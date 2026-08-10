import Foundation

protocol AppServerTransport: Sendable {
    var lines: AsyncStream<Data> { get }
    func start() async throws
    func send(_ line: Data) async throws
    func stop() async
}

struct AppServerTransportFactory: Sendable {
    let make: @Sendable () throws -> any AppServerTransport

    static let live = AppServerTransportFactory {
        guard let executable = CodexExecutableLocator.resolve() else {
            throw AppServerTransportError.codexNotFound
        }
        return ProcessAppServerTransport(executableURL: executable)
    }
}

enum AppServerTransportError: LocalizedError, Equatable {
    case codexNotFound
    case notRunning
    case processExited(Int32)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "找不到 codex 可执行文件"
        case .notRunning:
            return "Codex app-server 未运行"
        case let .processExited(code):
            return "Codex app-server 已退出（\(code)）"
        }
    }
}

enum CodexExecutableLocator {
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> URL? {
        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/codex" }
        let candidates = pathCandidates + [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex",
        ]
        return candidates.first(where: fileExists).map(URL.init(fileURLWithPath:))
    }
}

actor ProcessAppServerTransport: AppServerTransport {
    nonisolated let lines: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let executableURL: URL
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var buffer = Data()
    private var streamFinished = false

    init(executableURL: URL) {
        self.executableURL = executableURL
        let stream = AsyncStream<Data>.makeStream()
        lines = stream.stream
        continuation = stream.continuation
    }

    func start() async throws {
        guard process == nil else { return }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        inputHandle = inputPipe.fileHandleForWriting
        outputHandle = outputPipe.fileHandleForReading
        errorHandle = errorPipe.fileHandleForReading
        self.process = process

        outputHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.consume(data) }
        }
        errorHandle?.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            let code = terminatedProcess.terminationStatus
            Task { await self?.didTerminate(code: code) }
        }

        do {
            try process.run()
        } catch {
            await stop()
            throw error
        }
    }

    func send(_ line: Data) async throws {
        guard let process, process.isRunning, let inputHandle else {
            throw AppServerTransportError.notRunning
        }
        var framed = line
        framed.append(0x0A)
        try inputHandle.write(contentsOf: framed)
    }

    func stop() async {
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        try? inputHandle?.close()
        try? outputHandle?.close()
        try? errorHandle?.close()
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        process = nil
        finishStream()
    }

    private func consume(_ data: Data) {
        guard !streamFinished else { return }
        guard !data.isEmpty else {
            finishStream()
            return
        }

        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.last == 0x0D {
                line.removeLast()
            }
            if !line.isEmpty {
                continuation.yield(line)
            }
        }
    }

    private func didTerminate(code: Int32) {
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        process = nil
        finishStream()
    }

    private func finishStream() {
        guard !streamFinished else { return }
        streamFinished = true
        if !buffer.isEmpty {
            if buffer.last == 0x0D {
                buffer.removeLast()
            }
            if !buffer.isEmpty {
                continuation.yield(buffer)
            }
            buffer.removeAll(keepingCapacity: false)
        }
        continuation.finish()
    }
}
