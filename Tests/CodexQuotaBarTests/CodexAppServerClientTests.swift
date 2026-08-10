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
