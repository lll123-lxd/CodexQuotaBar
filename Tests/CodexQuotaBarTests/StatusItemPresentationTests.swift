import XCTest
@testable import CodexQuotaBar

final class StatusItemPresentationTests: XCTestCase {
    func testMenuPresentationAlwaysUsesSecondaryQuota() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = SnapshotFixtures.make(
            now: now,
            primaryUsed: 75,
            secondaryUsed: 14,
            secondaryResetAt: now.addingTimeInterval(6 * 86_400 + 23 * 3_600)
        )

        let value = StatusItemPresentation.make(
            for: snapshot,
            source: .live(updatedAt: now),
            now: now,
            language: .zhHans
        )

        XCTAssertEqual(value.title, "86% · 7天")
        XCTAssertEqual(value.progress, 0.86, accuracy: 0.000_001)
        XCTAssertTrue(value.tooltip.contains("7 天"))
        XCTAssertTrue(value.tooltip.contains("实时"))
    }
}

enum SnapshotFixtures {
    static func make(
        now: Date,
        primaryUsed: Double?,
        secondaryUsed: Double?,
        secondaryResetAt: Date?
    ) -> CodexSnapshot {
        CodexSnapshot(
            refreshedAt: now,
            latestEventAt: now,
            modelName: "gpt-5",
            planType: "plus",
            primaryQuota: QuotaWindow(
                label: "5h quota",
                windowMinutes: 300,
                usedPercent: primaryUsed,
                resetAt: now.addingTimeInterval(5 * 3_600)
            ),
            secondaryQuota: QuotaWindow(
                label: "7d quota",
                windowMinutes: 10_080,
                usedPercent: secondaryUsed,
                resetAt: secondaryResetAt
            ),
            lastRequestTokens: .zero,
            latestSessionTotalTokens: .zero,
            fiveHourTokens: .zero,
            sevenDayTokens: .zero,
            todayTokens: .zero,
            yesterdayTokens: .zero,
            thirtyDayTokens: .zero,
            subscriptionCycleTokens: .zero,
            trackedFileCount: 1,
            trackedEventCount: 1,
            message: nil
        )
    }
}
