# Architecture

CodexQuotaBar is a Swift Package executable that runs as a macOS menu-bar accessory app.

## Source layout

- `App/`: lifecycle, menu-bar item, popover, context menu, and settings coordination.
- `Data/`: Codex logs, app-server RPC client, observable usage store, and data models.
- `UI/`: SwiftUI popover, monitor rail, settings, and status-ring rendering.
- `Support/`: preferences, monitor configuration, localized copy, status presentation, and login-item control.

## Quota synchronization

1. `CodexUsageStore` scans each enabled monitor's local JSONL logs for token totals and a fallback snapshot.
2. For the default Codex monitor, `CodexAppServerClient` launches local `codex app-server` and sends `account/rateLimits/read` RPC requests.
3. The store merges official 5-hour and 7-day windows onto that default monitor only; custom monitors and all token totals continue to use their log-derived values.
4. App-server rate-limit notifications trigger a read. A 10-second poll and opening the popover also trigger refreshes; overlapping reads are coalesced.
5. A request without a response for 20 seconds fails. The client keeps the last valid quota, reports reconnecting, and reconnects with backoff. Before the first official value, logs remain the fallback.

```text
local logs ──> fallback snapshot + token totals ──┐
                                                ├─> store merge ─> menu bar / popover
codex app-server ─> official 5h + 7d limits ────┘
     notifications / 10s poll / open refresh
     20s watchdog ─> reconnect with backoff ─> retain last valid value
```

## UI behavior

- The menu bar represents the enabled monitor with the lowest remaining weekly quota.
- The popover lists 7-day before 5-hour quota, displays connection state, and refreshes when opened.
- Right-click or Control-click opens the context menu; clicking outside closes the popover.
- Launch at login is controlled through `SMAppService` and is disabled by default.
- Monitor, subscription, pricing, and interface preferences are local `UserDefaults` values.

## Build output

`scripts/build_app.sh` runs tests, builds the release executable, recreates `dist/CodexQuotaBar.app`, signs it with `CODE_SIGN_IDENTITY` (or ad-hoc `-`), and strictly verifies the resulting bundle. Build output is ignored by git.
