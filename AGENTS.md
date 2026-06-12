# AGENTS.md

Guidance for AI agents working in this repo. SturtBar is a lean macOS menu bar app that tracks Claude Code usage (and, strictly opt-in, OpenAI Codex usage), with zero third-party dependencies.

## Build, test, lint

- `make build` / `swift build`
- `make test` / `swift test` (Swift Testing, not XCTest)
- `make lint` / `make format` (SwiftFormat + SwiftLint, pinned via `Scripts/install_lint_tools.sh`)
- `make package` assembles `dist/SturtBar.app`; `make run` builds, packages, and launches a local dev build
- Always run `swift build && swift test` and `make lint` before claiming work is done. Keep the suite and a release build warning-free.

## Git workflow

- **Never commit or push directly to `main`**: a branch ruleset rejects it for everyone, including the maintainer. Work on a branch, open a PR, wait for the `build-test` check, squash merge.
- Merges are squash-only; merged branches are deleted automatically.
- Tags are pushed by `Scripts/release.sh` only (releases are manual and maintainer-only; the ruleset does not block tags).

## Layout

- `Sources/SturtBarCore/` library: logging, HTTP, Keychain, OAuth, CostUsage (the testable core, no AppKit)
- `Sources/SturtBar/` app: state layer (UsageStore, scheduler, actors), icon pipeline, menu, windows, settings
- `Tests/SturtBarTests/` plus `Fixtures/`
- `Scripts/` packaging, signing, lint; `Resources/` the app icon (`make_icon.sh` rebuilds the `.icns` from `AppIcon-1024.png`)

## Conventions

- Swift 6 strict concurrency. Explicit `self.` is required and enforced by SwiftFormat; do not remove it.
- Zero third-party dependencies. `os.Logger`, CryptoKit, and Security are system frameworks; do not add packages.
- macOS 26+, `LSUIElement` (menu bar only, no Dock icon). Bundle id `com.michaelpalmes.sturtbar`. First release is 1.0.0.

## Safety invariants

- **Never write to Claude Code's credential stores.** Refreshed/rotated OAuth tokens persist only to SturtBar's own keychain cache (`com.michaelpalmes.sturtbar.cache`). Read Claude Code's credentials; never modify them.
- **Never write under `~/.codex` and never refresh Codex tokens.** The Codex lane is a strictly read-only consumer of `~/.codex/auth.json`; a 401 surfaces as "sign in via the codex CLI" — SturtBar never calls `auth.openai.com` and never parses the `id_token` JWT.
- **A disabled provider is inert.** The provider toggles are hard privacy gates: no network, no file reads, no background work, and disabling wipes the provider's persisted snapshot. The only sanctioned pre-opt-in filesystem touch is the Settings-open `authFileExists` stat().
- All usage fetches go through the `ClaudeUsageClient` actor; never call OAuth-store sync entry points from the MainActor (they can block on keychain prompts).
- Health mapping is typed only; never parse error strings.
- The self-cache keychain read is best-effort and must never prompt (see `KeychainCacheStore.withoutLegacyKeychainUI`); it falls back to Claude Code's keychain.

## Brand voice

User-facing copy follows `BRAND.md` (kept in the SturtBar planning folder): Australian English, no em dashes ever, sentence case (no Title Case), and the dry maritime "Keeper" register. Theme density is inversely proportional to glance frequency: the menu bar is mute, the popover terse, the About box can sing. Never imply affiliation with any AI provider; provider names appear only in functional UI, never in flavour copy.
