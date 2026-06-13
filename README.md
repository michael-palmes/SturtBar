![SturtBar: the light that watches the passage so you don't run aground](docs/assets/social-card.png)

# SturtBar

[![CI](https://github.com/michael-palmes/SturtBar/actions/workflows/ci.yml/badge.svg)](https://github.com/michael-palmes/SturtBar/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/michael-palmes/SturtBar)](https://github.com/michael-palmes/SturtBar/releases/latest)
[![Licence](https://img.shields.io/github/license/michael-palmes/SturtBar)](LICENSE)

**The light that watches the passage so you don't run aground.**

SturtBar is a small, calm macOS menu bar app that keeps watch over your Claude Code usage: how much of the current session window is left, how much of the week, when each one resets, and what you have spent. Usage limits are the rocks. Your remaining quota is your sea room. SturtBar keeps the light burning so you always know how much passage you have left.

It is named for the Sturt Light at Cape Willoughby, on the eastern tip of Kangaroo Island: South Australia's first lighthouse, first lit on 16 January 1852, watching over Backstairs Passage so ships did not run aground. The light's namesake, as Colonial Secretary, raised the money from shipping interests to build the very light that warned their ships off the rocks. The funder paid for the warning. SturtBar is that light, re-manned by software.

> Note: SturtBar is an independent project. It is not affiliated with, endorsed by, or built by Anthropic. It reads the usage data Claude Code already stores on your Mac.

## What it shows

- **The Lamp** (the menu bar glyph): a two-bar meter. The tall bar is the session window, the short bar is the week. Each fills from the bottom as usage rises.
- **The Logbook** (the popover): session and weekly windows with exact percentages and reset countdowns, plus your spend for the period.
- **Notices to Mariners**: a rare, useful notification at 75% of a session, at the limit, when it refloats, and as the week draws in. Each is individually toggleable. No streaks, no nags, no re-engagement. A lighthouse does not send push notifications asking if you have thought about it lately.

## How it works

SturtBar reads the credentials Claude Code already keeps on your Mac. It looks first at `~/.claude/.credentials.json`, then falls back to the `Claude Code-credentials` item in your login keychain. It uses those credentials to call the usage API, exactly as Claude Code does. It reads them; it never changes them.

Spend is read locally by scanning the session logs under `~/.claude/projects` (the same JSONL `ccusage` reads). Nothing is uploaded.

Refresh runs on a hybrid schedule: whenever you open the menu, plus a background interval you choose (manual, 1, 2, 5, 15, or 30 minutes; 5 is the default). Cost scans run on demand.

**On token rotation:** if SturtBar ever has to refresh an expired OAuth token, the rotated token is written **only** to SturtBar's own keychain cache. SturtBar never writes to Claude Code's credential stores.

If SturtBar keeps asking you to re-authenticate after you've already logged back into Claude Code, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md): it's usually a keychain-permission or stale-file issue, not a login problem. (Note that signing into the Claude *desktop app* doesn't update the credentials SturtBar reads; only the `claude` CLI does.)

## Privacy

**The Keeper watches the water, not you.** SturtBar watches your usage, never you. Your credentials and session logs stay on your Mac; the only signals sent are the ones listed here.

What it reads:

- Claude Code's credentials, read-only: `~/.claude/.credentials.json` first, then the `Claude Code-credentials` login keychain item. It never writes to either.
- Session logs under `~/.claude/projects`, scanned locally for spend estimates. Nothing is uploaded.

Every network call it makes:

- `api.anthropic.com/api/oauth/usage`: reads your usage numbers, authenticated with the OAuth token, on each refresh.
- `platform.claude.com/v1/oauth/token`: refreshes the OAuth token, only when a stored token has expired. The rotated token is written only to SturtBar's own keychain cache.
- `models.dev/api.json`: fetches the pricing catalogue, unauthenticated, at most about once a day, and only while local cost tracking is enabled.

What it never does: no telemetry, no analytics, no accounts, no tracking. It never writes to Claude Code's credential stores, and secrets are redacted from its logs.

## Requirements

- macOS 26 or later
- Claude Code installed and signed in (run `claude` once so the credentials exist)

## Install

Download the latest notarised `SturtBar-<version>.dmg` from the [Releases](https://github.com/michael-palmes/SturtBar/releases) page. Open it and drag **SturtBar** onto the **Applications** folder, following the chart. Eject the disk image when you're done. SturtBar lives in the menu bar; it has no Dock icon.

(A `.zip` of the app is also attached for scripted installs.)

## Build from source

Zero third-party dependencies; the system toolchain is all you need.

```sh
make build      # swift build
make test       # swift test
make run        # build, package, and launch a local dev build
make package    # assemble dist/SturtBar.app
make dmg        # build a local unsigned DMG installer for preview
make lint       # SwiftFormat + SwiftLint
```

## Credits

The idea was sparked by [CodexBar](https://github.com/steipete/CodexBar) by Peter Steinberger. SturtBar is a lighter, faster, more privacy focused take on it: one provider instead of many, zero third-party dependencies, and no traffic beyond the calls it discloses. Thanks for the spark.

## License

MIT. See [LICENSE](LICENSE).
