# Changelog

All notable changes to SturtBar are recorded here.

## Unreleased

- New opt-in "Include Claude Desktop sessions" cost setting, off by default: when on, the local cost estimate also scans Claude Desktop's agent transcripts under `~/Library/Application Support/Claude` (read-only, token counts only, de-duplicated against `~/.claude/projects`). While off, those folders are never touched.
- The Claude plan label now distinguishes Max 5x and Max 20x subscriptions instead of a flat "Max".
- Usage readings are now honest at the low end: every positive value below one percent shows as "<1%" (in the card, the menu bar text, and the usage line) instead of rounding to "0%" or "1%". True zero still shows "0%".
- After you use the sign-in helper, SturtBar now rechecks for the fresh credentials a few times over the next minutes, so the card and the attention badge clear on their own once the login completes instead of waiting for the next scheduled refresh.
- The keychain consent explainer now says plainly that if the macOS dialog asks for your Mac login password, the entry is handled by macOS itself and SturtBar never sees what you type.
- The menu bar text now follows the quota that actually blocks you: when a weekly limit is exhausted while the session window is fresh, it shows the weekly reading (0% left and the weekly reset) instead of a misleading fresh session percentage. Applies to both providers; the card and icon already showed both windows.
- Readings now flip at the reset, not minutes later: when a quota window's reset time passes, SturtBar schedules one extra refresh just past the boundary (once per boundary, both providers) so an exhausted reading clears the moment it actually resets. Biggest win on the manual cadence, where nothing else would refresh until you looked.
- SturtBar now respects Low Power Mode and thermal pressure: while either holds, the interval refresh skips every other tick (doubling the effective interval, never stalling). No setting; it just behaves.
- Guards against a macOS 26 startup failure where the system rejects the menu bar item and the app would run invisibly: SturtBar now checks shortly after launch and rebuilds the item once if it has no window. An item you have hidden yourself is left alone.
- The menu bar pace no longer shows a signed zero: a delta that rounds to zero reads "0%" instead of "+0%" or "-0%".
- Quota warnings now also cover the named extra windows the card shows, such as a model-scoped weekly carve-out (like the Fable allowance) or Daily Routines. They use your existing weekly thresholds and toggle; the notice names the allowance ("Claude: 45% of the Fable allowance remains").
- Long reset countdowns keep their minutes when there are no whole hours: "in 2d 45m" instead of "in 2d".
- Keychain prompts are now opt-in and off by default, for new and existing installs alike: SturtBar never shows a macOS Keychain prompt unless you allow it. A new "Ask for Keychain access when needed" checkbox under the Claude provider in Settings controls it, and the card's "Allow Keychain access to reconnect" line offers a one-click opt-in (Continue enables the setting and retries; Not now changes nothing). Silent reads that macOS already permits keep working either way, so most setups notice no difference; the startup first-run prompt and background credential syncs now happen only after you opt in.
- When SturtBar can see that a Claude Code sign-in exists in the keychain but cannot read it, the card now offers the Keychain remedy instead of wrongly suggesting a fresh sign-in, and the tooltip says whether the cause is prompts being off or the item's permission resetting.
- One-click recovery when the Claude session expires: the card's status line becomes the action. "Sign in to Claude Code" opens your default terminal running `claude /login` via a small helper script under `~/Library/Application Support/SturtBar` (SturtBar itself never runs the claude CLI); "Allow Keychain access to reconnect" retries with the consent explainer. Error details moved to tooltips.
- The keychain explainer is now a real consent dialog: it explains what is about to happen and what the token is used for, with Continue and Not now buttons. Not now skips the OS dialog entirely and is never punished.
- The menu bar icon now carries a small exclamation badge when Claude needs attention you can act on (sign in again, or grant Keychain access), distinct from the plain dimming that means stale data.

## 1.1.0

- New opt-in Codex provider: track OpenAI Codex (ChatGPT) usage alongside Claude. Off by default: until you turn it on in Settings → Providers, SturtBar makes no calls to OpenAI and never reads `~/.codex`. When enabled it reads `~/.codex/auth.json` read-only (never writes it, never refreshes Codex tokens) and shows the 5-hour and weekly windows with the plan badge.
- Providers are now individually toggleable, Claude included (on by default). A disabled provider is fully inert: no network, no file reads, and its cached snapshot is wiped. With both off, the card says so plainly.
- With two providers enabled the popover stacks both sections in one card, and the menu bar follows whichever provider is most constrained (highest session usage) with a one-letter prefix ("C 45%", "X 81%"). A new "Menu bar shows" setting can pin it to one provider. Single-provider displays are unchanged.
- Cost tracking now spans both providers. With "Track local token cost" on, SturtBar estimates Codex spend from `~/.codex` (read-only, on demand, never in the background) the same way it does Claude from `~/.claude`, with an inline cost line in each provider's card section and a separate cost history chart per provider.
- New "5-day work week (Mon-Fri)" pacing option, off by default: the weekly gauge paces quota across Monday to Friday and treats weekends as zero usage, so the pace marker tracks a working week rather than a calendar one.
- Notices to Mariners now name the coast: notification bodies open with the provider ("Claude: session spent…"), and per-provider notices no longer replace each other. One housekeeping note: the first notice after this upgrade may stack with one left over from an older version.
- Provider links in the menu (console/usage and status pages) follow the enabled set.
- The Refresh and Settings menu items now carry SF Symbol glyphs, matching the system About and Quit icons on macOS 26.
- Apple Silicon only, now enforced in the tooling: the packaging scripts always build arm64 (the `--universal` Intel opt-in is removed) and the README requirements name an Apple Silicon Mac.
- Agent guidance rewritten around key principles (privacy, security and performance first, least access, every network destination disclosed), with commit style rules and a CLAUDE.md symlink so Claude Code reads the same instructions.
- Performance made explicit: the brand guide gains the keeper's economy (lean by construction, measured before claimed), the README gains a Performance section with measured footprint figures and the method behind each, the Credits line drops the unmeasured "faster", and unmeasured performance numbers are now a hard brand boundary.
- Privacy made explicit: the README now lists every network destination (usage API, token refresh, pricing catalogue), the About box states the privacy posture, and the keychain explainer says plainly that SturtBar reads the token and never changes it. Undisclosed network destinations are now a hard brand boundary.
- The denied-keychain error no longer suggests a setting that doesn't exist; it now says to press ⌘R and choose Always Allow.
- Fixed a loop where SturtBar kept showing "Re-authenticate in Claude Code" even after a successful re-login. Re-authenticating recreates Claude Code's keychain item (resetting SturtBar's read permission), and a stale `~/.claude/.credentials.json` could shadow the fresh keychain credentials:
  - When the only readable credentials are stale and a Claude keychain item exists that SturtBar can't read, the error now says what to actually do (open the menu, press ⌘R, and allow Keychain access) instead of suggesting another re-login.
  - A hard auth block can no longer become permanent when SturtBar can't observe credential changes at all; it now retries once an hour in that state.
  - "Refresh token missing" errors now name the credential store they came from (file, cached copy, or keychain item) to make remote diagnosis possible.
- Added TROUBLESHOOTING.md with a step-by-step recovery guide for authentication issues.

## 1.0.2

- "Show usage as used" now also flips the pace tip (the reserve/deficit marker): it marks expected usage on the same axis as the bar fill instead of staying on the remaining side. Reserve stays green and deficit red in both modes.

## 1.0.1

- Installer now ships as a styled, notarised DMG: open it and drag SturtBar onto Applications, guided by the Sturt Light chart. The `.zip` of the app remains available for scripted installs.
- New display options in Settings: "Show reset time as clock" (absolute clock instead of a countdown) and "Show usage as used" (meters fill as you consume quota instead of showing what's left). Both default off.

## 1.0.0

First light. (The Sturt Light itself was first lit in 1852.)

- Menu bar usage meter for Claude Code: session and weekly windows, exact percentages, and reset countdowns.
- The Logbook popover with spend for the period and a cost history chart.
- Notices to Mariners: opt-in notifications at 75% of a session, at the limit, on refloat, and as the week draws in.
- Reads Claude Code's existing credentials (`~/.claude/.credentials.json`, falling back to the login keychain) and never writes to them. Any refreshed token persists only to SturtBar's own keychain cache.
- Local spend scanning of `~/.claude/projects` session logs; no upload, no telemetry, no account.
- Settings: refresh cadence, menu bar text, cost toggle, notification thresholds and sound, launch at login.
- macOS 26+, Apple Silicon (arm64), a single signed and notarised build, zero third-party dependencies.
