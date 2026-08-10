# CodexQuotaBar

CodexQuotaBar is a macOS menu-bar app that shows your remaining weekly Codex quota and reset time. It reads official quota values from a local `codex app-server`; local Codex session logs still provide token totals and the fallback when the app-server is unavailable.

## Requirements

- macOS 13 or newer.
- Swift 6.2 or newer to build from source.
- Codex installed and already signed in on this Mac. The app starts the local `codex app-server` and uses that existing Codex login state.

## What it shows

- The menu bar shows the remaining 7-day quota and its reset time.
- The popover shows the 7-day and 5-hour windows, local rolling token totals, the latest request, and optional manual subscription/cost estimates.
- Official limits update from app-server notifications, every 10 seconds as a fallback poll, and immediately when the popover opens.
- If app-server disconnects or stalls, the last valid quota stays visible while it reconnects with backoff; local session logs remain the initial fallback.
- Multiple custom monitors can read their own local sessions folders; official quota overlays only the default Codex monitor.
- Launch at login is available in Settings and is off by default.

## Build and run

```bash
./scripts/build_app.sh
open dist/CodexQuotaBar.app
```

The build script runs `swift test`, creates a release bundle at `dist/CodexQuotaBar.app`, signs it, and verifies the signature. By default it uses an ad-hoc signature (`CODE_SIGN_IDENTITY=-`), suitable for local development and CI only. macOS may require a first-open approval for an ad-hoc-signed app.

To sign with an installed signing identity instead:

```bash
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build_app.sh
```

For development without creating an app bundle:

```bash
swift build
swift run CodexQuotaBar
```

## Privacy

The app reads local Codex logs and configuration only for the monitors you configure. It does not read or save OpenAI account tokens. See [docs/PRIVACY.md](docs/PRIVACY.md) for the complete data-handling details and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the synchronization design.

## License

MIT. See [LICENSE](LICENSE).
