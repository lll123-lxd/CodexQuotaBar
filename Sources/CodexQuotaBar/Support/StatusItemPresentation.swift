import Foundation

enum QuotaConnectionState: Equatable {
    case logs
    case connecting
    case live(updatedAt: Date)
    case reconnecting(attempt: Int, message: String?)

    func label(language: AppLanguage) -> String {
        switch (self, language) {
        case (.logs, .zhHans): "日志回退"
        case (.logs, .english): "Log fallback"
        case (.connecting, .zhHans): "正在连接"
        case (.connecting, .english): "Connecting"
        case (.live, .zhHans): "实时"
        case (.live, .english): "Live"
        case (.reconnecting, .zhHans): "正在重连"
        case (.reconnecting, .english): "Reconnecting"
        }
    }
}

struct StatusItemPresentation: Equatable {
    let title: String
    let tooltip: String
    let progress: Double

    static func make(
        for snapshot: CodexSnapshot,
        source: QuotaConnectionState,
        now: Date,
        language: AppLanguage
    ) -> StatusItemPresentation {
        let quota = snapshot.secondaryQuota
        let remaining = quota.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "--%"
        let reset = quota.compactResetRemaining(from: now, language: language)
        let window = language == .zhHans ? "7 天" : "7-day"
        let sourceText = source.label(language: language)
        let used = quota.usedPercent.map { "\(Int($0.rounded()))%" } ?? "--"
        let absoluteReset = MetricFormatters.fullDate(quota.resetAt, language: language)
        let updated = MetricFormatters.fullDate(snapshot.refreshedAt, language: language)
        let tooltip = language == .zhHans
            ? "数据来源：\(sourceText)\n最后更新：\(updated)\n\(window)额度：已用 \(used)，剩余 \(remaining)\n重置：\(absoluteReset)"
            : "Source: \(sourceText)\nUpdated: \(updated)\n\(window) quota: \(used) used, \(remaining) left\nReset: \(absoluteReset)"

        return StatusItemPresentation(
            title: "\(remaining) · \(reset)",
            tooltip: tooltip,
            progress: quota.remainingFraction ?? 0
        )
    }
}
