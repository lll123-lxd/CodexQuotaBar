# CodexQuotaBar Official Sync and Blue Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 CodexQuotaBar 中接入本机 Codex app-server 的真实 5 小时/7 天额度，把菜单栏改为蓝色 `86% · 7天`，并补齐同步进度条、重连、开机启动、测试、签名和验证。

**Architecture:** 保留 `CodexLogScanner` 负责 token 统计和自定义监控器额度；新增长连接 JSONL RPC 客户端读取官方 `account/rateLimits/read`，只覆盖默认 Codex 监控器的额度字段。`CodexUsageStore` 仍是唯一 UI 数据入口，并合并官方快照、日志快照和连接状态；菜单栏和 Popover 都只从同一个 `QuotaWindow.remainingFraction` 取比例。

**Tech Stack:** Swift 6.2、Swift Package Manager、AppKit、SwiftUI、Combine、Foundation `Process`/`Pipe`、ServiceManagement `SMAppService`、XCTest、zsh、codesign。

## Global Constraints

- 只修改现有 `CodexQuotaBar` 项目，不创建第二套应用。
- 最低系统保持 macOS 13，Swift tools version 保持 6.2，不新增第三方依赖。
- 不读取、复制、保存 ChatGPT token、密码或 API Key；只启动本机 `codex app-server` 使用现有登录态。
- 官方主数据源固定调用 `account/rateLimits/read`，监听 `account/rateLimits/updated`；本地日志保留为 token 统计和额度回退。
- 官方快照只覆盖 ID 为 `default-codex` 的监控器；自定义监控器继续读取各自日志目录。
- 菜单栏主指标固定为 7 天 `secondaryQuota`；5 小时 `primaryQuota` 只在 Popover 继续显示。
- 官方额度每 10 秒保底读取，打开 Popover 立即读取；每个初始化/读取请求的 watchdog 固定为 20 秒。
- 重连退避为 1、2、4、8、16、30 秒上限并带抖动；`-32001` 退避但不重启健康进程。
- 菜单栏环形图标和两条配额进度条使用系统 `systemBlue`；背景、轨道、边框和文字使用语义颜色。
- 进度文字、环形弧长、横向填充宽度必须共享 `QuotaWindow.remainingPercent` / `remainingFraction`。
- 开机启动使用 `SMAppService.mainApp`，默认关闭；注册失败时回滚到真实状态并显示错误。
- 构建脚本先运行测试；有 `CODE_SIGN_IDENTITY` 时使用指定身份，否则使用 ad-hoc `-`；最后严格验证签名。
- 当前 Windows 环境不能证明 AppKit、ServiceManagement、codesign 或 `.app` 运行通过；最终成功声明必须附 macOS 或 macOS CI 的新鲜输出。

---

## File Structure

**Create**

- `Sources/CodexQuotaBar/Data/OfficialRateLimits.swift`：官方响应结构、映射和日志快照覆盖。
- `Sources/CodexQuotaBar/Data/AppServerTransport.swift`：`codex` 定位、`Process`/`Pipe` JSONL 传输。
- `Sources/CodexQuotaBar/Data/CodexAppServerClient.swift`：初始化握手、RPC 请求匹配、20 秒超时、更新通知、退避重连。
- `Sources/CodexQuotaBar/Support/StatusItemPresentation.swift`：可测试的菜单标题、重置短文本和 tooltip 生成。
- `Sources/CodexQuotaBar/Support/LoginItemController.swift`：`SMAppService.mainApp` 适配和可测试状态机。
- `Tests/CodexQuotaBarTests/QuotaWindowTests.swift`
- `Tests/CodexQuotaBarTests/OfficialRateLimitsTests.swift`
- `Tests/CodexQuotaBarTests/CodexAppServerClientTests.swift`
- `Tests/CodexQuotaBarTests/CodexUsageStoreTests.swift`
- `Tests/CodexQuotaBarTests/StatusItemPresentationTests.swift`
- `Tests/CodexQuotaBarTests/LoginItemControllerTests.swift`
- `.github/workflows/macos.yml`：macOS 编译、测试和 ad-hoc 签名验证。

**Modify**

- `Package.swift`：增加 test target。
- `Sources/CodexQuotaBar/Data/Models.swift`：倒计时短文本和快照复制入口。
- `Sources/CodexQuotaBar/Data/CodexUsageStore.swift`：官方/日志双通道刷新、合并和连接状态。
- `Sources/CodexQuotaBar/App/AppCoordinator.swift`：7 天菜单标题、tooltip、代表项和打开立即刷新。
- `Sources/CodexQuotaBar/UI/RingImageRenderer.swift`：7 天比例和固定系统蓝。
- `Sources/CodexQuotaBar/UI/QuotaPopoverView.swift`：7 天优先、蓝色进度条、语义深浅色、数据来源状态。
- `Sources/CodexQuotaBar/UI/SettingsView.swift`：开机启动开关和错误文案。
- `Sources/CodexQuotaBar/Support/AppPreferences.swift`：默认刷新间隔改为 10 秒。
- `Sources/CodexQuotaBar/Support/AppText.swift`：开机启动中英文文案。
- `scripts/build_app.sh`：测试、签名和严格验证。
- `README.md`、`docs/ARCHITECTURE.md`、`docs/PRIVACY.md`：同步真实行为和运行方法。

---

### Task 1: 测试骨架、比例与菜单倒计时

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/CodexQuotaBar/Data/Models.swift`
- Create: `Sources/CodexQuotaBar/Support/StatusItemPresentation.swift`
- Create: `Tests/CodexQuotaBarTests/QuotaWindowTests.swift`
- Create: `Tests/CodexQuotaBarTests/StatusItemPresentationTests.swift`

**Interfaces:**
- Produces: `QuotaWindow.compactResetRemaining(from:language:) -> String`
- Produces: `StatusItemPresentation.make(for:source:now:language:) -> StatusItemPresentation`
- Produces: `QuotaConnectionState` cases used by Store and UI in later tasks。

- [ ] **Step 1: Add the XCTest target**

将 `Package.swift` 的 `targets` 改为：

```swift
targets: [
    .executableTarget(
        name: "CodexQuotaBar",
        path: "Sources/CodexQuotaBar"
    ),
    .testTarget(
        name: "CodexQuotaBarTests",
        dependencies: ["CodexQuotaBar"],
        path: "Tests/CodexQuotaBarTests"
    ),
]
```

- [ ] **Step 2: Write failing quota and status-title tests**

在 `QuotaWindowTests.swift` 写入：

```swift
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
```

在 `StatusItemPresentationTests.swift` 写入一个 `secondary=14% used`、`primary=75% used` 的快照，断言：

```swift
func testMenuPresentationAlwaysUsesSecondaryQuota() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let snapshot = SnapshotFixtures.make(
        now: now,
        primaryUsed: 75,
        secondaryUsed: 14,
        secondaryResetAt: now.addingTimeInterval(6 * 86_400 + 23 * 3_600)
    )
    let value = StatusItemPresentation.make(for: snapshot, source: .live(updatedAt: now), now: now, language: .zhHans)
    XCTAssertEqual(value.title, "86% · 7天")
    XCTAssertEqual(value.progress, 0.86, accuracy: 0.000_001)
    XCTAssertTrue(value.tooltip.contains("7 天"))
    XCTAssertTrue(value.tooltip.contains("实时"))
}
```

同文件加入完整夹具：

```swift
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
```

- [ ] **Step 3: Run the focused tests and confirm RED**

Run on macOS:

```bash
swift test --filter 'QuotaWindowTests|StatusItemPresentationTests'
```

Expected: FAIL，错误包含 `compactResetRemaining`、`StatusItemPresentation` 或 `QuotaConnectionState` 尚未定义；现有 `remainingFraction` 断言可以先通过。

- [ ] **Step 4: Implement minimal reset/status presentation logic**

在 `Models.swift` 的 `QuotaWindow` 内增加：

```swift
func compactResetRemaining(from now: Date, language: AppLanguage = .defaultLanguage) -> String {
    guard let resetAt else { return "--" }
    let seconds = Int(resetAt.timeIntervalSince(now))
    guard seconds >= 60 else {
        return language == .zhHans ? "即将重置" : "Resetting"
    }
    if seconds >= 86_400 {
        let days = Int(ceil(Double(seconds) / 86_400))
        return language == .zhHans ? "\(days)天" : "\(days)d"
    }
    if seconds >= 3_600 {
        let hours = seconds / 3_600
        return language == .zhHans ? "\(hours)小时" : "\(hours)h"
    }
    let minutes = seconds / 60
    return language == .zhHans ? "\(minutes)分钟" : "\(minutes)m"
}
```

创建 `StatusItemPresentation.swift`：

```swift
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
```

- [ ] **Step 5: Run tests and commit**

Run: `swift test --filter 'QuotaWindowTests|StatusItemPresentationTests'`

Expected: PASS，`86%` 与 `0.86` 来自同一个 secondary quota。

Commit:

```bash
git add Package.swift Sources/CodexQuotaBar/Data/Models.swift Sources/CodexQuotaBar/Support/StatusItemPresentation.swift Tests/CodexQuotaBarTests
git commit -m "test: define weekly quota presentation"
```

---

### Task 2: 官方额度响应解码与日志快照覆盖

**Files:**
- Create: `Sources/CodexQuotaBar/Data/OfficialRateLimits.swift`
- Create: `Tests/CodexQuotaBarTests/OfficialRateLimitsTests.swift`

**Interfaces:**
- Consumes: `QuotaWindow`、`CodexSnapshot`
- Produces: `OfficialRateLimitsResponse.rateLimits`
- Produces: `OfficialRateLimits.applying(to:at:) -> CodexSnapshot`

- [ ] **Step 1: Write failing decode/mapping tests**

测试固定响应：

```swift
let json = #"""
{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":2000},"secondary":{"usedPercent":14,"windowDurationMins":10080,"resetsAt":9000},"planType":"plus"}}
"""#.data(using: .utf8)!
let response = try JSONDecoder().decode(OfficialRateLimitsResponse.self, from: json)
XCTAssertEqual(response.rateLimits.primary?.usedPercent, 20)
XCTAssertEqual(response.rateLimits.secondary?.remainingFraction ?? -1, 0.86, accuracy: 0.000_001)
XCTAssertEqual(response.rateLimits.secondary?.resetAt, Date(timeIntervalSince1970: 9000))
```

再加入覆盖测试：

```swift
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
    let merged = official.applying(to: log, at: now.addingTimeInterval(10))

    XCTAssertEqual(merged.primaryQuota.usedPercent, 20)
    XCTAssertEqual(merged.secondaryQuota.remainingPercent, 86)
    XCTAssertEqual(merged.planType, "pro")
    XCTAssertEqual(merged.modelName, log.modelName)
    XCTAssertEqual(merged.sevenDayTokens, log.sevenDayTokens)
    XCTAssertEqual(merged.lastRequestTokens, log.lastRequestTokens)
    XCTAssertEqual(merged.trackedFileCount, log.trackedFileCount)
    XCTAssertEqual(merged.trackedEventCount, log.trackedEventCount)
}
```

- [ ] **Step 2: Run focused test and confirm RED**

Run: `swift test --filter OfficialRateLimitsTests`

Expected: FAIL with `cannot find OfficialRateLimitsResponse in scope`。

- [ ] **Step 3: Implement exact official models and copy-preserving overlay**

创建 `OfficialRateLimits.swift`：

```swift
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
            primaryQuota: primary?.quota(label: "5h quota", fallbackMinutes: 300) ?? log.primaryQuota,
            secondaryQuota: secondary?.quota(label: "7d quota", fallbackMinutes: 10_080) ?? log.secondaryQuota,
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

    func quota(label: String, fallbackMinutes: Int) -> QuotaWindow {
        QuotaWindow(
            label: label,
            windowMinutes: windowDurationMins ?? fallbackMinutes,
            usedPercent: usedPercent,
            resetAt: resetAt
        )
    }
}
```

- [ ] **Step 4: Run tests and commit**

Run: `swift test --filter OfficialRateLimitsTests`

Expected: PASS，14% used 映射为 86% remaining，日志 token 字段不变。

Commit:

```bash
git add Sources/CodexQuotaBar/Data/OfficialRateLimits.swift Tests/CodexQuotaBarTests/OfficialRateLimitsTests.swift
git commit -m "feat: decode official Codex rate limits"
```

---

### Task 3: 可替换的 JSONL 进程传输层

**Files:**
- Create: `Sources/CodexQuotaBar/Data/AppServerTransport.swift`
- Extend test support in: `Tests/CodexQuotaBarTests/CodexAppServerClientTests.swift`

**Interfaces:**
- Produces: `AppServerTransport` with `lines`, `start()`, `send(_:)`, `stop()`
- Produces: `AppServerTransportFactory`
- Produces: `CodexExecutableLocator.resolve(environment:fileExists:) -> URL?`
- Later consumed by: `CodexAppServerClient`

- [ ] **Step 1: Write failing executable-locator and fake-transport tests**

```swift
func testLocatorUsesPathBeforeHomebrewFallbacks() {
    let url = CodexExecutableLocator.resolve(
        environment: ["PATH": "/custom/bin:/usr/bin"],
        fileExists: { $0 == "/custom/bin/codex" }
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
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --filter CodexAppServerClientTests/testLocator`

Expected: FAIL because `CodexExecutableLocator` and `AppServerTransport` do not exist。

- [ ] **Step 3: Implement the transport contract and locator**

在 `AppServerTransport.swift` 定义：

```swift
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
        case .codexNotFound: "找不到 codex 可执行文件"
        case .notRunning: "Codex app-server 未运行"
        case let .processExited(code): "Codex app-server 已退出（\(code)）"
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
```

同文件加入完整进程传输；stderr 只 drain，绝不当作 JSON-RPC 输入：

```swift
actor ProcessAppServerTransport: AppServerTransport {
    nonisolated let lines: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let executableURL: URL
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var buffer = Data()
    private var streamFinished = false

    init(executableURL: URL) {
        self.executableURL = executableURL
        var captured: AsyncStream<Data>.Continuation!
        lines = AsyncStream { captured = $0 }
        continuation = captured
    }

    func start() async throws {
        guard process == nil else { return }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        inputHandle = inputPipe.fileHandleForWriting
        outputHandle = outputPipe.fileHandleForReading
        errorHandle = errorPipe.fileHandleForReading
        self.process = process

        outputHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.consume(data) }
        }
        errorHandle?.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] process in
            Task { await self?.didTerminate(code: process.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            await stop()
            throw error
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
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
        try? inputHandle?.close()
        try? outputHandle?.close()
        try? errorHandle?.close()
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        process = nil
        finishStream()
    }

    private func consume(_ data: Data) {
        guard !streamFinished else { return }
        guard !data.isEmpty else {
            finishStream()
            return
        }

        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.last == 0x0D { line.removeLast() }
            if !line.isEmpty { continuation.yield(line) }
        }
    }

    private func didTerminate(code: Int32) {
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        process = nil
        finishStream()
    }

    private func finishStream() {
        guard !streamFinished else { return }
        streamFinished = true
        if !buffer.isEmpty {
            if buffer.last == 0x0D { buffer.removeLast() }
            if !buffer.isEmpty { continuation.yield(buffer) }
            buffer.removeAll(keepingCapacity: false)
        }
        continuation.finish()
    }
}
```

- [ ] **Step 4: Add a deterministic fake transport for later RPC tests**

在测试文件内创建：

```swift
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

    func start() async { startCount += 1 }
    func send(_ line: Data) async { sent.append(line) }
    func stop() async { stopCount += 1; continuation.finish() }
    func emit(_ json: String) { continuation.yield(Data(json.utf8)) }
    func finish() { continuation.finish() }
}
```

- [ ] **Step 5: Run tests and commit**

Run: `swift test --filter CodexAppServerClientTests/testLocator`

Expected: PASS。

Commit:

```bash
git add Sources/CodexQuotaBar/Data/AppServerTransport.swift Tests/CodexQuotaBarTests/CodexAppServerClientTests.swift
git commit -m "feat: add Codex app-server transport"
```

---

### Task 4: RPC 握手、请求匹配、通知、20 秒 watchdog 与退避

**Files:**
- Create: `Sources/CodexQuotaBar/Data/CodexAppServerClient.swift`
- Modify: `Tests/CodexQuotaBarTests/CodexAppServerClientTests.swift`

**Interfaces:**
- Consumes: `AppServerTransportFactory`, `OfficialRateLimitsResponse`
- Produces: `OfficialRateLimitClient` protocol
- Produces: `CodexAppServerClient.events: AsyncStream<CodexAppServerEvent>`
- Produces: `readRateLimits() async throws -> OfficialRateLimits`, `stop() async`

- [ ] **Step 1: Write failing handshake, mapping and notification tests**

测试驱动 fake transport 时，按发送请求中的 `id` 回送响应：

```swift
func testHandshakeReadAndUpdatedNotification() async throws {
    let transport = FakeAppServerTransport()
    let client = CodexAppServerClient(
        factory: AppServerTransportFactory { transport },
        timeoutSeconds: 0.2,
        sleep: { _ in },
        jitter: { _ in 1 },
        now: { Date(timeIntervalSince1970: 1_000) }
    )
    let read = Task { try await client.readRateLimits() }

    var sent = try await waitForSentCount(1, transport: transport)
    let initialize = try jsonObject(sent[0])
    XCTAssertEqual(initialize["method"] as? String, "initialize")
    let clientInfo = (initialize["params"] as? [String: Any])?["clientInfo"] as? [String: Any]
    XCTAssertEqual(clientInfo?["name"] as? String, "codex-quota-bar")
    XCTAssertEqual(clientInfo?["title"] as? String, "CodexQuotaBar")
    XCTAssertEqual(clientInfo?["version"] as? String, "1.0.0")
    let initializeID = (initialize["id"] as! NSNumber).intValue
    await transport.emit("{\"id\":\(initializeID),\"result\":{}}")

    sent = try await waitForSentCount(3, transport: transport)
    XCTAssertEqual(try jsonObject(sent[1])["method"] as? String, "initialized")
    let rateRequest = try jsonObject(sent[2])
    XCTAssertEqual(rateRequest["method"] as? String, "account/rateLimits/read")
    let rateID = (rateRequest["id"] as! NSNumber).intValue
    await transport.emit("{\"id\":\(rateID),\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":20,\"windowDurationMins\":300,\"resetsAt\":2000},\"secondary\":{\"usedPercent\":14,\"windowDurationMins\":10080,\"resetsAt\":9000},\"planType\":\"plus\"}}}")

    let limits = try await read.value
    XCTAssertEqual(limits.secondary?.remainingFraction ?? -1, 0.86, accuracy: 0.000_001)

    var iterator = client.events.makeAsyncIterator()
    await transport.emit("{\"method\":\"account/rateLimits/updated\",\"params\":{\"rateLimits\":{\"secondary\":{\"usedPercent\":15}}}}")
    var foundUpdate = false
    for _ in 0..<4 {
        if await iterator.next() == .rateLimitsChanged {
            foundUpdate = true
            break
        }
    }
    XCTAssertTrue(foundUpdate)
    await client.stop()
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func waitForSentCount(
    _ count: Int,
    transport: FakeAppServerTransport
) async throws -> [Data] {
    for _ in 0..<100 {
        let sent = await transport.sent
        if sent.count >= count { return sent }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw CodexAppServerClientError.timeout
}
```

- [ ] **Step 2: Write failing timeout/restart/overload tests with injected clock**

先用纯函数锁死退避表：

```swift
func testReconnectBackoffScheduleAndCap() {
    XCTAssertEqual(CodexAppServerClient.requestTimeoutSeconds, 20)
    XCTAssertEqual((1...7).map { ReconnectBackoff.delay(for: $0, jitter: 1) }, [1, 2, 4, 8, 16, 30, 30])
    XCTAssertEqual(ReconnectBackoff.delay(for: 6, jitter: 1.1), 30)
}
```

用线程安全队列依次返回两个 fake transport，首个不回复 initialize，第二个正常回复：

```swift
func testTimeoutStopsOldTransportAndReconnects() async throws {
    let first = FakeAppServerTransport()
    let second = FakeAppServerTransport()
    let queue = LockedTransportQueue([first, second])
    let delays = LockedDelays()
    let client = CodexAppServerClient(
        factory: AppServerTransportFactory { try queue.next() },
        timeoutSeconds: 0.01,
        sleep: { delays.append($0) },
        jitter: { _ in 1 }
    )
    let read = Task { try await client.readRateLimits() }
    _ = try await waitForSentCount(1, transport: first)
    try await waitUntil { await first.stopCount == 1 }

    var sent = try await waitForSentCount(1, transport: second)
    var object = try jsonObject(sent[0])
    await second.emit("{\"id\":\((object["id"] as! NSNumber).intValue),\"result\":{}}")
    sent = try await waitForSentCount(3, transport: second)
    object = try jsonObject(sent[2])
    await second.emit("{\"id\":\((object["id"] as! NSNumber).intValue),\"result\":{\"rateLimits\":{\"primary\":null,\"secondary\":null,\"planType\":\"plus\"}}}")
    _ = try await read.value

    XCTAssertEqual(delays.values, [1])
    XCTAssertEqual(queue.makeCount, 2)
    await client.stop()
}
```

测试锁和等待 helper：

```swift
private final class LockedTransportQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [any AppServerTransport]
    private var count = 0
    init(_ transports: [any AppServerTransport]) { self.transports = transports }
    var makeCount: Int { lock.withLock { count } }
    func next() throws -> any AppServerTransport {
        try lock.withLock {
            guard !transports.isEmpty else { throw CodexAppServerClientError.disconnected }
            count += 1
            return transports.removeFirst()
        }
    }
}

private final class LockedDelays: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TimeInterval] = []
    var values: [TimeInterval] { lock.withLock { storage } }
    func append(_ value: TimeInterval) { lock.withLock { storage.append(value) } }
}

private func waitUntil(_ predicate: @escaping () async -> Bool) async throws {
    for _ in 0..<100 {
        if await predicate() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw CodexAppServerClientError.timeout
}

private func completeHandshakeAndReturnRateRequestID(
    _ transport: FakeAppServerTransport
) async throws -> Int {
    var sent = try await waitForSentCount(1, transport: transport)
    var object = try jsonObject(sent[0])
    await transport.emit("{\"id\":\((object["id"] as! NSNumber).intValue),\"result\":{}}")
    sent = try await waitForSentCount(3, transport: transport)
    object = try jsonObject(sent[2])
    return (object["id"] as! NSNumber).intValue
}
```

overload 和 malformed 路径写成：

```swift
func testOverloadBacksOffWithoutRestartingHealthyTransport() async throws {
    let transport = FakeAppServerTransport()
    let delays = LockedDelays()
    let client = CodexAppServerClient(
        factory: AppServerTransportFactory { transport },
        timeoutSeconds: 0.2,
        sleep: { delays.append($0) },
        jitter: { _ in 1 }
    )
    let read = Task { try await client.readRateLimits() }
    let firstRateID = try await completeHandshakeAndReturnRateRequestID(transport)
    await transport.emit("{\"id\":\(firstRateID),\"error\":{\"code\":-32001,\"message\":\"Server overloaded; retry later.\"}}")

    let sent = try await waitForSentCount(4, transport: transport)
    let secondRate = try jsonObject(sent[3])
    await transport.emit("{\"id\":\((secondRate["id"] as! NSNumber).intValue),\"result\":{\"rateLimits\":{\"primary\":null,\"secondary\":null,\"planType\":\"plus\"}}}")
    _ = try await read.value

    XCTAssertEqual(delays.values, [1])
    XCTAssertEqual(await transport.stopCount, 0)
    await client.stop()
}

func testMalformedMessageReconnectsAndDoesNotLeakPendingRequest() async throws {
    let first = FakeAppServerTransport()
    let second = FakeAppServerTransport()
    let queue = LockedTransportQueue([first, second])
    let client = CodexAppServerClient(
        factory: AppServerTransportFactory { try queue.next() },
        timeoutSeconds: 0.2,
        sleep: { _ in },
        jitter: { _ in 1 }
    )
    let read = Task { try await client.readRateLimits() }
    _ = try await waitForSentCount(1, transport: first)
    await first.emit("{bad json")
    try await waitUntil { await first.stopCount == 1 }

    let rateID = try await completeHandshakeAndReturnRateRequestID(second)
    await second.emit("{\"id\":\(rateID),\"result\":{\"rateLimits\":{\"primary\":null,\"secondary\":null,\"planType\":\"plus\"}}}")
    _ = try await read.value
    XCTAssertEqual(queue.makeCount, 2)
    await client.stop()
}
```

- [ ] **Step 3: Run focused tests and confirm RED**

Run: `swift test --filter CodexAppServerClientTests`

Expected: FAIL because client/event/protocol types are undefined。

- [ ] **Step 4: Implement the public client contract and RPC envelopes**

创建 `CodexAppServerClient.swift`，顶部类型固定为：

```swift
import Foundation

enum CodexAppServerEvent: Equatable {
    case stateChanged(QuotaConnectionState)
    case rateLimitsChanged
}

protocol OfficialRateLimitClient: Sendable {
    var events: AsyncStream<CodexAppServerEvent> { get }
    func readRateLimits() async throws -> OfficialRateLimits
    func stop() async
}

enum CodexAppServerClientError: LocalizedError, Equatable {
    case stopped
    case timeout
    case malformedMessage
    case rpc(code: Int, message: String)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .stopped: "Codex app-server 客户端已停止"
        case .timeout: "Codex app-server 20 秒内没有响应"
        case .malformedMessage: "Codex app-server 返回了无效消息"
        case let .rpc(code, message): "Codex app-server 错误 \(code)：\(message)"
        case .disconnected: "Codex app-server 连接已断开"
        }
    }
}

typealias ClientSleep = @Sendable (TimeInterval) async throws -> Void
typealias ClientJitter = @Sendable (ClosedRange<Double>) -> Double
typealias ClientNow = @Sendable () -> Date

enum ReconnectBackoff {
    static func delay(for attempt: Int, jitter: Double) -> TimeInterval {
        let schedule: [TimeInterval] = [1, 2, 4, 8, 16, 30]
        let base = schedule[min(max(attempt - 1, 0), schedule.count - 1)]
        return min(30, base * min(max(jitter, 0.9), 1.1))
    }
}

private struct RPCResponse<Result: Decodable>: Decodable {
    let id: Int
    let result: Result?
    let error: RPCFailure?
}

private struct RPCFailure: Decodable {
    let code: Int
    let message: String
}

private struct InitializeResponse: Decodable {
    init(from decoder: Decoder) throws {}
}

actor CodexAppServerClient: OfficialRateLimitClient {
    static let requestTimeoutSeconds: TimeInterval = 20
    nonisolated let events: AsyncStream<CodexAppServerEvent>
    private let eventContinuation: AsyncStream<CodexAppServerEvent>.Continuation
    private let factory: AppServerTransportFactory
    private let timeoutSeconds: TimeInterval
    private let sleep: ClientSleep
    private let jitter: ClientJitter
    private let now: ClientNow
    private var transport: (any AppServerTransport)?
    private var readerTask: Task<Void, Never>?
    private var connectionGeneration: UUID?
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var nextID = 1
    private var initialized = false
    private var stopped = false

    init(
        factory: AppServerTransportFactory = .live,
        timeoutSeconds: TimeInterval = Self.requestTimeoutSeconds,
        sleep: @escaping ClientSleep = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        jitter: @escaping ClientJitter = { Double.random(in: $0) },
        now: @escaping ClientNow = Date.init
    ) {
        self.factory = factory
        self.timeoutSeconds = timeoutSeconds
        self.sleep = sleep
        self.jitter = jitter
        self.now = now
        var captured: AsyncStream<CodexAppServerEvent>.Continuation!
        events = AsyncStream { captured = $0 }
        eventContinuation = captured
    }
}
```

RPC 请求写入时省略 `jsonrpc`，每条消息用 `JSONSerialization` 生成；响应先用顶层 `id` 匹配 `pending`，再由泛型 `RPCResponse<Result>` 解码。notification 只检查顶层 `method`。

- [ ] **Step 5: Implement handshake, timeout cancellation and receive routing**

在 actor 内加入完整连接、请求和接收实现：

```swift
private func ensureConnected() async throws {
    if initialized { return }
    guard !stopped else { throw CodexAppServerClientError.stopped }

    let candidate = try factory.make()
    let generation = UUID()
    transport = candidate
    connectionGeneration = generation

    do {
        try await candidate.start()
        readerTask = Task { [weak self, candidate] in
            for await line in candidate.lines {
                await self?.receive(line, generation: generation)
            }
            await self?.connectionEnded(generation: generation)
        }
        let _: InitializeResponse = try await request("initialize", params: [
            "clientInfo": [
                "name": "codex-quota-bar",
                "title": "CodexQuotaBar",
                "version": "1.0.0",
            ],
        ])
        try await sendNotification("initialized", params: [:])
        initialized = true
    } catch {
        await invalidateConnection(error)
        throw error
    }
}

private func request<Result: Decodable>(
    _ method: String,
    params: [String: Any]
) async throws -> Result {
    let id = nextID
    nextID += 1
    let payload = try JSONSerialization.data(withJSONObject: [
        "id": id,
        "method": method,
        "params": params,
    ])
    let responseData = try await performRequest(id: id, payload: payload)
    let response: RPCResponse<Result>
    do {
        response = try JSONDecoder().decode(RPCResponse<Result>.self, from: responseData)
    } catch {
        throw CodexAppServerClientError.malformedMessage
    }
    if let failure = response.error {
        throw CodexAppServerClientError.rpc(code: failure.code, message: failure.message)
    }
    guard let result = response.result else {
        throw CodexAppServerClientError.malformedMessage
    }
    return result
}

private func sendNotification(_ method: String, params: [String: Any]) async throws {
    guard let transport else { throw CodexAppServerClientError.disconnected }
    let payload = try JSONSerialization.data(withJSONObject: [
        "method": method,
        "params": params,
    ])
    try await transport.send(payload)
}

private func performRequest(id: Int, payload: Data) async throws -> Data {
    let timeoutSeconds = self.timeoutSeconds
    return try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask { try await self.waitForResponse(id: id, payload: payload) }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            try Task.checkCancellation()
            throw CodexAppServerClientError.timeout
        }
        do {
            guard let first = try await group.next() else {
                throw CodexAppServerClientError.disconnected
            }
            group.cancelAll()
            return first
        } catch {
            group.cancelAll()
            throw error
        }
    }
}

private func waitForResponse(id: Int, payload: Data) async throws -> Data {
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { await self.write(payload, id: id) }
        }
    } onCancel: {
        Task { await self.cancelPending(id: id) }
    }
}

private func write(_ payload: Data, id: Int) async {
    guard let transport else {
        failPending(id: id, error: CodexAppServerClientError.disconnected)
        return
    }
    do {
        try await transport.send(payload)
    } catch {
        failPending(id: id, error: error)
        await invalidateConnection(error)
    }
}

private func cancelPending(id: Int) {
    pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
}

private func failPending(id: Int, error: Error) {
    pending.removeValue(forKey: id)?.resume(throwing: error)
}

private func receive(_ line: Data, generation: UUID) async {
    guard generation == connectionGeneration else { return }
    guard let value = try? JSONSerialization.jsonObject(with: line),
          let object = value as? [String: Any] else {
        await invalidateConnection(CodexAppServerClientError.malformedMessage)
        return
    }
    if let method = object["method"] as? String {
        if method == "account/rateLimits/updated" {
            eventContinuation.yield(.rateLimitsChanged)
        }
        return
    }
    guard let number = object["id"] as? NSNumber else { return }
    pending.removeValue(forKey: number.intValue)?.resume(returning: line)
}

private func connectionEnded(generation: UUID) async {
    guard generation == connectionGeneration, !stopped else { return }
    eventContinuation.yield(.stateChanged(.reconnecting(attempt: 1, message: "Connection closed")))
    await invalidateConnection(CodexAppServerClientError.disconnected)
}

private func invalidateConnection(_ error: Error) async {
    let oldTransport = transport
    transport = nil
    initialized = false
    connectionGeneration = nil
    let oldReader = readerTask
    readerTask = nil
    oldReader?.cancel()
    let continuations = pending.values
    pending.removeAll()
    continuations.forEach { $0.resume(throwing: error) }
    await oldTransport?.stop()
}

```

`performRequest` 的响应任务通过 cancellation handler 在超时/取消时从 `pending` 移除并 resume，保证没有 continuation 泄漏。收到 EOF、退出或 malformed JSON 时对全部 `pending` resume throwing。

- [ ] **Step 6: Implement retry semantics and full read**

`readRateLimits()` 的循环语义固定为：

```swift
func readRateLimits() async throws -> OfficialRateLimits {
    var attempt = 0
    while !stopped {
        do {
            if transport == nil {
                eventContinuation.yield(.stateChanged(attempt == 0 ? .connecting : .reconnecting(attempt: attempt, message: nil)))
            }
            try await ensureConnected()
            let response: OfficialRateLimitsResponse = try await request("account/rateLimits/read", params: [:])
            eventContinuation.yield(.stateChanged(.live(updatedAt: now())))
            return response.rateLimits
        } catch let CodexAppServerClientError.rpc(code, _) where code == -32001 {
            attempt += 1
            eventContinuation.yield(.stateChanged(.reconnecting(attempt: attempt, message: "Server overloaded")))
            try await sleep(ReconnectBackoff.delay(for: attempt, jitter: jitter(0.9...1.1)))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            attempt += 1
            await invalidateConnection(error)
            eventContinuation.yield(.stateChanged(.reconnecting(attempt: attempt, message: error.localizedDescription)))
            try await sleep(ReconnectBackoff.delay(for: attempt, jitter: jitter(0.9...1.1)))
        }
    }
    throw CodexAppServerClientError.stopped
}

func stop() async {
    guard !stopped else { return }
    stopped = true
    await invalidateConnection(CodexAppServerClientError.stopped)
    eventContinuation.finish()
}
```

`ReconnectBackoff` 先取 `[1, 2, 4, 8, 16, 30]`，再乘 clamp 到 `0.9...1.1` 的 jitter；overload 分支不得调用 `invalidateConnection`。`receive` 遇到 `account/rateLimits/updated` 只 yield `.rateLimitsChanged`。

- [ ] **Step 7: Run tests and commit**

Run: `swift test --filter CodexAppServerClientTests`

Expected: PASS；无 hanging tests，20 秒通过注入 timeout/sleeper 在毫秒级完成。

Commit:

```bash
git add Sources/CodexQuotaBar/Data/CodexAppServerClient.swift Tests/CodexQuotaBarTests/CodexAppServerClientTests.swift
git commit -m "feat: supervise official Codex quota RPC"
```

---

### Task 5: Store 双通道刷新、默认监控器覆盖和回退

**Files:**
- Modify: `Sources/CodexQuotaBar/Data/CodexUsageStore.swift`
- Modify: `Sources/CodexQuotaBar/Support/AppPreferences.swift`
- Create: `Tests/CodexQuotaBarTests/CodexUsageStoreTests.swift`

**Interfaces:**
- Consumes: `OfficialRateLimitClient.events/readRateLimits/stop`
- Produces: `@Published connectionState`
- Produces: `connectionState(for:)`
- Preserves: `refreshNow()` as AppCoordinator/Popover call site。

- [ ] **Step 1: Write failing merge/fallback/coalescing tests**

用 `FakeOfficialRateLimitClient` 和注入的 `snapshotLoader` 测试：

1. 启动后日志扫描和官方读取都各调用一次。
2. 官方返回 14% weekly used 后，`default-codex` 显示 86%，自定义 monitor 保持日志值。
3. 官方未成功时默认 monitor 使用日志额度且状态为 `.logs`/`.reconnecting`。
4. 已有官方快照后连接失败，数值保持最后官方值，状态变为 `.reconnecting`。
5. 一次官方读取进行中触发三次 `refreshNow()`，完成后只再执行一次读取。
6. `.rateLimitsChanged` 事件触发完整 read，而不是直接应用稀疏通知。
7. `stop()` 取消 timer/event/read tasks 并调用 client.stop。

测试 fake 固定为可手动完成每次读取的 actor：

```swift
actor FakeOfficialRateLimitClient: OfficialRateLimitClient {
    nonisolated let events: AsyncStream<CodexAppServerEvent>
    private let eventContinuation: AsyncStream<CodexAppServerEvent>.Continuation
    private var reads: [CheckedContinuation<OfficialRateLimits, Error>] = []
    private(set) var readCount = 0
    private(set) var stopCount = 0

    init() {
        var captured: AsyncStream<CodexAppServerEvent>.Continuation!
        events = AsyncStream { captured = $0 }
        eventContinuation = captured
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

    func emit(_ event: CodexAppServerEvent) { eventContinuation.yield(event) }

    func stop() {
        stopCount += 1
        reads.forEach { $0.resume(throwing: CancellationError()) }
        reads.removeAll()
        eventContinuation.finish()
    }
}
```

核心覆盖与 coalescing 测试写成：

```swift
@MainActor
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
    await client.succeed(OfficialRateLimits(
        primary: OfficialRateLimitWindow(usedPercent: 20, windowDurationMins: 300, resetsAt: 2_000_000),
        secondary: OfficialRateLimitWindow(usedPercent: 14, windowDurationMins: 10_080, resetsAt: 3_000_000),
        planType: "plus"
    ))

    try await waitUntil { await client.readCount == 2 }
    XCTAssertEqual(store.monitorSnapshots.first { $0.id == "default-codex" }?.snapshot.secondaryQuota.remainingPercent, 86)
    XCTAssertEqual(store.monitorSnapshots.first { $0.id == "custom" }?.snapshot.secondaryQuota.remainingPercent, 70)

    await client.emit(.stateChanged(.reconnecting(attempt: 1, message: "test")))
    try await Task.sleep(nanoseconds: 10_000_000)
    XCTAssertEqual(store.monitorSnapshots.first { $0.id == "default-codex" }?.snapshot.secondaryQuota.remainingPercent, 86)
    if case .reconnecting = store.connectionState {} else { XCTFail("expected reconnecting") }

    store.stop()
    try await waitUntil { await client.stopCount == 1 }
}
```

测试 helpers 和另外两个路径固定为：

```swift
private enum StoreTestError: Error { case failed, timedOut }

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

@MainActor
func testUpdatedNotificationTriggersOneFullRead() async throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let client = FakeOfficialRateLimitClient()
    let target = makeTarget(id: "default-codex")
    let store = CodexUsageStore(
        officialClient: client,
        snapshotLoader: { _, date in
            SnapshotFixtures.make(now: date, primaryUsed: 50, secondaryUsed: 50, secondaryResetAt: nil)
        },
        monitorTargets: { [target] },
        now: { now }
    )
    store.start()
    try await waitUntil { await client.readCount == 1 }
    await client.succeed(OfficialRateLimits(primary: nil, secondary: nil, planType: nil))
    try await waitUntil { store.connectionState == .live(updatedAt: now) }
    await client.emit(.rateLimitsChanged)
    try await waitUntil { await client.readCount == 2 }
    XCTAssertEqual(await client.readCount, 2)
    store.stop()
}

@MainActor
func testFirstOfficialFailureKeepsLogFallback() async throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let client = FakeOfficialRateLimitClient()
    let target = makeTarget(id: "default-codex")
    let store = CodexUsageStore(
        officialClient: client,
        snapshotLoader: { _, date in
            SnapshotFixtures.make(now: date, primaryUsed: 40, secondaryUsed: 30, secondaryResetAt: nil)
        },
        monitorTargets: { [target] },
        now: { now }
    )
    store.start()
    try await waitUntil { await client.readCount == 1 && store.monitorSnapshots.count == 1 }
    await client.fail(StoreTestError.failed)
    try await waitUntil { store.connectionState == .logs }
    XCTAssertEqual(store.monitorSnapshots[0].snapshot.secondaryQuota.remainingPercent, 70)
    store.stop()
}
```

- [ ] **Step 2: Run focused test and confirm RED**

Run: `swift test --filter CodexUsageStoreTests`

Expected: FAIL because Store does not accept injected client/loader and has no connection state。

- [ ] **Step 3: Refactor Store with exact injected boundaries**

在 `CodexUsageStore.swift` 顶部增加：

```swift
typealias SnapshotLoader = @Sendable (MonitorTarget, Date) -> CodexSnapshot

@MainActor
final class CodexUsageStore: ObservableObject {
    static let officialRefreshInterval: TimeInterval = 10
    @Published private(set) var monitorSnapshots: [MonitorSnapshot] = []
    @Published private(set) var connectionState: QuotaConnectionState = .logs

    private let officialClient: any OfficialRateLimitClient
    private let snapshotLoader: SnapshotLoader
    private let monitorTargets: @Sendable () -> [MonitorTarget]
    private let now: @Sendable () -> Date
    private var latestOfficial: OfficialRateLimits?
    private var latestOfficialAt: Date?
    private var officialReadTask: Task<Void, Never>?
    private var officialPollTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var logRefreshTask: Task<Void, Never>?
    private var isLogRefreshing = false
    private var logRefreshPending = false
    private var officialRefreshPending = false
    private var isRunning = false

    init(
        officialClient: any OfficialRateLimitClient = CodexAppServerClient(),
        snapshotLoader: @escaping SnapshotLoader = { target, now in
            CodexLogScanner(sessionsRoot: target.sessionsURL, configURL: target.configURL).loadSnapshot(now: now)
        },
        monitorTargets: @escaping @Sendable () -> [MonitorTarget] = {
            AppPreferences.monitorTargets.filter(\.isEnabled)
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.officialClient = officialClient
        self.snapshotLoader = snapshotLoader
        self.monitorTargets = monitorTargets
        self.now = now
    }
}
```

保留现有串行 `refreshQueue` 做日志扫描；加入以下入口和日志合并方法：

```swift
var snapshot: CodexSnapshot {
    monitorSnapshots.first?.snapshot ?? .empty
}

func connectionState(for target: MonitorTarget) -> QuotaConnectionState {
    target.id == "default-codex" ? connectionState : .logs
}

func refreshNow() {
    guard isRunning else { return }
    refreshLogs()
    refreshOfficial()
}

private func refreshLogs() {
    guard !isLogRefreshing else {
        logRefreshPending = true
        return
    }
    isLogRefreshing = true
    let targets = monitorTargets()
    let scanDate = now()
    let loader = snapshotLoader

    refreshQueue.async { [weak self] in
        let snapshots = targets.map {
            MonitorSnapshot(target: $0, snapshot: loader($0, scanDate))
        }
        Task { @MainActor [weak self] in
            self?.finishLogRefresh(snapshots)
        }
    }
}

private func finishLogRefresh(_ snapshots: [MonitorSnapshot]) {
    guard isRunning else {
        isLogRefreshing = false
        logRefreshPending = false
        return
    }
    monitorSnapshots = snapshots.map { monitor in
        guard monitor.target.id == "default-codex",
              let latestOfficial,
              let latestOfficialAt else { return monitor }
        return MonitorSnapshot(
            target: monitor.target,
            snapshot: latestOfficial.applying(to: monitor.snapshot, at: latestOfficialAt)
        )
    }
    isLogRefreshing = false
    if logRefreshPending {
        logRefreshPending = false
        refreshLogs()
    }
}
```

只有 target ID `default-codex` 调用 `latestOfficial.applying`；自定义 target 永不覆盖。

- [ ] **Step 4: Implement official event/poll/coalescing lifecycle**

`start()`、事件处理、官方 coalescing 和 `stop()` 使用以下实现：

```swift
func start() {
    guard !isRunning else { return }
    isRunning = true
    preferencesObserver = NotificationCenter.default.publisher(for: AppPreferences.didChangeNotification)
        .sink { [weak self] _ in
            self?.restartLogTimer()
            self?.refreshNow()
        }
    let client = officialClient
    eventTask = Task { [weak self] in
        for await event in client.events {
            guard !Task.isCancelled else { break }
            self?.handle(event)
        }
    }
    refreshNow()
    restartLogTimer()
    restartOfficialPollTimer()
}

private func handle(_ event: CodexAppServerEvent) {
    switch event {
    case let .stateChanged(state):
        connectionState = state
        if case .reconnecting = state, officialReadTask == nil {
            refreshOfficial()
        }
    case .rateLimitsChanged:
        refreshOfficial()
    }
}

private func refreshOfficial() {
    guard officialReadTask == nil else {
        officialRefreshPending = true
        return
    }
    let client = officialClient
    officialReadTask = Task { [weak self] in
        defer { self?.finishOfficialRefresh() }
        do {
            let limits = try await client.readRateLimits()
            guard !Task.isCancelled else { return }
            self?.receiveOfficial(limits)
        } catch is CancellationError {
            return
        } catch {
            if self?.latestOfficial == nil { self?.connectionState = .logs }
        }
    }
}

private func receiveOfficial(_ limits: OfficialRateLimits) {
    let fetchedAt = now()
    latestOfficial = limits
    latestOfficialAt = fetchedAt
    connectionState = .live(updatedAt: fetchedAt)
    monitorSnapshots = monitorSnapshots.map { monitor in
        guard monitor.target.id == "default-codex" else { return monitor }
        return MonitorSnapshot(
            target: monitor.target,
            snapshot: limits.applying(to: monitor.snapshot, at: fetchedAt)
        )
    }
}

private func finishOfficialRefresh() {
    officialReadTask = nil
    if isRunning && officialRefreshPending {
        officialRefreshPending = false
        refreshOfficial()
    }
}

func stop() {
    isRunning = false
    logRefreshPending = false
    officialRefreshPending = false
    logRefreshTask?.cancel()
    officialPollTask?.cancel()
    officialReadTask?.cancel()
    eventTask?.cancel()
    logRefreshTask = nil
    officialPollTask = nil
    officialReadTask = nil
    eventTask = nil
    preferencesObserver = nil
    let client = officialClient
    Task { await client.stop() }
}
```

两个 timer 的实现固定为：

```swift
private func restartLogTimer() {
    logRefreshTask?.cancel()
    let interval = AppPreferences.refreshInterval
    logRefreshTask = Task { [weak self] in
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { break }
            self?.refreshLogs()
        }
    }
}

private func restartOfficialPollTimer() {
    officialPollTask?.cancel()
    officialPollTask = Task { [weak self] in
        while !Task.isCancelled {
            try? await Task.sleep(
                nanoseconds: UInt64(Self.officialRefreshInterval * 1_000_000_000)
            )
            guard !Task.isCancelled else { break }
            self?.refreshOfficial()
        }
    }
}
```

把 `AppPreferences.defaultRefreshInterval` 从 `20.0` 改为 `10.0`，保留 `[10, 20, 30, 60]` 可选项；官方 poll 始终使用 Store 的 10 秒常量。

- [ ] **Step 5: Run tests and commit**

Run: `swift test --filter CodexUsageStoreTests`

Expected: PASS；默认 monitor 和 custom monitor 的来源规则、最后有效值、coalescing 均符合测试。

Commit:

```bash
git add Sources/CodexQuotaBar/Data/CodexUsageStore.swift Sources/CodexQuotaBar/Support/AppPreferences.swift Tests/CodexQuotaBarTests/CodexUsageStoreTests.swift
git commit -m "feat: merge official quotas with local usage"
```

---

### Task 6: 7 天菜单栏与深浅色蓝色进度 UI

**Files:**
- Modify: `Sources/CodexQuotaBar/App/AppCoordinator.swift`
- Modify: `Sources/CodexQuotaBar/UI/RingImageRenderer.swift`
- Modify: `Sources/CodexQuotaBar/UI/QuotaPopoverView.swift`
- Modify: `Tests/CodexQuotaBarTests/StatusItemPresentationTests.swift`

**Interfaces:**
- Consumes: `StatusItemPresentation`, `CodexUsageStore.connectionState(for:)`
- Preserves: compact 500 × 760 Popover and existing monitor sidebar/actions。

- [ ] **Step 1: Extend failing presentation tests**

增加以下测试（`makeMonitor` 使用 Task 1 的 `SnapshotFixtures.make` 并构造 `MonitorTarget`）：

```swift
func testRepresentativeMonitorUsesTightestWeeklyQuota() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let primaryTight = makeMonitor(id: "a", now: now, primaryUsed: 95, secondaryUsed: 10)
    let weeklyTight = makeMonitor(id: "b", now: now, primaryUsed: 20, secondaryUsed: 90)
    XCTAssertEqual(
        StatusItemPresentation.representativeWeeklyMonitor(from: [primaryTight, weeklyTight])?.id,
        "b"
    )
}

func testMissingQuotaUsesPlaceholders() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let snapshot = SnapshotFixtures.make(now: now, primaryUsed: nil, secondaryUsed: nil, secondaryResetAt: nil)
    let value = StatusItemPresentation.make(for: snapshot, source: .logs, now: now, language: .zhHans)
    XCTAssertEqual(value.title, "--% · --")
    XCTAssertEqual(value.progress, 0)
}

func testEnglishWeeklyTitle() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let snapshot = SnapshotFixtures.make(
        now: now,
        primaryUsed: 75,
        secondaryUsed: 14,
        secondaryResetAt: now.addingTimeInterval(7 * 86_400)
    )
    let value = StatusItemPresentation.make(for: snapshot, source: .live(updatedAt: now), now: now, language: .english)
    XCTAssertEqual(value.title, "86% · 7d")
}
```

测试 helper 固定为：

```swift
private func makeMonitor(
    id: String,
    now: Date,
    primaryUsed: Double,
    secondaryUsed: Double
) -> MonitorSnapshot {
    let target = MonitorTarget(
        id: id,
        name: id,
        systemImage: "speedometer",
        colorHex: "#0000FF",
        sessionsPath: "/tmp/\(id)",
        configPath: "/tmp/\(id).toml",
        isEnabled: true
    )
    return MonitorSnapshot(
        target: target,
        snapshot: SnapshotFixtures.make(
            now: now,
            primaryUsed: primaryUsed,
            secondaryUsed: secondaryUsed,
            secondaryResetAt: now.addingTimeInterval(7 * 86_400)
        )
    )
}
```

- [ ] **Step 2: Run focused test and confirm RED**

Run: `swift test --filter StatusItemPresentationTests`

Expected: FAIL because weekly representative helper is not defined。

- [ ] **Step 3: Change status item to weekly title and blue weekly ring**

在 `StatusItemPresentation.swift` 增加：

```swift
static func representativeWeeklyMonitor(from snapshots: [MonitorSnapshot]) -> MonitorSnapshot? {
    snapshots.min {
        ($0.snapshot.secondaryQuota.remainingPercent ?? .greatestFiniteMagnitude)
        < ($1.snapshot.secondaryQuota.remainingPercent ?? .greatestFiniteMagnitude)
    }
}
```

`AppCoordinator.updateStatusItem` 使用：

```swift
let source = monitor.map { store.connectionState(for: $0.target) } ?? .logs
let presentation = StatusItemPresentation.make(
    for: snapshot,
    source: source,
    now: Date(),
    language: AppPreferences.language
)
let title = presentation.title
button.image = RingImageRenderer.makeStatusImage(progress: presentation.progress)
button.toolTip = monitor.map { "\($0.target.name)\n\(presentation.tooltip)" } ?? presentation.tooltip
```

代表 monitor 改调 `StatusItemPresentation.representativeWeeklyMonitor`。debug JSON 的 `remainingPercent`、`usedPercent`、`resetAt` 改为 secondary，并加入 `source`。`togglePopover` 保留显示前 `store.refreshNow()`，不得挪到显示之后。

`RingImageRenderer` API 改为：

```swift
static func makeStatusImage(progress: Double) -> NSImage
```

弧长 clamp `progress`，轨道继续 `labelColor.withAlphaComponent(0.16)`，填充固定 `NSColor.systemBlue`，删除 `statusColor(for:)` 及绿/橙/红分支。

- [ ] **Step 4: Make Popover weekly-first and semantic blue**

配额顺序精确改为：

```swift
quotaLine(title: text.sevenDayQuotaTitle, quota: monitor.snapshot.secondaryQuota)
quotaLine(title: text.fiveHourQuotaTitle, quota: monitor.snapshot.primaryQuota)
```

进度条填充使用：

```swift
Capsule()
    .fill(Color(nsColor: .systemBlue))
    .frame(width: max(0, proxy.size.width * min(max(progress, 0), 1)))
```

轨道改 `Color(nsColor: .separatorColor).opacity(0.35)`；删除 94% 白色标记线和固定绿色状态点。根背景改 `Color(nsColor: .windowBackgroundColor)`；header/button capsule 改 `controlBackgroundColor` 和 `separatorColor`，文字保留 `.primary/.secondary`。连接状态在配额标题下显示 `store.connectionState(for: monitor.target).label(language:)`，重连时不清空旧额度。

`creditsSection` 现有 savings progress 同样把黑色轨道改为 `separatorColor.opacity(0.35)`、填充改为 `systemBlue`，但宽度仍使用 `savingsProgress`，不得误接到 quota 数据。这样全 Popover 在深色模式下不残留近黑硬编码条。

- [ ] **Step 5: Reuse existing localized quota titles without duplicate state logic**

连接状态继续统一调用 `QuotaConnectionState.label(language:)`，不在 SwiftUI 中重复 switch。配额标题改用已经存在的 `fiveHourQuotaTitle/sevenDayQuotaTitle`，不再调用重复的 `sessionQuotaTitle/weeklyQuotaTitle`。

- [ ] **Step 6: Run tests, static color scan and commit**

Run:

```bash
swift test --filter StatusItemPresentationTests
rg -n 'Color\.white|Color\.black|Color\.green|systemGreen|systemOrange|systemRed' Sources/CodexQuotaBar/UI/QuotaPopoverView.swift Sources/CodexQuotaBar/UI/RingImageRenderer.swift
```

Expected: tests PASS；`rg` 不应命中配额 UI 的硬编码黑白绿橙红（若别的非配额组件保留，逐项确认语义而不是批量删除）。

Commit:

```bash
git add Sources/CodexQuotaBar/App/AppCoordinator.swift Sources/CodexQuotaBar/UI/RingImageRenderer.swift Sources/CodexQuotaBar/UI/QuotaPopoverView.swift Tests/CodexQuotaBarTests/StatusItemPresentationTests.swift
git commit -m "feat: show weekly quota with macOS blue progress"
```

---

### Task 7: `SMAppService` 开机启动设置

**Files:**
- Create: `Sources/CodexQuotaBar/Support/LoginItemController.swift`
- Modify: `Sources/CodexQuotaBar/UI/SettingsView.swift`
- Modify: `Sources/CodexQuotaBar/Support/AppText.swift`
- Create: `Tests/CodexQuotaBarTests/LoginItemControllerTests.swift`

**Interfaces:**
- Produces: `LoginItemManaging` test seam
- Produces: `@MainActor LoginItemController.isEnabled/requiresApproval/errorMessage/setEnabled(_:)`

- [ ] **Step 1: Write failing controller rollback tests**

写入以下 fake 和状态/回滚测试：

```swift
import XCTest
@testable import CodexQuotaBar

private enum LoginItemTestError: Error { case denied }

private final class FakeLoginItemManager: LoginItemManaging {
    var status: LoginItemStatus
    var registerResult: Result<Void, Error> = .success(())
    var unregisterResult: Result<Void, Error> = .success(())

    init(status: LoginItemStatus) { self.status = status }

    func register() throws {
        try registerResult.get()
        status = .enabled
    }

    func unregister() throws {
        try unregisterResult.get()
        status = .notRegistered
    }
}

@MainActor
final class LoginItemControllerTests: XCTestCase {
    func testStatusMappingAndApproval() {
        let manager = FakeLoginItemManager(status: .requiresApproval)
        let controller = LoginItemController(manager: manager)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(controller.requiresApproval)

        manager.status = .enabled
        controller.refresh()
        XCTAssertTrue(controller.isEnabled)
        XCTAssertFalse(controller.requiresApproval)
    }

    func testRegistrationFailureRollsBackToManagerStatus() {
        let manager = FakeLoginItemManager(status: .notRegistered)
        manager.registerResult = .failure(LoginItemTestError.denied)
        let controller = LoginItemController(manager: manager)

        controller.setEnabled(true)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(manager.status, .notRegistered)
    }

    func testSuccessfulUnregisterReadsRealStatus() {
        let manager = FakeLoginItemManager(status: .enabled)
        let controller = LoginItemController(manager: manager)
        controller.setEnabled(false)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(manager.status, .notRegistered)
    }
}
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --filter LoginItemControllerTests`

Expected: FAIL because login item types do not exist。

- [ ] **Step 3: Implement ServiceManagement adapter and controller**

创建 `LoginItemController.swift`：

```swift
import Combine
import ServiceManagement

enum LoginItemStatus: Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
}

protocol LoginItemManaging {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

struct MainAppLoginItemManager: LoginItemManaging {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var errorMessage: String?
    private let manager: any LoginItemManaging

    init(manager: any LoginItemManaging = MainAppLoginItemManager()) {
        self.manager = manager
        refresh()
    }

    func refresh() {
        isEnabled = manager.status == .enabled
        requiresApproval = manager.status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try manager.register()
            } else {
                try manager.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }
}
```

- [ ] **Step 4: Wire Settings UI to real state**

`SettingsView` 增加：

```swift
@StateObject private var loginItemController = LoginItemController()

private var launchAtLoginBinding: Binding<Bool> {
    Binding(
        get: { loginItemController.isEnabled },
        set: { loginItemController.setEnabled($0) }
    )
}
```

在 Behavior section 首项插入：

```swift
Toggle(text.launchAtLoginLabel, isOn: launchAtLoginBinding)
Text(text.launchAtLoginExplanation)
    .font(.footnote)
    .foregroundStyle(.secondary)
if loginItemController.requiresApproval {
    Text(text.loginItemRequiresApprovalExplanation)
        .font(.footnote)
        .foregroundStyle(.secondary)
}
if let error = loginItemController.errorMessage {
    Text(error)
        .font(.footnote)
        .foregroundStyle(.red)
}
```

在 Form 末尾增加 `.onAppear { loginItemController.refresh() }`。不得新增 UserDefaults key，因为真实状态来自 `SMAppService.mainApp.status`。

`AppText` 增加：

```swift
var launchAtLoginLabel: String {
    switch language {
    case .zhHans: "开机启动"
    case .english: "Launch at Login"
    }
}

var launchAtLoginExplanation: String {
    switch language {
    case .zhHans: "登录 macOS 后自动启动 CodexQuotaBar。默认关闭。"
    case .english: "Start CodexQuotaBar automatically after signing in to macOS. Off by default."
    }
}

var loginItemRequiresApprovalExplanation: String {
    switch language {
    case .zhHans: "请在“系统设置 → 通用 → 登录项”中批准 CodexQuotaBar。"
    case .english: "Approve CodexQuotaBar in System Settings → General → Login Items."
    }
}
```

- [ ] **Step 5: Run tests and commit**

Run: `swift test --filter LoginItemControllerTests`

Expected: PASS，失败路径不保留虚假的 toggle 状态。

Commit:

```bash
git add Sources/CodexQuotaBar/Support/LoginItemController.swift Sources/CodexQuotaBar/UI/SettingsView.swift Sources/CodexQuotaBar/Support/AppText.swift Tests/CodexQuotaBarTests/LoginItemControllerTests.swift
git commit -m "feat: add launch at login control"
```

---

### Task 8: 构建、签名、文档、CI 与 macOS 运行验证

**Files:**
- Modify: `scripts/build_app.sh`
- Create: `.github/workflows/macos.yml`
- Modify: `README.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/PRIVACY.md`
- Modify: `docs/DEVLOG.md`

**Interfaces:**
- Consumes: complete app and tests from Tasks 1–7。
- Produces: signed `dist/CodexQuotaBar.app` and reproducible macOS evidence。

- [ ] **Step 1: Make the build script test and sign**

在 `scripts/build_app.sh` 的 release build 前增加：

```zsh
swift test
swift build -c release
```

Info.plist 写完后增加：

```zsh
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
/usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"
echo "Built and verified $APP_DIR"
```

未提供证书时输出必须可从 `codesign -dv` 看出 ad-hoc；不得生成或下载签名凭据。

- [ ] **Step 2: Add a macOS workflow that exercises the exact release path**

创建 `.github/workflows/macos.yml`：

```yaml
name: macOS
on:
  push:
  pull_request:
jobs:
  test-and-build:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v7
      - name: Select Swift
        run: swift --version
      - name: Test, build, and ad-hoc sign
        run: ./scripts/build_app.sh
      - name: Verify bundle
        run: |
          codesign --verify --deep --strict --verbose=2 dist/CodexQuotaBar.app
          plutil -p dist/CodexQuotaBar.app/Contents/Info.plist
```

- [ ] **Step 3: Update user-facing and technical docs to match reality**

README 必须改为：菜单栏显示 7 天剩余与重置时间；官方额度来自本机 app-server；日志继续提供 token 统计/回退；依赖本机已安装并登录 `codex`；开机启动默认关闭；`CODE_SIGN_IDENTITY` 用法和 ad-hoc 限制。

`docs/PRIVACY.md` 必须明确：应用不读取/保存 token；它启动本机 `codex app-server`，由 Codex 使用现有登录态访问 OpenAI；session 日志不会上传；debug-status 新增 source/weekly 字段。删除“不进行网络请求”的过时绝对表述。

`docs/ARCHITECTURE.md` 增加 app-server、Store merge、通知/轮询、20 秒 watchdog、回退状态图。`docs/DEVLOG.md` 记录实际改动和真实验证结果，不预写尚未运行的 PASS。

- [ ] **Step 4: Run the full automated verification on macOS**

Run:

```bash
swift test
./scripts/build_app.sh
codesign --verify --deep --strict --verbose=2 dist/CodexQuotaBar.app
```

Expected: all XCTest cases PASS；release build 成功；codesign 输出 `valid on disk` 和 `satisfies its Designated Requirement`。

- [ ] **Step 5: Launch and compare official values**

Run:

```bash
open dist/CodexQuotaBar.app
```

同时从已登录的 Codex app-server 读取一次 `account/rateLimits/read`，记录官方 secondary `usedPercent/resetsAt`。断言：

- 菜单栏剩余 = `round(100 - secondary.usedPercent)`。
- 菜单栏重置短文本按当前时间与 `resetsAt` 计算。
- Popover 7 天条在上、5 小时条在下。
- 用辅助测试快照 `usedPercent=14` 时进度条几何宽度为可用宽度 `0.86 ± 0.005`。

- [ ] **Step 6: Verify refresh, reconnect, themes and login item on macOS**

逐项保存证据：

1. 连续观察至少 25 秒，确认发生两个 10 秒保底读取周期。
2. 打开 Popover，确认 debug-status 的 refreshed timestamp 立即更新。
3. 终止应用启动的 app-server 子进程，确认 UI 保留最后值、显示“正在重连”，并在 20 秒 watchdog/退避后恢复实时。
4. 在浅色和深色模式各截图一次，确认 systemBlue、轨道、文字可读且没有白底块。
5. 开启“开机启动”，检查 `SMAppService.mainApp.status == .enabled`；关闭后为 `.notRegistered`；在可重登录测试机上验证一次登录启动。

- [ ] **Step 7: Final diff review and commit**

Run:

```bash
git diff --check
git status --short
git diff --stat HEAD~7..HEAD
```

Expected: no whitespace errors；只有计划列出的文件改变；无 `.build/`、`dist/`、日志、账号数据或签名凭据被追踪。

Commit:

```bash
git add scripts/build_app.sh .github/workflows/macos.yml README.md docs/ARCHITECTURE.md docs/PRIVACY.md docs/DEVLOG.md
git commit -m "build: verify signed macOS app bundle"
```

---

## Final Acceptance Checklist

- [ ] `swift test` 全部通过，覆盖 86%→0.86、天/小时/分钟、官方解码、通知、超时、重连、回退、coalescing、开机启动回滚。
- [ ] 菜单栏显示 `secondaryQuota` 的 `86% · 7天`，代表 monitor 也按 secondary 最紧张项选择。
- [ ] 菜单栏蓝色环和 Popover 7 天条共享同一 `remainingFraction`。
- [ ] 官方读数覆盖默认 monitor，自定义 monitor 和所有 token totals 保持日志来源。
- [ ] 10 秒轮询、打开立即刷新、更新通知、20 秒 watchdog 和退避重连均有 macOS 证据。
- [ ] 浅色/深色模式截图清晰，UI 无配额区域硬编码白底/黑条/固定绿点。
- [ ] 开机启动可注册、注销、失败回滚，并实际验证一次重新登录。
- [ ] `scripts/build_app.sh` 产出签名验证通过的 `dist/CodexQuotaBar.app`。
- [ ] README、架构、隐私说明与实际行为一致。
- [ ] Windows 上完成的静态检查没有被描述成 macOS 运行通过。
