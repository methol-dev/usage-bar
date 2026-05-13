<p align="center">
  <img src="macos/Resources/icon.png" width="128" alt="UsageBar icon">
</p>

# UsageBar

Have you ever found yourself refreshing the Claude usage page, wondering how close you are to hitting your rate limit? Yeah, I've been there too. So I built this.

Now it's just a glimpse away — always sitting at the top of your screen.

<p align="center">
  <img src="https://github.com/user-attachments/assets/9224ea74-702d-4e50-bd47-444e9bf11dd0" width="400" alt="UsageBar Claude usage view">
  &nbsp;&nbsp;
  <img src="https://github.com/user-attachments/assets/d3827410-35bc-46f1-a8b4-07ed62970e3b" width="400" alt="UsageBar Codex usage view">
</p>

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-BSD--2--Clause-green)

## What it does

A tiny macOS menu bar app that shows your Claude API and Codex usage at a glance. Click it for the full picture:

- Menu bar icon with a mini dual-bar showing 5-hour and 7-day utilization
- Detailed popover with per-window usage, per-model breakdown, and reset timers
- **Multi-provider support** — switch between Claude and Codex tabs in the popover
- Extra usage tracking with USD currency display (pricing via LiteLLM snapshot)
- Usage history chart — see how your usage evolves over time (1h / 6h / 1d / 7d / 30d)
- Hover over the chart to see exact values at any point
- Configurable polling interval (5m / 15m / 30m / 1h)
- Built-in update checks via Sparkle
- Just sign in — Claude: OAuth via browser, no API keys to manage; Codex: reads existing CLI credentials
- Minimal dependencies — SwiftUI, Swift Charts, Foundation, and Sparkle for updates

## Install

### Download

1. Download `UsageBar.dmg` from the [latest release](https://github.com/methol/usage-bar/releases/latest)
2. Open the disk image and drag `UsageBar.app` into `Applications`
3. Launch the app from `/Applications`
4. macOS may require right-click → **Open** on first launch

### Build from source

Requires Xcode 15+ / Swift 5.9+ and macOS 14 (Sonoma) or later.

```sh
git clone https://github.com/methol/usage-bar.git
cd usage-bar
make app            # build .app bundle
make dmg            # build drag-to-Applications disk image
make install        # copy to /Applications
```

## Usage

### Claude

1. Launch the app — a menu bar icon appears
2. Click the icon → **Sign in with Claude** → authorize in your browser
3. Paste the code back into the app
4. The icon updates automatically (default: every 30 minutes)
5. Release builds show **Check for Updates…** in the popover so you can pull newer versions without re-downloading manually

Click the icon anytime to see:
- 5-hour and 7-day usage with progress bars and reset timers
- Per-model breakdown (Opus / Sonnet) when available
- Extra usage credits and limits
- Usage history chart with adjustable time range and hover details

### Codex

If you have the [Codex CLI](https://github.com/openai/codex) installed and logged in, UsageBar automatically detects your credentials and shows a **Codex** tab in the popover. No additional sign-in is required — the app reads your existing `~/.codex/auth.json` (written by the Codex CLI) and never modifies it.

To enable Codex tracking: install and log in to the Codex CLI, then relaunch UsageBar.

## Data storage

All data is stored locally:

| Path | Purpose |
|------|---------|
| `~/.config/usage-bar/credentials.json` | Claude OAuth credentials (permissions: `0600`) |
| `~/.config/usage-bar/history.json` | Usage history for the chart (30-day retention) |
| `~/.codex/auth.json` | Codex credentials — **read-only** by UsageBar, managed by Codex CLI |

History is buffered in memory and flushed to disk every 5 minutes and on app quit. No data is sent anywhere other than the respective provider APIs.

> Legacy note: older versions stored Claude credentials in `~/.config/usage-bar/token`. The app migrates this file automatically on first launch after upgrading.

## Development

```sh
make build          # release build only
make app            # build + create .app bundle
make zip            # build + bundle + zip + verify distribution artifact
make dmg            # build + bundle + DMG + verify distribution artifact
make release-artifacts  # build once, then create and verify both ZIP and DMG
make verify-release # inspect the packaged ZIP and DMG artifacts
make install        # build + install to /Applications
make clean          # remove build artifacts
```

## Publishing updates

This repo uses a tag-driven release flow. Pushing a `v*` tag will:

- build the `.app` bundle once
- produce `UsageBar.zip` for Sparkle and `UsageBar.dmg` for manual installs
- verify the packaged artifacts contain the expected app bundle resources and updater framework
- create the GitHub Release
- reuse GitHub-generated release notes for both the GitHub Release and the Sparkle update entry
- generate a signed Sparkle `appcast.xml` from that exact zip
- deploy the appcast to GitHub Pages

Publishing a release is just:

```sh
git tag v0.0.5
git push origin v0.0.5
```

One-time repo setup:

1. Enable GitHub Pages and set the source to `GitHub Actions`.
2. Add a repository Actions secret named `SPARKLE_PRIVATE_KEY`.

Local source builds intentionally ship with Sparkle disabled unless `SU_FEED_URL` is injected during packaging. This prevents forks and local builds from auto-updating to upstream binaries.

Manual installs should prefer the DMG. The ZIP remains the source of truth for Sparkle updates and appcast generation.

You can export the current Sparkle private key from your local Keychain with:

```sh
macos/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account usage-bar -x /tmp/usage-bar.sparkle.key
gh secret set SPARKLE_PRIVATE_KEY < /tmp/usage-bar.sparkle.key
```

The appcast feed URL used by release builds is:

```text
https://methol.github.io/usage-bar/appcast.xml
```

### Project structure

```
macos/                 # macOS menu bar app (Swift/SwiftUI)
├── Sources/UsageBar/  # App source files
├── Tests/             # Unit tests
├── Resources/         # App bundle resources (Info.plist, Assets.xcassets)
├── scripts/           # build.sh, verify-release.sh
└── Package.swift

docs/                  # Project documentation
scripts/               # Shared tooling (mock-server, issue scripts)
```

## Fork relationship

This repo is an AI-led fork of [`Blimp-Labs/claude-usage-bar`](https://github.com/Blimp-Labs/claude-usage-bar) (forked at upstream `v0.0.6`, 2026-03-10). From `v0.0.7` onward the version numbering and release URLs are independent — see [`docs/adr/0004-fork-divergence-from-blimp-labs.md`](docs/adr/0004-fork-divergence-from-blimp-labs.md). Upstream commits are not auto-merged.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, testing with the mock server, and submission guidelines.

> Note: this project is AI-led — see [`AGENTS.md`](AGENTS.md) for the governance contract.

## License

[BSD 2-Clause](LICENSE)

### Third-party

- Cost estimates use model price data from [`BerriAI/litellm`](https://github.com/BerriAI/litellm) (`model_prices_and_context_window.json`), MIT License — bundled as `litellm_model_prices.json`; see `THIRD_PARTY_LICENSES.txt` in the app bundle.
- Update mechanism: [Sparkle](https://sparkle-project.org), MIT License.
