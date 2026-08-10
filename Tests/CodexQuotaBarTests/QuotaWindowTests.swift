import XCTest
@testable import CodexQuotaBar

final class QuotaWindowTests: XCTestCase {
    func testRemainingFractionUsesClampedRemainingPercent() {
        let quota = QuotaWindow(label: "7d quota", windowMinutes: 10_080, usedPercent: 14, resetAt: nil)

        XCTAssertEqual(quota.remainingPercent, 86)
        XCTAssertEqual(quota.remainingFraction ?? -1, 0.86, accuracy: 0.000_001)
        XCTAssertEqual(QuotaWindow(label: "x", windowMinutes: nil, usedPercent: -20, resetAt: nil).remainingFraction, 1)
        XCTAssertEqual(QuotaWindow(label: "x", windowMinutes: nil, usedPercent: 120, resetAt: nil).remainingFraction, 0)
    }

    func testCompactResetRemainingUsesCeilingOnlyForDays() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(makeQuota(now, 6 * 86_400 + 23 * 3_600).compactResetRemaining(from: now, language: .zhHans), "7天")
        XCTAssertEqual(makeQuota(now, 23 * 3_600 + 59 * 60).compactResetRemaining(from: now, language: .zhHans), "23小时")
        XCTAssertEqual(makeQuota(now, 59 * 60).compactResetRemaining(from: now, language: .zhHans), "59分钟")
        XCTAssertEqual(makeQuota(now, 30).compactResetRemaining(from: now, language: .zhHans), "即将重置")
        XCTAssertEqual(makeQuota(now, -1).compactResetRemaining(from: now, language: .english), "Resetting")
    }

    private func makeQuota(_ now: Date, _ delta: TimeInterval) -> QuotaWindow {
        QuotaWindow(label: "7d quota", windowMinutes: 10_080, usedPercent: 14, resetAt: now.addingTimeInterval(delta))
    }
}
