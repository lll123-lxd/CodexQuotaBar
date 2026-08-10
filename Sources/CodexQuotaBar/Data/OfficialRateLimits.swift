import Foundation

struct OfficialRateLimitsResponse: Decodable, Equatable {
    let rateLimits: OfficialRateLimits
}

struct OfficialRateLimits: Decodable, Equatable {
    let primary: OfficialRateLimitWindow?
    let secondary: OfficialRateLimitWindow?
    let planType: String?

    func applying(to log: CodexSnapshot, at refreshedAt: Date) -> CodexSnapshot {
        CodexSnapshot(
            refreshedAt: refreshedAt,
            latestEventAt: refreshedAt,
            modelName: log.modelName,
            planType: planType ?? log.planType,
            primaryQuota: primary?.applying(to: log.primaryQuota) ?? log.primaryQuota,
            secondaryQuota: secondary?.applying(to: log.secondaryQuota) ?? log.secondaryQuota,
            lastRequestTokens: log.lastRequestTokens,
            latestSessionTotalTokens: log.latestSessionTotalTokens,
            fiveHourTokens: log.fiveHourTokens,
            sevenDayTokens: log.sevenDayTokens,
            todayTokens: log.todayTokens,
            yesterdayTokens: log.yesterdayTokens,
            thirtyDayTokens: log.thirtyDayTokens,
            subscriptionCycleTokens: log.subscriptionCycleTokens,
            trackedFileCount: log.trackedFileCount,
            trackedEventCount: log.trackedEventCount,
            message: log.message
        )
    }
}

struct OfficialRateLimitWindow: Decodable, Equatable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: TimeInterval?

    var remainingFraction: Double? {
        quota(label: "", fallbackMinutes: 0).remainingFraction
    }

    var resetAt: Date? {
        resetsAt.map(Date.init(timeIntervalSince1970:))
    }

    func applying(to fallback: QuotaWindow) -> QuotaWindow {
        QuotaWindow(
            label: fallback.label,
            windowMinutes: windowDurationMins ?? fallback.windowMinutes,
            usedPercent: usedPercent ?? fallback.usedPercent,
            resetAt: resetAt ?? fallback.resetAt
        )
    }

    func quota(label: String, fallbackMinutes: Int) -> QuotaWindow {
        QuotaWindow(
            label: label,
            windowMinutes: windowDurationMins ?? fallbackMinutes,
            usedPercent: usedPercent,
            resetAt: resetAt
        )
    }
}
