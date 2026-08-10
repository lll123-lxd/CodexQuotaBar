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
}
