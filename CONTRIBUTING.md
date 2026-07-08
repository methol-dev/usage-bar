# Contributing to UsageBar

Thanks for your interest in contributing! This guide will help you get set up and make sure your changes land smoothly.

> **Note: this project is AI-led** ([ADR 0003](docs/adr/0003-ai-led-development.md)).
> Day-to-day implementation, testing, and CHANGELOG generation are handled by AI agents
> under the governance contract in [`AGENTS.md`](AGENTS.md). Human contributors are welcome —
> please prefer opening a [GitHub Issue](https://github.com/methol/usage-bar/issues/new) describing
> the bug or feature first; AI agents will pick it up via the
> [issue-driven workflow](.agent/rules/workflows/issue-driven.md) and produce a PR. Direct PRs are still
> accepted but may be re-routed through that flow for consistency.

## Prerequisites

- macOS 14 (Sonoma) or later
- Xcode 15+ / Swift 5.9+
- Python 3 (for the mock server, included with macOS)

## Getting started

```sh
git clone https://github.com/methol/usage-bar.git
cd usage-bar
make app
```

This builds the release binary via Swift Package Manager, bundles it as a `.app`, and codesigns it. The app also embeds Sparkle for update checks.

## Project structure

```
macos/Sources/UsageBar/
├── App/             # Entry point, app delegate, Sparkle updater wrapper
├── Models/          # Data types: credentials, accounts, usage snapshots
├── Services/        # UsageHistoryService, NotificationService, ProviderCoordinator
├── Providers/
│   ├── Core/        # UsageProvider protocol
│   ├── Claude/      # Claude provider: OAuth, polling, backoff
│   ├── Codex/       # Codex provider: ~/.codex/auth.json + JSONL scan
│   └── Gemini/      # Gemini provider: OAuth token refresh, Cloud Code Assist quota
├── Pricing/         # LiteLLM snapshot loader + per-provider normalize
├── LocalCost/       # JSONL parser, aggregator, scan cursor store
├── MenuBar/         # Menu bar label + icon rendering
├── Features/
│   ├── Popover/     # Main popover UI (hero card, chart, heatmap)
│   └── Settings/    # Settings window
├── Utilities/       # Pace / Trend calculators, formatters
└── Resources/       # Info.plist, Assets.xcassets, litellm_model_prices.json
```

See [`docs/superpowers/specs/2026-05-13-code-structure-hygiene.md`](docs/superpowers/specs/2026-05-13-code-structure-hygiene.md) §3.3 for the authoritative file mapping.

## Build commands

| Command | What it does |
|---------|-------------|
| `make build` | Release build via `swift build` |
| `make app` | Build + create `.app` bundle |
| `make zip` | Build + bundle + zip, then verify the release artifact |
| `make dmg` | Build + bundle + drag-to-Applications disk image, then verify it |
| `make release-artifacts` | Build once, then create and verify both ZIP and DMG artifacts |
| `make verify-release` | Inspect the packaged ZIP and DMG artifacts for required resources/frameworks |
| `make install` | Build + install to `/Applications` |
| `make clean` | Remove build artifacts |

## Publishing releases

Releases are tag-driven. Pushing a `v*` tag triggers the GitHub Actions workflow that:

- builds the release app bundle once
- produces both a ZIP (for Sparkle) and a DMG (for manual drag-to-Applications installs)
- verifies the packaged artifacts before publishing
- uploads those exact artifacts to the GitHub Release
- reuses GitHub-generated release notes for both the release body and the Sparkle update entry
- generates a signed Sparkle appcast from that zip
- deploys the appcast to GitHub Pages

One-time repository setup:

1. Enable GitHub Pages with source `GitHub Actions`
2. Add the `SPARKLE_PRIVATE_KEY` repository secret

Local source builds intentionally leave `SUFeedURL` unset, so Sparkle stays disabled unless your packaging flow injects a feed URL. This prevents forks and dev builds from auto-updating to upstream releases.

To export the current private key from your local Keychain:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account usage-bar -x /tmp/usage-bar.sparkle.key
gh secret set SPARKLE_PRIVATE_KEY < /tmp/usage-bar.sparkle.key
```

## Testing with the mock server

A mock API server lets you test usage fetching and error handling against different scenarios without needing a real Anthropic account:

```sh
python3 scripts/mock-server.py --scenario extra
```

To connect the app to the mock server:

1. In `Providers/Claude/UsageService.swift`, change the static default endpoint:
   ```swift
   nonisolated static let defaultUsageEndpoint = URL(string: "http://127.0.0.1:8080/api/oauth/usage")!
   ```
2. Add local networking to `Resources/Info.plist`:
   ```xml
   <key>NSAppTransportSecurity</key>
   <dict>
       <key>NSAllowsLocalNetworking</key>
       <true/>
   </dict>
   ```
3. Rebuild and run the app, then click Refresh.

The mock server serves four routes: `GET /api/oauth/usage` (usage payload for the active scenario), `GET /api/oauth/userinfo` (static fake user info), `GET /scenario/<name>` (switch scenario at runtime), and `POST /v1/oauth/token` (fake token endpoint for manual experiments). The real browser OAuth flow is NOT mocked — the app still uses Anthropic’s real OAuth/browser flow unless you separately rewire the auth endpoints.

Available scenarios:

| Scenario | Description |
|----------|-------------|
| `normal` | Moderate usage (5h: 25%, 7d: 45%) |
| `high` | Near rate limit (5h: 85%, 7d: 92%) |
| `maxed` | Fully rate limited (100% / 100%) |
| `low` | Barely used (5h: 2%, 7d: 5%) |
| `extra` | Extra usage enabled ($52.30 / $280.00) |
| `extra_high` | Extra usage near limit ($94.50 / $100.00) |
| `per_model` | Per-model breakdown (Opus + Sonnet) |
| `all_features` | Everything: per-model + extra usage |
| `unauthenticated` | Returns 401 |
| `rate_limited` | Returns 429 with Retry-After |
| `error` | Returns 500 |

**Remember to revert the endpoint and Info.plist changes before committing.**

## Submitting changes

1. Fork the repo and create a branch from `main`
2. Keep PRs focused — one feature or fix per PR
3. Test your changes with the mock server when relevant
4. Make sure `make app` builds without errors
5. Open a pull request against `main`

### Code style

- Follow the existing conventions in the codebase
- SwiftUI views in separate files, one primary view per file
- Provider logic lives in `Providers/<Name>/`; `ProviderCoordinator` drives the unified polling cycle
- Keep dependencies minimal — Sparkle is the only third-party runtime dependency

## License

By contributing, you agree that your contributions will be licensed under the [BSD 2-Clause License](LICENSE).
