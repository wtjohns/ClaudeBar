# ClaudeBar

A native macOS menu bar app that shows your Claude (and optionally Codex) usage limits as a percentage — always visible, no clicking required.

![macOS](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![Swift](https://img.shields.io/badge/swift-5.9-orange)
![License](https://img.shields.io/badge/license-MIT-green)

> Swift/SwiftUI rewrite of [wtjohns/claude-usage-tool](https://github.com/wtjohns/claude-usage-tool) (Electron),
> which is itself a fork of [IgniteStudiosLtd/claude-usage-tool](https://github.com/IgniteStudiosLtd/claude-usage-tool).
> ~672KB vs ~300MB — no bundled Chromium.

## Features

- **Menu bar percentage** — shows your 5-hour session usage (e.g. `62%`) directly in the menu bar; with Codex enabled, a compact two-line `C 62%` / `X 18%`
- **Usage bars** — Claude session and weekly limits with reset timers
- **Codex usage** — ChatGPT plan 5-hour and weekly Codex limits (uses your existing Codex sign-in)
- **API credit balance** — scraped from platform.claude.com
- **Admin API tab** — 30-day token usage, cost breakdown by model, and credit balance (requires Admin API key)
- **Auto-refresh** — updates every 60 seconds
- **Native login windows** — log in to claude.ai and platform.claude.com without leaving the app
- **Persistent sessions** — stays logged in across restarts
- **Configurable** — show or hide Claude, Codex, credit balance and the debug log in Settings
- **Self-updating** — checks GitHub for new releases and installs them in place

## Requirements

- macOS 13 (Ventura) or later
- Xcode 15+ to build from source (`scripts/release.sh` builds a signed universal DMG)

## Installation

1. Download the latest `ClaudeBar-x.x.x.dmg` from [Releases](https://github.com/wtjohns/ClaudeBar/releases)
2. Open the DMG and drag **ClaudeBar.app** to **Applications**
3. Open ClaudeBar. macOS will say it can't verify the developer — click **Done**
4. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the ClaudeBar message, then confirm

ClaudeBar appears in your menu bar with no Dock icon.

> **Why step 4?** ClaudeBar is free and open source, so it isn't notarized by Apple (that requires a paid developer account). macOS asks you to approve it once. On macOS 13–14 you can instead right-click the app → **Open**.
>
> Upgrading from 1.1.x or earlier? Those builds had an incomplete signature that made macOS report the app as *damaged*; from 1.2.0 the normal **Open Anyway** flow works.

### Updates

ClaudeBar checks for new releases every few hours. When one is available, an **Update to x.y.z** button appears in the popover footer (or use **Settings → Check for Updates**). Updates are downloaded by the app itself, verified against the release checksum, and installed in place — no Gatekeeper approval needed after the first install.

> **Keychain prompt:** Because the app isn't signed with an Apple developer certificate, macOS asks for Keychain access the first time it reads your Claude Code session token (and again after each update). Click **Always Allow** — if you click Allow Once, the prompt will reappear on every refresh.

## Build from Source

```bash
# Install xcodegen if you don't have it
brew install xcodegen

# Clone and open
git clone https://github.com/wtjohns/ClaudeBar.git
cd ClaudeBar

# Regenerate the Xcode project (optional, already included)
xcodegen generate

# Open in Xcode
open ClaudeBar.xcodeproj
```

In Xcode: select your Team under **Signing & Capabilities**, then hit **Run** (⌘R).

## Admin API Key (Optional)

For the 30-day usage and cost breakdown, you need an Anthropic Admin API key:

1. Get one from [Anthropic Console](https://console.anthropic.com/settings/admin-keys)
2. Open the app → click **Settings** in the popover footer
3. Paste your key — it's stored securely in Keychain

## How It Works

ClaudeBar uses `WKWebView` with a persistent session store to scrape your usage data from claude.ai and platform.claude.com — the same approach as the Electron version, just native. Your session cookies persist across restarts so you only need to log in once.

**Claude:** usage comes from the Anthropic OAuth usage API, using the token Claude Code stores in your Keychain. If Claude Code isn't signed in, it falls back to scraping claude.ai/settings/usage.

**Codex:** usage comes from ChatGPT's usage endpoint, using the sign-in Codex stores in `~/.codex/auth.json` (read-only — ClaudeBar never modifies it). If that fails, it reads the most recent rate-limit snapshot from Codex's session logs in `~/.codex/sessions`.

## Privacy

All data stays on your machine. No analytics, no telemetry. The app only makes outbound requests to:
- `claude.ai` — usage data
- `platform.claude.com` — credit balance
- `api.anthropic.com` — Claude usage (OAuth) and Admin API (if key configured)
- `chatgpt.com` — Codex usage (only if Codex display is enabled)
- `api.github.com` / `github.com` — update checks and downloads

---

**Note:** Unofficial tool, not affiliated with or endorsed by Anthropic.
