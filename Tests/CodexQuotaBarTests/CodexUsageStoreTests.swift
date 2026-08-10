import XCTest
@testable import CodexQuotaBar

private enum StoreTestError: Error {
    case failed
    case timedOut
}

private actor FakeOfficialRateLimitClient: OfficialRateLimitClient {
    nonisolated let events: AsyncStream<CodexAppServerEvent>
    private let eventContinuation: AsyncStream<CodexAppServerEvent>.Continuation
    private var reads: [CheckedContinuation<OfficialRateLimits, Error>] = []
    private(set) var readCount = 0
    private(set) var stopCount = 0

    init() {
        let stream = AsyncStream<CodexAppServerEvent>.makeStream()
        events = stream.stream
        eventContinuation = stream.continuation
    }

    func readRateLimits() async throws -> OfficialRateLimits {
        readCount += 1
        return try await withCheckedThrowingContinuation { reads.append($0) }
    }

    func succeed(_ value: OfficialRateLimits) {
        reads.removeFirst().resume(returning: value)
    }

    func fail(_ error: Error) {
        reads.removeFirst().resume(throwing: error)
    }

    func emit(_ event: CodexAppServerEvent) {
        eventContinuation.yield(event)
    }

    func stop() {
        stopCount += 1
        reads.forEach { $0.resume(throwing: CancellationError()) }
        reads.removeAll()
        eventContinuation.finish()
    }
}

@MainActor
final class CodexUsageStoreTests: XCTestCase {
    func testStartRefreshesLogsAndOfficialLimits() async throws {
        let client = FakeOfficialRateLimitClient()
        let target = makeTarget(id: "default-codex")
        let store = makeStore(client: client, targets: [target])

        store.start()

        try await waitUntil { await client.readCount == 1 && store.monitorSnapshots.count == 1 }
        XCTAssertEqual(store.monitorSnapshots[0].snapshot.secondaryQuota.remainingPercent, 50)
        store.stop()
    }

    func testOfficialOverlayOnlyChangesDefaultAndCoalescesRefreshes() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let client = FakeOfficialRateLimitClient()
        let defaultTarget = makeTarget(id: "default-codex")
        let customTarget = makeTarget(id: "custom")
        let store = CodexUsageStore(
            officialClient: client,
            snapshotLoader: { target, date in
                SnapshotFixtures.make(
                    now: date,
                    primaryUsed: target.id == "default-codex" ? 70 : 40,
                    secondaryUsed: target.id == "default-codex" ? 60 : 30,
                    secondaryResetAt: date.addingTimeInterval(7 * 86_400)
                )
            },
            monitorTargets: { [defaultTarget, customTarget] },
            now: { now }
        )
        store.start()
        try await waitUntil { await client.readCount == 1 && store.monitorSnapshots.count == 2 }

        store.refreshNow()
        store.refreshNow()
        store.refreshNow()
        await client.succeed(officialLimits())

        try await waitUntil { await client.readCount == 2 }
        XCTAssertEqual(store.monitorSnapshots.first { $0.id == "default-codex" }?.snapshot.secondaryQuota.remainingPercent, 86)
        XCTAssertEqual(store.monitorSnapshots.first { $0.id == "custom" }?.snapshot.secondaryQuota.remainingPercent, 70)
        store.stop()
    }

    func testFirstOfficialFailureKeepsLogFallback() async throws {
        let client = FakeOfficialRateLimitClient()
        let store = makeStore(client: client, targets: [makeTarget(id: "default-codex")])
        store.start()
        try await waitUntil { await client.readCount == 1 && store.monitorSnapshots.count == 1 }

        await client.fail(StoreTestError.failed)

        try await waitUntil { store.connectionState == .logs }
        XCTAssertEqual(store.monitorSnapshots[0].snapshot.secondaryQuota.remainingPercent, 50)
        store.stop()
    }

    func testReconnectKeepsLastOfficialValue() async throws {
        let now = fixedNow
        let client = FakeOfficialRateLimitClient()
        let store = makeStore(client: client, targets: [makeTarget(id: "default-codex")])
        store.start()
        try await waitUntil { await client.readCount == 1 && store.monitorSnapshots.count == 1 }
        await client.succeed(officialLimits())
        try await waitUntil { store.connectionState == .live(updatedAt: now) }

        await client.emit(.stateChanged(.reconnecting(attempt: 1, message: "test")))

        try await waitUntil {
            if case .reconnecting = store.connectionState { return true }
            return false
        }
        XCTAssertEqual(store.monitorSnapshots[0].snapshot.secondaryQuota.remainingPercent, 86)
        store.stop()
    }

    func testUpdatedNotificationTriggersOneFullRead() async throws {
        let now = fixedNow
        let client = FakeOfficialRateLimitClient()
        let store = makeStore(client: client, targets: [makeTarget(id: "default-codex")])
        store.start()
        try await waitUntil { await client.readCount == 1 }
        await client.succeed(OfficialRateLimits(primary: nil, secondary: nil, planType: nil))
        try await waitUntil { store.connectionState == .live(updatedAt: now) }

        await client.emit(.rateLimitsChanged)

        try await waitUntil { await client.readCount == 2 }
        let readCount = await client.readCount
        XCTAssertEqual(readCount, 2)
        store.stop()
    }

    func testStopCancelsWorkAndStopsClient() async throws {
        let client = FakeOfficialRateLimitClient()
        let store = makeStore(client: client, targets: [makeTarget(id: "default-codex")])
        store.start()
        try await waitUntil { await client.readCount == 1 }

        store.stop()

        try await waitUntil { await client.stopCount == 1 }
    }

    private let fixedNow = Date(timeIntervalSince1970: 1_000_000)

    private func makeStore(
        client: FakeOfficialRateLimitClient,
        targets: [MonitorTarget]
    ) -> CodexUsageStore {
        let now = fixedNow
        return CodexUsageStore(
            officialClient: client,
            snapshotLoader: { _, date in
                SnapshotFixtures.make(
                    now: date,
                    primaryUsed: 50,
                    secondaryUsed: 50,
                    secondaryResetAt: nil
                )
            },
            monitorTargets: { targets },
            now: { now }
        )
    }

    private func officialLimits() -> OfficialRateLimits {
        OfficialRateLimits(
            primary: OfficialRateLimitWindow(usedPercent: 20, windowDurationMins: 300, resetsAt: 2_000_000),
            secondary: OfficialRateLimitWindow(usedPercent: 14, windowDurationMins: 10_080, resetsAt: 3_000_000),
            planType: "plus"
        )
    }
}

private func makeTarget(id: String) -> MonitorTarget {
    MonitorTarget(
        id: id,
        name: id,
        systemImage: "speedometer",
        colorHex: "#0000FF",
        sessionsPath: "/tmp/\(id)",
        configPath: "/tmp/\(id).toml",
        isEnabled: true
    )
}

@MainActor
private func waitUntil(
    _ predicate: @escaping () async -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    for _ in 0..<100 {
        if await predicate() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("condition timed out", file: file, line: line)
    throw StoreTestError.timedOut
}
