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
}

private enum ProcessTransportTestError: Error {
    case timedOut(String)
    case invalidPID(String)
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

    init() {
        var captured: AsyncStream<Data>.Continuation!
        lines = AsyncStream { captured = $0 }
        continuation = captured
    }

    func start() async {
        startCount += 1
    }

    func send(_ line: Data) async {
        sent.append(line)
    }

    func stop() async {
        stopCount += 1
        continuation.finish()
    }

    func emit(_ json: String) {
        continuation.yield(Data(json.utf8))
    }

    func finish() {
        continuation.finish()
    }
}
