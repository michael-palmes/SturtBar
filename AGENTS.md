# AGENTS.md

Guidance for AI agents working in this repo. SturtBar is a lean macOS menu bar app that tracks Claude Code usage (and, strictly opt-in, OpenAI Codex usage), with zero third-party dependencies.

## Key principles

- Privacy, security and performance come first.
- Simple is good, less is more. Always look for ways to reduce the app's overhead and keep it light.
- Least access: only read or access what is needed, nothing more.
- No telemetry, no analytics, no accounts, no tracking.
- No network calls of any kind except to the agent providers Anthropic Claude and OpenAI Codex, and only for providers the user has enabled or connected. The one further destination is the disclosed, setting-gated pricing fetch (`models.dev`). The complete list lives in `docs/brand/BRAND.md` 6.3 and the README's Privacy section; a new destination ships with its disclosure in the same commit, or it does not ship.
- Be clear and transparent with the user about what is accessed and how. Transparency and honesty build trust.
- macOS 26 or later only. Apple Silicon (arm64) only.
- No em dashes in anything you write: UI copy, docs, commit messages, code comments, error strings. Use commas, colons, parentheses or full stops. Australian English throughout.
- All user-facing copy follows [`docs/brand/BRAND.md`](docs/brand/BRAND.md).

## Secure-change checklist

Apply when a change touches credentials, network, file access or logging:

- Credentials are read-only: never write to Claude Code's credential stores. Rotated OAuth tokens persist only to SturtBar's own keychain cache (`com.michaelpalmes.sturtbar.cache`).
- **Never write under `~/.codex` and never refresh Codex tokens.** The Codex lane is a strictly read-only consumer of `~/.codex/auth.json`; a 401 surfaces as "sign in via the codex CLI" — SturtBar never calls `auth.openai.com` and never parses the `id_token` JWT.
- **A disabled provider is inert.** The provider toggles are hard privacy gates: no network, no file reads, no background work, and disabling wipes the provider's persisted snapshot. The only sanctioned pre-opt-in filesystem touch is the Settings-open `authFileExists` stat().
- Least-privilege paths: read only the files and keychain items the feature needs.
- Redact secrets (tokens, emails, bearer credentials) before logging.
- A new network destination ships with its disclosure in the same commit, or not at all.
- No new dependencies.

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

### Commit style

- Conventional commits: `feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `chore`, `ci`, `build`, `revert`.
- No scopes: `feat: add weekly gauge`, not `feat(ui): add weekly gauge`.
- Lowercase imperative subject under 72 characters; no body.
- One logical change per commit; split unrelated work.
- Never bypass hooks with `--no-verify`: fix what the hook flagged instead.

## Layout

- `Sources/SturtBarCore/` library: logging, HTTP, Keychain, OAuth, CostUsage (the testable core, no AppKit)
- `Sources/SturtBar/` app: state layer (UsageStore, scheduler, actors), icon pipeline, menu, windows, settings
- `Tests/SturtBarTests/` plus `Fixtures/`
- `Scripts/` packaging, signing, lint; `Resources/` the app icon (`make_icon.sh` rebuilds the `.icns` from `AppIcon-1024.png`)

## Conventions

- Swift 6 strict concurrency. Explicit `self.` is required and enforced by SwiftFormat; do not remove it.
- Zero third-party dependencies. `os.Logger`, CryptoKit, and Security are system frameworks; do not add packages.
- `LSUIElement` (menu bar only, no Dock icon). Bundle id `com.michaelpalmes.sturtbar`.

## Safety invariants

- All usage fetches go through the `ClaudeUsageClient` actor; never call OAuth-store sync entry points from the MainActor (they can block on keychain prompts).
- Health mapping is typed only; never parse error strings.
- The self-cache keychain read is best-effort and must never prompt (see `KeychainCacheStore.withoutLegacyKeychainUI`); it falls back to Claude Code's keychain.

## Brand voice

User-facing copy follows [`docs/brand/BRAND.md`](docs/brand/BRAND.md): sentence case (native macOS menu item titles are exempt per platform convention) and the dry maritime "Keeper" register. Security and privacy claims are always literal and plain; themed lines are for marketing surfaces only (BRAND.md section 6). Theme density is inversely proportional to glance frequency: the menu bar is mute, the popover terse, the About box can sing. Never imply affiliation with any AI provider; provider names appear only in functional UI, never in flavour copy.
