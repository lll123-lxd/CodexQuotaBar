# Privacy

CodexQuotaBar is local-first. It does not read or save OpenAI account tokens.

## Local files and settings

The app reads local Codex session logs and configuration from:

- `~/.codex/sessions/**/*.jsonl`
- `~/.codex/config.toml`
- Any sessions folders and configuration files you explicitly add in Settings.

It stores small local preferences in `UserDefaults`, including monitor paths, refresh and language settings, duplicate-instance behavior, and optional manual subscription and token-pricing settings.

## Official quota access

The app starts `codex app-server` on your Mac to read official quota data. Codex app-server uses the existing Codex login state to access OpenAI; CodexQuotaBar neither receives nor persists the underlying account token.

## Data sent and diagnostic status

CodexQuotaBar does not upload, transmit, sync, or send telemetry for session logs. App-server communication may use the network through the existing Codex login state as described above.

For local troubleshooting, the app writes `~/Library/Application Support/CodexQuotaBar/debug-status.json`. It stays on your Mac and can be deleted safely. It includes the menu-bar status, source (`source`), weekly quota values (`remainingPercent`, `usedPercent`, and `resetAt`), timestamps, process ID, app path, and monitor name.
