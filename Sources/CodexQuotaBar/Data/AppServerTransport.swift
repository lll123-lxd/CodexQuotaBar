import Darwin
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
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var stdoutFinished = true
    private var stderrFinished = true
    private var started = false
    private var cleanupComplete = false
    private var exitCode: Int32?

    init(executableURL: URL) {
        self.executableURL = executableURL
        let stream = AsyncStream<Data>.makeStream()
        lines = stream.stream
        continuation = stream.continuation
    }

    func start() async throws {
        if let process {
            if process.isRunning {
                return
            }
            throw AppServerTransportError.processExited(process.terminationStatus)
        }
        if started {
            throw AppServerTransportError.processExited(exitCode ?? -1)
        }
        guard !cleanupComplete else {
            throw AppServerTransportError.notRunning
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputHandle = inputPipe.fileHandleForWriting
        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        process.executableURL = executableURL
        process.arguments = ["app-server"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] terminatedProcess in
            let pid = terminatedProcess.processIdentifier
            let code = terminatedProcess.terminationStatus
            Task { await self?.didTerminate(pid: pid, code: code) }
        }

        self.process = process
        self.inputHandle = inputHandle
        self.outputHandle = outputHandle
        self.errorHandle = errorHandle
        started = true

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            self.process = nil
            closeHandles()
            cleanupComplete = true
            exitCode = -1
            continuation.finish()
            throw error
        }

        stdoutFinished = false
        stderrFinished = false
        stdoutTask = Task<Void, Never> { [weak self, continuation, outputHandle] in
            await Self.readStdout(from: outputHandle, continuation: continuation)
            guard let self else { return }
            await self.markStdoutFinished()
        }
        stderrTask = Task<Void, Never> { [weak self, errorHandle] in
            await Self.drainStderr(from: errorHandle)
            guard let self else { return }
            await self.markStderrFinished()
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
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        if cleanupComplete {
            return
        }

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performStop()
        }
        shutdownTask = task
        await task.value
    }

    private func performStop() async {
        guard let process else {
            continuation.finish()
            await finishIOBounded()
            cleanupComplete = true
            return
        }

        let pid = process.processIdentifier
        if process.isRunning {
            process.terminate()
        }

        let exitedGracefully = await waitForExit(process, timeout: .milliseconds(250))
        if !exitedGracefully {
            let signalResult = Darwin.kill(pid, SIGKILL)
            let signalError = errno
            if signalResult == 0 || signalError == ESRCH {
                await Self.waitUntilExit(process)
            } else {
                process.terminate()
                await Self.waitUntilExit(process)
            }
        }

        process.terminationHandler = nil
        if self.process?.processIdentifier == pid {
            self.process = nil
        }
        exitCode = process.terminationStatus
        await finishIOBounded()
        cleanupComplete = true
    }

    private func didTerminate(pid: pid_t, code: Int32) {
        guard process?.processIdentifier == pid else { return }
        process?.terminationHandler = nil
        process = nil
        exitCode = code
        guard shutdownTask == nil else { return }

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performNaturalExitCleanup()
        }
        shutdownTask = task
    }

    private func waitForExit(_ process: Process, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning, clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(20))
        }
        return !process.isRunning
    }

    private func performNaturalExitCleanup() async {
        await finishIOBounded()
        cleanupComplete = true
    }

    private func finishIOBounded() async {
        let readersFinished = await waitForReaders(timeout: .milliseconds(250))
        if !readersFinished {
            stdoutTask?.cancel()
            stderrTask?.cancel()
            closeOutputHandles()
            _ = await waitForReaders(timeout: .milliseconds(250))
        }
        continuation.finish()
        closeHandles()
        self.stdoutTask = nil
        self.stderrTask = nil
    }

    private func waitForReaders(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(stdoutFinished && stderrFinished), clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(10))
        }
        return stdoutFinished && stderrFinished
    }

    private func markStdoutFinished() {
        stdoutFinished = true
    }

    private func markStderrFinished() {
        stderrFinished = true
    }

    private func closeOutputHandles() {
        try? outputHandle?.close()
        try? errorHandle?.close()
        outputHandle = nil
        errorHandle = nil
    }

    private func closeHandles() {
        try? inputHandle?.close()
        try? outputHandle?.close()
        try? errorHandle?.close()
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
    }

    private static func waitUntilExit(_ process: Process) async {
        await Task.detached(priority: nil) {
            process.waitUntilExit()
        }.value
    }

    private static func readStdout(
        from handle: FileHandle,
        continuation: AsyncStream<Data>.Continuation
    ) async {
        var buffer = Data()
        do {
            for try await byte in handle.bytes {
                if byte == 0x0A {
                    var line = buffer
                    buffer.removeAll(keepingCapacity: true)
                    if line.last == 0x0D {
                        line.removeLast()
                    }
                    if !line.isEmpty {
                        continuation.yield(line)
                    }
                } else {
                    buffer.append(byte)
                }
            }
        } catch {
            // Closing a handle during forced cleanup ends the reader.
        }

        if buffer.last == 0x0D {
            buffer.removeLast()
        }
        if !buffer.isEmpty {
            continuation.yield(buffer)
        }
        continuation.finish()
    }

    private static func drainStderr(from handle: FileHandle) async {
        do {
            for try await _ in handle.bytes {}
        } catch {
            // stderr is intentionally ignored; closing the handle ends the drain.
        }
    }
}
