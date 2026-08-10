import Foundation

enum CodexAppServerEvent: Equatable {
    case stateChanged(QuotaConnectionState)
    case rateLimitsChanged
}

protocol OfficialRateLimitClient: Sendable {
    var events: AsyncStream<CodexAppServerEvent> { get }
    func readRateLimits() async throws -> OfficialRateLimits
    func stop() async
}

enum CodexAppServerClientError: LocalizedError, Equatable {
    case stopped
    case timeout
    case malformedMessage
    case rpc(code: Int, message: String)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .stopped:
            return "Codex app-server 客户端已停止 (client stopped)"
        case .timeout:
            return "Codex app-server 20 秒内没有响应 (request timed out)"
        case .malformedMessage:
            return "Codex app-server 返回了无效消息 (malformed message)"
        case let .rpc(code, message):
            return "Codex app-server 错误 \(code) (RPC error): \(message)"
        case .disconnected:
            return "Codex app-server 连接已断开 (disconnected)"
        }
    }
}

typealias ClientSleep = @Sendable (TimeInterval) async throws -> Void
typealias ClientJitter = @Sendable (ClosedRange<Double>) -> Double
typealias ClientNow = @Sendable () -> Date

enum ReconnectBackoff {
    static func delay(for attempt: Int, jitter: Double) -> TimeInterval {
        let schedule: [TimeInterval] = [1, 2, 4, 8, 16, 30]
        let index = min(max(attempt - 1, 0), schedule.count - 1)
        let boundedJitter = min(max(jitter, 0.9), 1.1)
        return min(30, schedule[index] * boundedJitter)
    }
}

private struct RPCResponse<Result: Decodable>: Decodable {
    let id: Int
    let result: Result?
    let error: RPCFailure?
}

private struct RPCFailure: Decodable {
    let code: Int
    let message: String
}

private struct InitializeResponse: Decodable {
    init(from decoder: Decoder) throws {}
}

actor CodexAppServerClient: OfficialRateLimitClient {
    static let requestTimeoutSeconds: TimeInterval = 20

    nonisolated let events: AsyncStream<CodexAppServerEvent>
    private let eventContinuation: AsyncStream<CodexAppServerEvent>.Continuation
    private let factory: AppServerTransportFactory
    private let timeoutSeconds: TimeInterval
    private let sleep: ClientSleep
    private let jitter: ClientJitter
    private let now: ClientNow

    private var transport: (any AppServerTransport)?
    private var readerTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Error>?
    private var connectionGeneration: UUID?
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var nextID = 1
    private var initialized = false
    private var stopped = false

    init(
        factory: AppServerTransportFactory = .live,
        timeoutSeconds: TimeInterval = 20,
        sleep: @escaping ClientSleep = { seconds in
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        jitter: @escaping ClientJitter = { Double.random(in: $0) },
        now: @escaping ClientNow = Date.init
    ) {
        self.factory = factory
        self.timeoutSeconds = timeoutSeconds
        self.sleep = sleep
        self.jitter = jitter
        self.now = now
        let stream = AsyncStream<CodexAppServerEvent>.makeStream()
        events = stream.stream
        eventContinuation = stream.continuation
    }

    func readRateLimits() async throws -> OfficialRateLimits {
        var attempt = 0
        while !stopped {
            do {
                if transport == nil {
                    let state: QuotaConnectionState = attempt == 0
                        ? .connecting
                        : .reconnecting(attempt: attempt, message: nil)
                    eventContinuation.yield(.stateChanged(state))
                }
                try await ensureConnected()
                let response: OfficialRateLimitsResponse = try await request(
                    "account/rateLimits/read",
                    params: [:]
                )
                eventContinuation.yield(.stateChanged(.live(updatedAt: now())))
                return response.rateLimits
            } catch let CodexAppServerClientError.rpc(code, _) where code == -32001 {
                attempt += 1
                eventContinuation.yield(.stateChanged(.reconnecting(
                    attempt: attempt,
                    message: "Server overloaded"
                )))
                try await sleep(reconnectDelay(for: attempt))
            } catch is CancellationError {
                throw CancellationError()
            } catch CodexAppServerClientError.stopped {
                throw CodexAppServerClientError.stopped
            } catch {
                attempt += 1
                await invalidateConnection(error)
                guard !stopped else {
                    throw CodexAppServerClientError.stopped
                }
                eventContinuation.yield(.stateChanged(.reconnecting(
                    attempt: attempt,
                    message: error.localizedDescription
                )))
                try await sleep(reconnectDelay(for: attempt))
            }
        }
        throw CodexAppServerClientError.stopped
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        let initializer = connectionTask
        connectionTask = nil
        initializer?.cancel()
        await invalidateConnection(CodexAppServerClientError.stopped)
        eventContinuation.finish()
    }

    private func reconnectDelay(for attempt: Int) -> TimeInterval {
        ReconnectBackoff.delay(for: attempt, jitter: jitter(0.9...1.1))
    }

    private func ensureConnected() async throws {
        guard !stopped else {
            throw CodexAppServerClientError.stopped
        }
        if initialized {
            return
        }
        if let connectionTask {
            try await connectionTask.value
            return
        }

        let task = Task { try await self.connectOneGeneration() }
        connectionTask = task
        do {
            try await task.value
            connectionTask = nil
        } catch {
            connectionTask = nil
            throw error
        }
    }

    private func connectOneGeneration() async throws {
        let candidate = try factory.make()
        let generation = UUID()
        transport = candidate
        connectionGeneration = generation

        do {
            try await candidate.start()
            guard !stopped, generation == connectionGeneration else {
                throw CodexAppServerClientError.stopped
            }
            readerTask = Task { [weak self, candidate] in
                for await line in candidate.lines {
                    await self?.receive(line, generation: generation)
                }
                await self?.connectionEnded(generation: generation)
            }
            let _: InitializeResponse = try await request("initialize", params: [
                "clientInfo": [
                    "name": "codex-quota-bar",
                    "title": "CodexQuotaBar",
                    "version": "1.0.0",
                ],
            ])
            try await sendNotification("initialized", params: [:])
            guard !stopped, generation == connectionGeneration else {
                throw CodexAppServerClientError.disconnected
            }
            initialized = true
        } catch {
            await invalidateConnection(error, generation: generation)
            throw error
        }
    }

    private func request<Result: Decodable>(
        _ method: String,
        params: [String: Any]
    ) async throws -> Result {
        let id = nextID
        nextID += 1
        let payload = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "method": method,
            "params": params,
        ])
        let responseData = try await performRequest(id: id, payload: payload)
        let response: RPCResponse<Result>
        do {
            response = try JSONDecoder().decode(RPCResponse<Result>.self, from: responseData)
        } catch {
            throw CodexAppServerClientError.malformedMessage
        }
        if let failure = response.error {
            throw CodexAppServerClientError.rpc(code: failure.code, message: failure.message)
        }
        guard let result = response.result else {
            throw CodexAppServerClientError.malformedMessage
        }
        return result
    }

    private func sendNotification(_ method: String, params: [String: Any]) async throws {
        guard let transport else {
            throw CodexAppServerClientError.disconnected
        }
        let payload = try JSONSerialization.data(withJSONObject: [
            "method": method,
            "params": params,
        ])
        try await transport.send(payload)
    }

    private func performRequest(id: Int, payload: Data) async throws -> Data {
        let timeoutNanoseconds = UInt64(max(0, timeoutSeconds) * 1_000_000_000)
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await self.waitForResponse(id: id, payload: payload)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                try Task.checkCancellation()
                throw CodexAppServerClientError.timeout
            }
            do {
                guard let first = try await group.next() else {
                    throw CodexAppServerClientError.disconnected
                }
                group.cancelAll()
                return first
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func waitForResponse(id: Int, payload: Data) async throws -> Data {
        guard let candidate = transport, let generation = connectionGeneration else {
            throw CodexAppServerClientError.disconnected
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                pending[id] = continuation
                Task {
                    await self.write(
                        payload,
                        id: id,
                        transport: candidate,
                        generation: generation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelPending(id: id) }
        }
    }

    private func write(
        _ payload: Data,
        id: Int,
        transport candidate: any AppServerTransport,
        generation: UUID
    ) async {
        do {
            try await candidate.send(payload)
        } catch {
            failPending(id: id, error: error)
            await invalidateConnection(error, generation: generation)
        }
    }

    private func cancelPending(id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func failPending(id: Int, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func receive(_ line: Data, generation: UUID) async {
        guard generation == connectionGeneration else { return }
        guard let value = try? JSONSerialization.jsonObject(with: line),
              let object = value as? [String: Any] else {
            await invalidateConnection(
                CodexAppServerClientError.malformedMessage,
                generation: generation
            )
            return
        }
        if let method = object["method"] as? String {
            if method == "account/rateLimits/updated" {
                eventContinuation.yield(.rateLimitsChanged)
            }
            return
        }
        guard let number = object["id"] as? NSNumber else { return }
        pending.removeValue(forKey: number.intValue)?.resume(returning: line)
    }

    private func connectionEnded(generation: UUID) async {
        guard generation == connectionGeneration, !stopped else { return }
        eventContinuation.yield(.stateChanged(.reconnecting(
            attempt: 1,
            message: "Connection closed"
        )))
        await invalidateConnection(
            CodexAppServerClientError.disconnected,
            generation: generation
        )
    }

    private func invalidateConnection(_ error: Error, generation: UUID? = nil) async {
        if let generation, generation != connectionGeneration {
            return
        }

        let oldTransport = transport
        let oldReader = readerTask
        transport = nil
        readerTask = nil
        connectionGeneration = nil
        initialized = false
        oldReader?.cancel()

        let continuations = Array(pending.values)
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
        await oldTransport?.stop()
    }
}
