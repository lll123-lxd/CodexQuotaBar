# CodexQuotaBar 官方同步与蓝色进度条设计

日期：2026-08-10  
状态：用户已逐段批准  
上游基线：`Ammasloan/CodexQuotaBar` `main`，提交 `63a8819644d8`

## 目标

在现有 CodexQuotaBar 项目上完成同步版菜单栏工具，不创建第二套应用。应用使用本机 Codex 登录态读取官方额度数据，菜单栏显示 7 天额度剩余百分比和重置剩余时间，例如 `98% · 7天`。点击后，Popover 同时显示 5 小时和 7 天额度，其中 7 天额度位于顶部，并以现代 macOS 蓝色进度条展示。

必须保留现有本地 token 统计、多监控器、自动刷新、打开立即刷新、设置和单实例能力，并补齐当前仓库缺失的 20 秒超时重连、开机启动、签名和自动化测试。

## 非目标

- 不读取、复制或保存用户的 ChatGPT token、密码或 API Key。
- 不直接调用未由 Codex app-server 管理的 OpenAI 后端接口。
- 不重写现有 token 统计、订阅成本估算或多监控器界面。
- 不把横向进度条塞入原生菜单栏按钮；菜单栏保持蓝色图标和短文本。
- 不增加与额度同步无关的设置或视觉重构。

## 现状与缺口

现有项目扫描 `~/.codex/sessions` 下最近 7 天的 JSONL 文件，从 `token_count` 事件读取配额和 token 统计。`QuotaWindow` 已将 `usedPercent` 转换为同源的 `remainingPercent` 和 `remainingFraction`，现有横向进度条宽度逻辑正确。

当前缺口：

- 配额只来自日志，没有调用官方 `account/rateLimits/read`。
- 菜单栏只显示 5 小时剩余百分比，没有 7 天重置剩余时间。
- 横向进度条为近黑色，Popover 强制白色背景，深色模式不完整。
- 刷新任务没有超时；一次扫描卡住会让 `isRefreshing` 永远保持为真。
- 没有 app-server 更新通知、进程监管或自动重连。
- 没有开机启动、签名步骤、测试 target、CI 或正式 Release。

## 方案选择

采用“官方 app-server 主数据源 + 本地日志回退”。

未采用的方案：

- 完全改用 app-server：会不必要地削弱现有本地 token 统计和自定义日志监控器。
- 只修日志版 UI：无法保证没有新会话时额度仍与官方当前状态一致。

## 架构

### `CodexAppServerClient`

新增一个独立客户端，负责：

1. 启动本机 `codex app-server --stdio` 子进程。
2. 通过换行分隔 JSON 与 app-server 通信。
3. 发送一次 `initialize` 请求并发送 `initialized` 通知。
4. 调用 `account/rateLimits/read`。
5. 持续读取 `account/rateLimits/updated` 通知；收到稀疏通知后重新读取完整快照，不在 UI 层自行猜测合并规则。
6. 管理请求 ID、响应匹配、20 秒超时、进程退出和重连状态。

客户端不拥有 UI 状态，也不读取 session 日志。它只输出官方额度快照和连接状态，便于独立测试。

进程解析优先使用当前环境可找到的 `codex`，并兼容常见 Homebrew 安装路径。无法找到或启动 app-server 时，应用继续使用日志额度并明确显示回退/重连状态，不崩溃、不要求用户提供凭据。

### 官方额度模型

新增只覆盖官方响应字段的可解码结构：

- `rateLimits.primary`
- `rateLimits.secondary`
- `usedPercent`
- `windowDurationMins`
- `resetsAt`
- `planType`

解码后立即映射到现有 `QuotaWindow`。剩余比例仍由现有模型统一计算：

```text
remainingPercent = clamp(100 - usedPercent, 0...100)
remainingFraction = remainingPercent / 100
```

文字百分比、菜单栏环形图标和横向进度条不得分别计算比例。

### `CodexUsageStore`

现有 Store 继续作为唯一 UI 数据入口：

1. 日志扫描器生成 token 统计和日志额度快照。
2. app-server 返回官方快照时，仅覆盖默认 Codex 监控器的 primary、secondary 和 plan type。
3. 自定义日志监控器继续使用各自目录中的日志数据。
4. 官方连接不可用时保留最后一次官方快照；若从未成功读取，则使用日志额度。
5. Store 发布连接状态，供 Popover 显示“实时”“正在重连”或“日志回退”。

多监控器代表项继续选择剩余额度最紧张的启用项，但比较指标改为 7 天 `secondaryQuota.remainingPercent`，与菜单栏主指标一致。

## 数据流与刷新

启动时：

1. 注册默认偏好。
2. 启动 app-server 客户端并完成初始化握手。
3. 同步执行一次官方额度读取和一次后台日志扫描。
4. 合并快照并更新菜单栏与 Popover。

持续运行时：

- 每 10 秒执行一次保底额度读取。
- 用户打开 Popover 前立即触发读取。
- 收到 `account/rateLimits/updated` 后立即重新读取完整额度。
- 设置变化后重启刷新计时器并立即刷新。
- 同一时刻只允许一条官方读取和一条日志扫描；重复触发合并为下一次刷新，不能永久丢弃。

## 超时、重连与降级

- 初始化和额度读取均设 20 秒上限。
- 超时、EOF、broken pipe、子进程退出或无法解码关键响应时，关闭管道并终止旧进程。
- 自动重连使用 1、2、4、8、16、30 秒上限的指数退避，并加入少量抖动。
- app-server 返回 `-32001 Server overloaded; retry later.` 时使用相同退避，不立即重启健康进程。
- 成功读取一次后重置退避。
- 重连期间保留最后一次有效额度，并把连接状态标为“正在重连”。
- 从未取得官方数据时使用日志额度；官方数据恢复后立即覆盖日志额度。
- 应用终止时取消计时器、结束挂起请求并终止由本应用启动的 app-server 子进程。

## 菜单栏设计

菜单栏使用 `secondaryQuota`，显示：

```text
蓝色环形图标  86% · 7天
```

规则：

- 环形弧长使用 `secondaryQuota.remainingFraction`。
- 环形图标固定使用 `NSColor.systemBlue`，轨道使用语义 label 色的低透明度版本。
- 百分比使用 `secondaryQuota.compactRemainingLabel`。
- 重置间隔不少于 24 小时时，使用向上取整的天数，例如 6 天 23 小时显示 `7天`。
- 少于 24 小时时显示整小时；少于 1 小时时显示分钟；已经到点显示“即将重置”。
- 无百分比或重置时间时显示 `--% · --`。
- Tooltip 包含数据来源、最后更新时间、7 天已用/剩余百分比和绝对重置时间。

## Popover 设计

- 保持现有紧凑尺寸和左侧监控器栏。
- 7 天额度移到配额区顶部，5 小时额度位于其下。
- 两条进度条均使用各自 `QuotaWindow.remainingFraction`。
- 填充使用 `Color(nsColor: .systemBlue)`；轨道、边框和背景改用系统语义颜色。
- 移除 `Color.white` 和 `Color.black` 作为大面积背景/轨道的硬编码，使用 `windowBackgroundColor`、`controlBackgroundColor`、`separatorColor`、`.primary` 和 `.secondary`。
- 浅色和深色模式使用同一布局，只由系统语义颜色调整对比度。
- 连接状态显示为短文本，不用固定绿色圆点伪装数据新鲜度。
- 正在重连时继续显示最后有效数据；从未取得数据时显示占位符。

## 开机启动

设置页新增“开机启动”开关，使用 macOS 13+ `SMAppService.mainApp`：

- 默认关闭。
- 开关状态读取 `SMAppService.mainApp.status`，不只依赖 UserDefaults。
- 注册或注销失败时恢复真实状态并显示可操作错误。
- 不实现旧式 LaunchAgent 或登录脚本。

## 构建与签名

保留 `scripts/build_app.sh` 的 Swift Package 构建和 `.app` 封装流程，并补充：

- 构建前运行测试，或提供独立的验证脚本供 CI 调用。
- 若设置 `CODE_SIGN_IDENTITY`，使用该身份签名。
- 未设置身份时使用 ad-hoc 签名 `-`，仅用于本机开发和验证。
- 构建结束运行 `codesign --verify --deep --strict`。
- 不创建或伪造 Developer ID、Notarization 凭据。

## 测试设计

在 `Package.swift` 增加 test target，测试新逻辑而不是复制实现。

单元测试：

- `usedPercent = 14` 得到 `remainingPercent = 86` 和 `remainingFraction = 0.86`。
- 比例在 0...100 内正确截断。
- 7 天、小时、分钟和“即将重置”格式边界。
- `account/rateLimits/read` 完整响应解码与映射。
- `account/rateLimits/updated` 通知识别并触发重新读取。
- 菜单栏状态始终使用 secondary，而不是 primary。
- 连接状态、日志回退和最后有效数据保留规则。
- 开机启动状态映射与错误回滚逻辑。

传输/状态机测试：

- 初始化握手成功后才能发送额度读取。
- 请求 ID 对应正确响应。
- 20 秒超时触发进程重启。
- EOF、退出和 malformed JSON 不会锁死刷新。
- `-32001` 使用退避而不错误重启健康进程。
- 多次刷新触发不会并发写入同一管道或永久丢失下一次刷新。

macOS 验证：

1. `swift test` 全部通过。
2. release `.app` 构建通过，`codesign --verify` 通过。
3. 本机 Codex 官方额度与菜单栏/Popover 数值一致。
4. 86% 时进度条实测占可用宽度的 86%。
5. 重置倒计时跨天、跨小时更新正确。
6. 连续运行至少两个刷新周期，打开 Popover 立即刷新。
7. 模拟 app-server 卡住或退出，20 秒后自动重连并恢复官方数据。
8. 浅色/深色模式截图检查文字、轨道和蓝色填充对比度。
9. 开机启动注册、注销和重新登录启动均验证。

## 验证边界

当前执行环境为 Windows 11，可完成源码改动、静态审查和与平台无关的文本/协议检查，但不能真实运行 AppKit、`SMAppService`、`codesign` 或 `.app`。完成声明必须基于 macOS 或 macOS CI 的新鲜输出；若没有该环境，只能明确报告尚未验证的项目，不得把 Windows 检查描述为 macOS 运行通过。

## 完成标准

- 菜单栏显示 7 天剩余额度和重置剩余时间。
- 菜单栏环形图标及 Popover 进度条统一为系统蓝色。
- 所有比例来自同一 `QuotaWindow`，86% 对应 0.86 宽度。
- 官方 app-server 为主数据源，通知与 10 秒轮询均可更新。
- 超过 20 秒卡住可自动重连；断线期间不显示虚构数据。
- 日志 token 统计、多监控器、打开立即刷新和设置能力不回归。
- 开机启动可由用户控制。
- 自动化测试、release 构建、签名校验和 macOS 手工验证均有证据。

