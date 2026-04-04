# ClaudeBar

A native macOS menu bar app that shows your Claude 5-hour session usage as a percentage — always visible, no clicking required.

![macOS](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![Swift](https://img.shields.io/badge/swift-5.9-orange)
![License](https://img.shields.io/badge/license-MIT-green)

> Swift/SwiftUI rewrite of [wtjohns/claude-usage-tool](https://github.com/wtjohns/claude-usage-tool) (Electron),
> which is itself a fork of [IgniteStudiosLtd/claude-usage-tool](https://github.com/IgniteStudiosLtd/claude-usage-tool).
> ~672KB vs ~300MB — no bundled Chromium.

## Features

- **Menu bar percentage** — shows your 5-hour session usage (e.g. `62%`) directly in the menu bar
- **Usage bars** — all usage limits from claude.ai/settings/usage with reset timers
- **API credit balance** — scraped from platform.claude.com
- **Admin API tab** — 30-day token usage, cost breakdown by model, and credit balance (requires Admin API key)
- **Auto-refresh** — updates every 60 seconds
- **Native login windows** — log in to claude.ai and platform.claude.com without leaving the app
- **Persistent sessions** — stays logged in across restarts

## Requirements

- macOS 13 (Ventura) or later
- Xcode 15+ to build from source

## Installation

1. Download the latest `ClaudeBar-x.x.x.dmg` from [Releases](https://github.com/wtjohns/ClaudeBar/releases)
2. Open the DMG and drag **ClaudeBar.app** to your Applications folder
3. Run this command in Terminal to clear the quarantine flag (required for unsigned apps):

```bash
xattr -dr com.apple.quarantine /Applications/ClaudeBar.app
```

4. Open ClaudeBar from Applications — it will appear in your menu bar with no Dock icon

> macOS will show "damaged and can't be opened" without step 3. This is Gatekeeper blocking unsigned apps downloaded from the internet — the command removes that restriction.

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

For the menu bar percentage, it reads the "Current session" bar from the scraped data. If that's unavailable, it falls back to the Anthropic OAuth usage API using the token Claude Code stores in your Keychain.

## Privacy

All data stays on your machine. No analytics, no telemetry. The app only makes outbound requests to:
- `claude.ai` — usage data
- `platform.claude.com` — credit balance
- `api.anthropic.com` — Admin API (if key configured) and OAuth usage fallback

---

**Note:** Unofficial tool, not affiliated with or endorsed by Anthropic.
