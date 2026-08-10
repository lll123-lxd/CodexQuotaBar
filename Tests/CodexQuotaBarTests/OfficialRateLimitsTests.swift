import XCTest
@testable import CodexQuotaBar

final class OfficialRateLimitsTests: XCTestCase {
    func testDecodesOfficialRateLimitsResponse() throws {
        let json = #"""
        {"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":2000},"secondary":{"usedPercent":14,"windowDurationMins":10080,"resetsAt":9000},"planType":"plus"}}
        """#.data(using: .utf8)!

        let response = try JSONDecoder().decode(OfficialRateLimitsResponse.self, from: json)

        XCTAssertEqual(response.rateLimits.primary?.usedPercent, 20)
        XCTAssertEqual(response.rateLimits.secondary?.remainingFraction ?? -1, 0.86, accuracy: 0.000_001)
        XCTAssertEqual(response.rateLimits.secondary?.resetAt, Date(timeIntervalSince1970: 9_000))
    }

    func testApplyingOfficialLimitsPreservesLogUsageFields() {
        let now = Date(timeIntervalSince1970: 1_000)
        let log = SnapshotFixtures.make(
            now: now,
            primaryUsed: 70,
            secondaryUsed: 60,
            secondaryResetAt: Date(timeIntervalSince1970: 2_000)
        )
        let official = OfficialRateLimits(
            primary: OfficialRateLimitWindow(usedPercent: 20, windowDurationMins: 300, resetsAt: 3_000),
            secondary: OfficialRateLimitWindow(usedPercent: 14, windowDurationMins: 10_080, resetsAt: 9_000),
            planType: "pro"
        )
        let refreshedAt = now.addingTimeInterval(10)

        let merged = official.applying(to: log, at: refreshedAt)

        XCTAssertEqual(merged.refreshedAt, refreshedAt)
        XCTAssertEqual(merged.primaryQuota.usedPercent, 20)
        XCTAssertEqual(merged.secondaryQuota.remainingPercent, 86)
        XCTAssertEqual(merged.planType, "pro")
        XCTAssertEqual(merged.modelName, log.modelName)
        XCTAssertEqual(merged.lastRequestTokens, log.lastRequestTokens)
        XCTAssertEqual(merged.sevenDayTokens, log.sevenDayTokens)
        XCTAssertEqual(merged.trackedFileCount, log.trackedFileCount)
        XCTAssertEqual(merged.trackedEventCount, log.trackedEventCount)
    }

    func testApplyingPartialOfficialLimitsFallsBackToEachLogQuotaField() {
        let now = Date(timeIntervalSince1970: 1_000)
        let primaryResetAt = Date(timeIntervalSince1970: 2_000)
        let secondaryResetAt = Date(timeIntervalSince1970: 3_000)
        let log = CodexSnapshot(
            refreshedAt: now,
            latestEventAt: now.addingTimeInterval(-5),
            modelName: "gpt-5",
            planType: "plus",
            primaryQuota: QuotaWindow(label: "log primary", windowMinutes: 240, usedPercent: 70, resetAt: primaryResetAt),
            secondaryQuota: QuotaWindow(label: "log secondary", windowMinutes: 10_000, usedPercent: 60, resetAt: secondaryResetAt),
            lastRequestTokens: totals(1),
            latestSessionTotalTokens: totals(2),
            fiveHourTokens: totals(3),
            sevenDayTokens: totals(4),
            todayTokens: totals(5),
            yesterdayTokens: totals(6),
            thirtyDayTokens: totals(7),
            subscriptionCycleTokens: totals(8),
            trackedFileCount: 9,
            trackedEventCount: 10,
            message: "log message"
        )
        let official = OfficialRateLimits(
            primary: OfficialRateLimitWindow(usedPercent: nil, windowDurationMins: 300, resetsAt: 9_000),
            secondary: OfficialRateLimitWindow(usedPercent: 14, windowDurationMins: nil, resetsAt: nil),
            planType: nil
        )
        let refreshedAt = now.addingTimeInterval(10)

        let merged = official.applying(to: log, at: refreshedAt)

        XCTAssertEqual(merged.refreshedAt, refreshedAt)
        XCTAssertEqual(merged.latestEventAt, refreshedAt)
        XCTAssertEqual(merged.primaryQuota, QuotaWindow(
            label: log.primaryQuota.label,
            windowMinutes: 300,
            usedPercent: log.primaryQuota.usedPercent,
            resetAt: Date(timeIntervalSince1970: 9_000)
        ))
        XCTAssertEqual(merged.secondaryQuota, QuotaWindow(
            label: log.secondaryQuota.label,
            windowMinutes: log.secondaryQuota.windowMinutes,
            usedPercent: 14,
            resetAt: log.secondaryQuota.resetAt
        ))
        XCTAssertEqual(merged.modelName, log.modelName)
        XCTAssertEqual(merged.planType, log.planType)
        XCTAssertEqual(merged.lastRequestTokens, log.lastRequestTokens)
        XCTAssertEqual(merged.latestSessionTotalTokens, log.latestSessionTotalTokens)
        XCTAssertEqual(merged.fiveHourTokens, log.fiveHourTokens)
        XCTAssertEqual(merged.sevenDayTokens, log.sevenDayTokens)
        XCTAssertEqual(merged.todayTokens, log.todayTokens)
        XCTAssertEqual(merged.yesterdayTokens, log.yesterdayTokens)
        XCTAssertEqual(merged.thirtyDayTokens, log.thirtyDayTokens)
        XCTAssertEqual(merged.subscriptionCycleTokens, log.subscriptionCycleTokens)
        XCTAssertEqual(merged.trackedFileCount, log.trackedFileCount)
        XCTAssertEqual(merged.trackedEventCount, log.trackedEventCount)
        XCTAssertEqual(merged.message, log.message)
    }

    private func totals(_ seed: Int) -> TokenTotals {
        TokenTotals(
            inputTokens: seed,
            cachedInputTokens: seed + 10,
            outputTokens: seed + 20,
            reasoningOutputTokens: seed + 30,
            totalTokens: seed + 40
        )
    }
}
