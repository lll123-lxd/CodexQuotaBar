import Darwin
import Foundation
import XCTest
@testable import CodexQuotaBar

final class CodexAppServerClientTests: XCTestCase {
    func testLocatorUsesPathBeforeHomebrewFallbacks() {
        let url = CodexExecutableLocator.resolve(
            environment: ["PATH": "/custom/bin:/usr/bin"],
            fileExists: {
                $0 == "/custom/bin/codex" || $0 == "/opt/homebrew/bin/codex"
            }
        )

        XCTAssertEqual(url?.path, "/custom/bin/codex")
    }

    func testLocatorFallsBackToAppleSiliconHomebrew() {
        let url = CodexExecutableLocator.resolve(
            environment: [:],
            fileExists: { $0 == "/opt/homebrew/bin/codex" }
        )

        XCTAssertEqual(url?.path, "/opt/homebrew/bin/codex")
    }

    func testLocatorFallsBackToIntelHomebrew() {
        let url = CodexExecutableLocator.resolve(
            environment: [:],
            fileExists: { $0 == "/usr/local/bin/codex" }
        )

        XCTAssertEqual(url?.path, "/usr/local/bin/codex")
    }

    func testLocatorReturnsNilWhenCodexIsUnavailable() {
        let url = CodexExecutableLocator.resolve(
            environment: ["PATH": "/custom/bin:/usr/bin"],
            fileExists: { _ in false }
        )

        XCTAssertNil(url)
    }

    func testProcessTransportFramesStdoutAndDrainsStderr() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutableScript(
            in: directory,
            body: #"""
            if [ "$#" -ne 1 ] || [ "$1" != "app-server" ]; then
                exit 64
            fi
            IFS= read -r line
            printf '{"stderr":true}\n' >&2
            printf '%s\r\n\r\n' "$line"
            printf '{"tail":true}'
            """#
        )
        let transport = ProcessAppServerTransport(executableURL: executable)

        let lines: [Data]
        do {
            try await transport.start()
            try await transport.send(Data(#"{"stdin":true}"#.utf8))
            lines = try await collectAllLines(from: transport.lines)
        } catch {
            await transport.stop()
            throw error
        }
        await transport.stop()

        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, [
            #"{"stdin":true}"#,
            #"{"tail":true}"#,
        ])
    }

    func testProcessTransportPreservesBurstFrameOrderThroughImmediateExit() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutableScript(
            in: directory,
            body: #"""
            i=0
            while [ "$i" -lt 1000 ]; do
                printf '{"number":%s}\n' "$i"
                i=$((i + 1))
            done
            printf '{"tail":true}'
            """#
        )
        let transport = ProcessAppServerTransport(executableURL: executable)

        let lines: [Data]
        do {
            try await transport.start()
            lines = try await collectAllLines(from: transport.lines)
        } catch {
            await transport.stop()
            throw error
        }
        await transport.stop()

        let expected = (0..<1000).map { #"{"number":\#($0)}"# } + [#"{"tail":true}"#]
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, expected)
    }

    func testStopWaitsUntilProcessHasExited() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("process.pid")
        let executable = try makeExecutableScript(
            in: directory,
            body: """
            printf '%s' "$$" > \(shellQuote(pidFile.path))
            trap 'sleep 1; exit 0' TERM
            while :; do
                sleep 1
            done
            """
        )
        let transport = ProcessAppServerTransport(executableURL: executable)

        try await transport.start()
        let pid: pid_t
        do {
            pid = try await waitForPID(at: pidFile)
        } catch {
            await transport.stop()
            throw error
        }
        defer {
            if Darwin.kill(pid, 0) == 0 {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }

        await transport.stop()

        if Darwin.kill(pid, 0) == 0 {
            XCTFail("stop() returned while child process \(pid) was still alive")
        } else {
            XCTAssertEqual(errno, ESRCH)
        }
    }

    func testConcurrentStopsForceAnIgnoredTermProcessWithinBound() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("ignored-term.pid")
        let executable = try makeExecutableScript(
            in: directory,
            body: """
            printf '%s' "$$" > \(shellQuote(pidFile.path))
            trap '' TERM
            while :; do
                IFS= read -r ignored
            done
            """
        )
        let transport = ProcessAppServerTransport(executableURL: executable)

        try await transport.start()
        let pid = try await waitForPID(at: pidFile)
        defer { killIfAlive(pid) }
        let startedAt = Date()
        let first = Task<Void, Never> { await transport.stop() }
        let second = Task<Void, Never> { await transport.stop() }

        try await waitForTasks([first, second], timeout: .seconds(6))

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.5)
        assertProcessDoesNotExist(pid)
    }

    func testStopDoesNotWaitForDescendantHoldingPipesOpen() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parentPIDFile = directory.appendingPathComponent("parent.pid")
        let descendantPIDFile = directory.appendingPathComponent("descendant.pid")
        let executable = try makeExecutableScript(
            in: directory,
            body: """
            /bin/sleep 3 &
            descendant=$!
            printf '%s' "$$" > \(shellQuote(parentPIDFile.path))
            printf '%s' "$descendant" > \(shellQuote(descendantPIDFile.path))
            exit 0
            """
        )
        let transport = ProcessAppServerTransport(executableURL: executable)

        try await transport.start()
        let parentPID = try await waitForPID(at: parentPIDFile)
        let descendantPID = try await waitForPID(at: descendantPIDFile)
        defer { killIfAlive(parentPID) }
        defer { killIfAlive(descendantPID) }
        XCTAssertEqual(Darwin.kill(descendantPID, 0), 0)
        let startedAt = Date()
        let stop = Task<Void, Never> { await transport.stop() }

        try await waitForTasks([stop], timeout: .seconds(5))

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.5)
        assertProcessDoesNotExist(parentPID)
    }

    func testHandshakeReadsOfficialLimitsAndMapsUpdatedNotification() async throws {
        let transport = FakeAppServerTransport()
        let client = CodexAppServerClient(
            factory: AppServerTransportFactory { transport },
            timeoutSeconds: 0.2,
            sleep: { _ in },
            jitter: { _ in 1 },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let read = Task { try await client.readRateLimits() }

        var sent = try await waitForSentCount(1, transport: transport)
        let initialize = try jsonObject(sent[0])
        XCTAssertEqual(initialize["method"] as? String, "initialize")
        let clientInfo = (initialize["params"] as? [String: Any])?["clientInfo"] as? [String: Any]
        XCTAssertEqual(clientInfo?["name"] as? String, "codex-quota-bar")
        XCTAssertEqual(clientInfo?["title"] as? String, "CodexQuotaBar")
        XCTAssertEqual(clientInfo?["version"] as? String, "1.0.0")
        let initializeID = try rpcID(initialize)
        await transport.emit("{\"id\":\(initializeID),\"result\":{}}")

        sent = try await waitForSentCount(3, transport: transport)
        XCTAssertEqual(try jsonObject(sent[1])["method"] as? String, "initialized")
        let rateRequest = try jsonObject(sent[2])
        XCTAssertEqual(rateRequest["method"] as? String, "account/rateLimits/read")
        let rateID = try rpcID(rateRequest)
        await transport.emit("{\"id\":\(rateID),\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":20,\"windowDurationMins\":300,\"resetsAt\":2000},\"secondary\":{\"usedPercent\":14,\"windowDurationMins\":10080,\"resetsAt\":9000},\"planType\":\"plus\"}}}")

        let limits = try await taskValue(of: read)
        XCTAssertEqual(limits.secondary?.remainingFraction ?? -1, 0.86, accuracy: 0.000_001)
        let startCount = await transport.startCount
        XCTAssertEqual(startCount, 1)

        await transport.emit("{\"method\":\"account/rateLimits/updated\",\"params\":{\"rateLimits\":{\"secondary\":{\"usedPercent\":15}}}}")
        let foundUpdate = try await waitForEvent(.rateLimitsChanged, in: client.events)
        XCTAssertTrue(foundUpdate)
        try await stopClient(client)
    }

    func testRequestTimeoutAndReconnectBackoffScheduleAreFixedAndBounded() {
        XCTAssertEqual(CodexAppServerClient.requestTimeoutSeconds, 20)
        XCTAssertEqual(
            (1...7).map { ReconnectBackoff.delay(for: $0, jitter: 1) },
            [1, 2, 4, 8, 16, 30, 30]
        )
        XCTAssertEqual(ReconnectBackoff.delay(for: 1, jitter: 0.1), 0.9, accuracy: 0.000_001)
        XCTAssertEqual(ReconnectBackoff.delay(for: 1, jitter: 9), 1.1, accuracy: 0.000_001)
        XCTAssertEqual(ReconnectBackoff.delay(for: 6, jitter: 1.1), 30, accuracy: 0.000_001)
        XCTAssertEqual(ReconnectBackoff.delay(for: 99, jitter: 1), 30, accuracy: 0.000_001)
    }

    func testTimeoutStopsOldTransportAndReconnects() async throws {
        let first = FakeAppServerTransport()
        let second = FakeAppServerTransport()
        let queue = LockedTransportQueue([first, second])
        let delays = LockedDelays()
        let client = CodexAppServerClient(
            factory: AppServerTransportFactory { try queue.next() },
            timeoutSeconds: 0.2,
            sleep: { delays.append($0) },
            jitter: { _ in 1 }
        )
        let read = Task { try await client.readRateLimits() }

        _ = try await waitForSentCount(1, transport: first)
        try await waitUntil { await first.stopCount == 1 }
        var sent = try await waitForSentCount(1, transport: second)
        var object = try jsonObject(sent[0])
        await second.emit("{\"id\":\(try rpcID(object)),\"result\":{}}")
        sent = try await waitForSentCount(3, transport: second)
        object = try jsonObject(sent[2])
        await second.emit("{\"id\":\(try rpcID(object)),\"result\":{\"rateLimits\":{\"primary\":null,\"secondary\":null,\"planType\":\"plus\"}}}")

        _ = try await taskValue(of: read)
        XCTAssertEqual(delays.values, [1])
        XCTAssertEqual(queue.makeCount, 2)
        try await stopClient(client)
    }

    func testOverloadBacksOffWithoutRestartingHealthyTransport() async throws {
        let transport = FakeAppServerTransport()
        let delays = LockedDelays()
        let client = CodexAppServerClient(
            factory: AppServerTransportFactory { transport },
            timeoutSeconds: 0.2,
            sleep: { delays.append($0) },
            jitter: { _ in 1 }
        )
        let read = Task { try await client.readRateLimits() }
        let firstRateID = try await completeHandshakeAndReturnRateRequestID(transport)
        await transport.emit("{\"id\":\(firstRateID),\"error\":{\"code\":-32001,\"message\":\"Server overloaded; retry later.\"}}")

        let sent = try await waitForSentCount(4, transport: transport)
        let secondRate = try jsonObject(sent[3])
        XCTAssertEqual(secondRate["method"] as? String, "account/rateLimits/read")
        await transport.emit("{\"id\":\(try rpcID(secondRate)),\"result\":{\"rateLimits\":{\"primary\":null,\"secondary\":null,\"planType\":\"plus\"}}}")

        _ = try await taskValue(of: read)
        XCTAssertEqual(delays.values, [1])
        let stopCount = await transport.stopCount
        XCTAssertEqual(stopCount, 0)
        try await stopClient(client)
    }

    func testMalformedMessageStopsOldTransportAndDoesNotLeakPendingReadAcrossReconnect() async throws {
        let first = FakeAppServerTransport()
        let second = FakeAppServerTransport()
        let queue = LockedTransportQueue([first, second])
        let client = CodexAppServerClient(
            factory: AppServerTransportFactory { try queue.next() },
            timeoutSeconds: 0.2,
            sleep: { _ in },
            jitter: { _ in 1 }
        )
        let read = Task { try await client.readRateLimits() }

        _ = try await waitForSentCount(1, transport: first)
        await first.emit("{bad json")
        try await waitUntil { await first.stopCount == 1 }

        let rateID = try await completeHandshakeAndReturnRateRequestID(second)
        await second.emit("{\"id\":\(rateID),\"result\":{\"rateLimits\":{\"primary\":null,\"secondary\":null,\"planType\":\"plus\"}}}")
        _ = try await taskValue(of: read)
        XCTAssertEqual(queue.makeCount, 2)
        try await stopClient(client)
    }

    func testIdleConnectionEndReconnectsAndDeliversUpdatedNotifications() async throws {
        let first = FakeAppServerTransport()
        let second = FakeAppServerTransport()
        let queue = LockedTransportQueue([first, second])
        let client = CodexAppServerClient(
            factory: AppServerTransportFactory { try queue.next() },
            timeoutSeconds: 0.2,
            sleep: { _ in },
            jitter: { _ in 1 }
        )
        let read = Task { try await client.readRateLimits() }
        let rateID = try await completeHandshakeAndReturnRateRequestID(first)
        await first.emit("{\"id\":\(rateID),\"result\":{\"rateLimits\":{\"primary\":null,\"secondary\":null,\"planType\":\"plus\"}}}")
        _ = try await taskValue(of: read)

        await first.finish()
        _ = try await waitForSentCount(1, transport: second)
        let initialize = try jsonObject((await second.sent)[0])
        await second.emit("{\"id\":\(try rpcID(initialize)),\"result\":{}}")
        _ = try await waitForSentCount(2, transport: second)
        await second.emit("{\"method\":\"account/rateLimits/updated\",\"params\":{}}")

        XCTAssertTrue(try await waitForEvent(.rateLimitsChanged, in: client.events))
        XCTAssertEqual(queue.makeCount, 2)
        try await stopClient(client)
    }

    func testStopCancelsReadWaitingForReconnectBackoff() async throws {
        let transport = FakeAppServerTransport()
        let client = CodexAppServerClient(
            factory: AppServerTransportFactory { transport },
            timeoutSeconds: 0.2,
            sleep: { _ in try await Task.sleep(for: .seconds(30)) },
            jitter: { _ in 1 }
        )
        let read = Task { try await client.readRateLimits() }
        let rateID = try await completeHandshakeAndReturnRateRequestID(transport)
        await transport.emit("{\"id\":\(rateID),\"error\":{\"code\":-32001,\"message\":\"Server overloaded\"}}")

        try await waitUntil { await transport.sent.count == 3 }
        await client.stop()
        do {
            _ = try await taskValue(of: read, timeout: .seconds(1))
            XCTFail("stopped read unexpectedly succeeded")
        } catch is CancellationError {
            // Expected: stop cancels the client-owned backoff task.
        } catch let error as CodexAppServerClientError {
            XCTAssertEqual(error, .stopped)
        }
    }

    func testOldGenerationReadFailureDoesNotInvalidateNewConnection() async throws {
        let first = FakeAppServerTransport()
        let second = FakeAppServerTransport()
        let queue = LockedTransportQueue([first, second])
        let client = CodexAppServerClient(
            factory: AppServerTransportFactory { try queue.next() },
            timeoutSeconds: 0.2,
            sleep: { _ in },
            jitter: { _ in 1 }
        )
        await first.failNextSend()
        await first.blockNextStop()

        let firstRead = Task { try await client.readRateLimits() }
        _ = try await waitForSentCount(1, transport: first)
        try await waitUntil { await first.stopStarted }

        let secondRead = Task { try await client.readRateLimits() }
        _ = try await waitForSentCount(1, transport: second)
        let initialize = try jsonObject((await second.sent)[0])
        await second.emit("{\"id\":\(try rpcID(initialize)),\"result\":{}}")
        _ = try await waitForSentCount(3, transport: second)

        await first.releaseStop()
        try await ContinuousClock().sleep(for: .milliseconds(50))
        XCTAssertEqual(await second.stopCount, 0)
        let rate = try jsonObject((await second.sent)[2])
        await second.emit("{\"id\":\(try rpcID(rate)),\"result\":{\"rateLimits\":{\"primary\":null,\"secondary\":null,\"planType\":\"plus\"}}}")
        _ = try await taskValue(of: secondRead)
        firstRead.cancel()
        _ = try? await taskValue(of: firstRead)
        try await stopClient(client)
    }

    func testTaskValueTimeoutReturnsWhenExternalTaskIgnoresCancellation() async throws {
        let suspension = UncancellableSuspension()
        let task = Task<Int, Error> {
            try await suspension.wait()
        }
        defer { Task { await suspension.resume() } }

        do {
            _ = try await taskValue(of: task, timeout: .milliseconds(20))
            XCTFail("timeout unexpectedly returned a value")
        } catch RPCClientTestError.timedOut {
            XCTAssertTrue(task.isCancelled)
        }
    }
}

private enum ProcessTransportTestError: Error {
    case timedOut(String)
    case invalidPID(String)
}

private enum RPCClientTestError: Error {
    case timedOut(String)
    case invalidRPCID
    case noTransportsRemaining
}

private final class TaskValueGate<Success>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Success, Error>?

    func install(_ continuation: CheckedContinuation<Success, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(with result: Result<Success, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private actor UncancellableSuspension {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async throws {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private final class LockedTransportQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [any AppServerTransport]
    private var count = 0

    init(_ transports: [any AppServerTransport]) {
        self.transports = transports
    }

    var makeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func next() throws -> any AppServerTransport {
        lock.lock()
        defer { lock.unlock() }
        guard !transports.isEmpty else {
            throw RPCClientTestError.noTransportsRemaining
        }
        count += 1
        return transports.removeFirst()
    }
}

private final class LockedDelays: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TimeInterval] = []

    var values: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: TimeInterval) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func rpcID(_ object: [String: Any]) throws -> Int {
    guard let id = object["id"] as? NSNumber else {
        throw RPCClientTestError.invalidRPCID
    }
    return id.intValue
}

private func waitForSentCount(
    _ count: Int,
    transport: FakeAppServerTransport,
    timeout: Duration = .seconds(1)
) async throws -> [Data] {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        let sent = await transport.sent
        if sent.count >= count {
            return sent
        }
        try await clock.sleep(for: .milliseconds(10))
    }
    throw RPCClientTestError.timedOut("waiting for \(count) app-server messages")
}

private func waitUntil(
    timeout: Duration = .seconds(1),
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await predicate() {
            return
        }
        try await clock.sleep(for: .milliseconds(10))
    }
    throw RPCClientTestError.timedOut("waiting for asynchronous condition")
}

private func completeHandshakeAndReturnRateRequestID(
    _ transport: FakeAppServerTransport
) async throws -> Int {
    var sent = try await waitForSentCount(1, transport: transport)
    var object = try jsonObject(sent[0])
    await transport.emit("{\"id\":\(try rpcID(object)),\"result\":{}}")
    sent = try await waitForSentCount(3, transport: transport)
    object = try jsonObject(sent[2])
    XCTAssertEqual(object["method"] as? String, "account/rateLimits/read")
    return try rpcID(object)
}

private func taskValue<Success: Sendable>(
    of task: Task<Success, Error>,
    timeout: Duration = .seconds(1)
) async throws -> Success {
    let gate = TaskValueGate<Success>()
    return try await withCheckedThrowingContinuation { continuation in
        gate.install(continuation)
        Task {
            do {
                gate.resume(with: .success(try await task.value))
            } catch {
                gate.resume(with: .failure(error))
            }
        }
        Task {
            do {
                try await ContinuousClock().sleep(for: timeout)
                task.cancel()
                gate.resume(with: .failure(RPCClientTestError.timedOut("waiting for RPC task")))
            } catch {
                // The timeout waiter has no caller-owned cancellation path.
            }
        }
    }
}

private func waitForEvent(
    _ expected: CodexAppServerEvent,
    in events: AsyncStream<CodexAppServerEvent>,
    timeout: Duration = .seconds(1)
) async throws -> Bool {
    try await withThrowingTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await event in events {
                if event == expected {
                    return true
                }
            }
            return false
        }
        group.addTask {
            try await ContinuousClock().sleep(for: timeout)
            throw RPCClientTestError.timedOut("waiting for app-server event")
        }
        defer { group.cancelAll() }
        guard let found = try await group.next() else {
            throw RPCClientTestError.timedOut("waiting for app-server event result")
        }
        return found
    }
}

private func stopClient(_ client: CodexAppServerClient) async throws {
    let stop = Task<Void, Never> { await client.stop() }
    try await waitForTasks([stop], timeout: .seconds(1))
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexQuotaBarTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeExecutableScript(in directory: URL, body: String) throws -> URL {
    let executable = directory.appendingPathComponent("codex")
    try "#!/bin/sh\nset -eu\n\(body)\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    return executable
}

private func collectAllLines(
    from stream: AsyncStream<Data>,
    timeout: Duration = .seconds(5)
) async throws -> [Data] {
    try await withThrowingTaskGroup(of: [Data].self) { group in
        group.addTask {
            var lines: [Data] = []
            for await line in stream {
                lines.append(line)
            }
            return lines
        }
        group.addTask {
            try await ContinuousClock().sleep(for: timeout)
            throw ProcessTransportTestError.timedOut("waiting for app-server stdout to finish")
        }

        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw ProcessTransportTestError.timedOut("waiting for app-server stdout result")
        }
        return result
    }
}

private func waitForPID(
    at url: URL,
    timeout: Duration = .seconds(5)
) async throws -> pid_t {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if let contents = try? String(contentsOf: url, encoding: .utf8) {
            let value = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pid = pid_t(value), pid > 0 else {
                throw ProcessTransportTestError.invalidPID(contents)
            }
            return pid
        }
        try await clock.sleep(for: .milliseconds(20))
    }
    throw ProcessTransportTestError.timedOut("waiting for app-server PID file")
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private actor TaskCompletionFlag {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
    }
}

private func waitForTasks(
    _ tasks: [Task<Void, Never>],
    timeout: Duration
) async throws {
    let completion = TaskCompletionFlag()
    let observer = Task<Void, Never> {
        for task in tasks {
            await task.value
        }
        await completion.markCompleted()
    }
    defer { observer.cancel() }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await completion.isCompleted() {
            return
        }
        try await clock.sleep(for: .milliseconds(20))
    }
    tasks.forEach { $0.cancel() }
    throw ProcessTransportTestError.timedOut("waiting for transport stop tasks")
}

private func killIfAlive(_ pid: pid_t) {
    if Darwin.kill(pid, 0) == 0 {
        _ = Darwin.kill(pid, SIGKILL)
    }
}

private func assertProcessDoesNotExist(
    _ pid: pid_t,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if Darwin.kill(pid, 0) == 0 {
        XCTFail("process \(pid) is still alive", file: file, line: line)
    } else {
        XCTAssertEqual(errno, ESRCH, file: file, line: line)
    }
}

actor FakeAppServerTransport: AppServerTransport {
    nonisolated let lines: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private(set) var sent: [Data] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var sendError: Error?
    private var blocksStop = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private(set) var stopStarted = false

    init() {
        var captured: AsyncStream<Data>.Continuation!
        lines = AsyncStream { captured = $0 }
        continuation = captured
    }

    func start() async {
        startCount += 1
    }

    func send(_ line: Data) async throws {
        if let sendError {
            self.sendError = nil
            throw sendError
        }
        sent.append(line)
    }

    func stop() async {
        stopCount += 1
        if blocksStop {
            stopStarted = true
            await withCheckedContinuation { continuation in
                stopContinuation = continuation
            }
        }
        continuation.finish()
    }

    func emit(_ json: String) {
        continuation.yield(Data(json.utf8))
    }

    func finish() {
        continuation.finish()
    }

    func failNextSend() {
        sendError = CodexAppServerClientError.disconnected
    }

    func blockNextStop() {
        blocksStop = true
    }

    func releaseStop() {
        stopContinuation?.resume()
        stopContinuation = nil
        blocksStop = false
    }
}
