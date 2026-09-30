# Changelog

All notable changes to SturtBar are recorded here.

## Unreleased

- Built with Xcode 27 and the macOS 27 SDK (still runs on macOS 26), so the Settings pickers work on macOS 27. The packaging script now refuses a release binary that does not record the macOS 27 SDK, since SwiftPM's default build system could silently record the older one.
- The menu bar icon keeps its place: SturtBar now names its status item, carries your existing position over, keeps it through the rare startup recovery (which could drop the icon at the far left after an update), and discards a corrupt saved position that could hide the icon off screen.
- Settings and About open on the Space you are working in (including under Stage Manager) instead of switching to another desktop.
- Cost estimates cover the current models: Claude Opus 5, Opus 5.5, Fable 5.1 and Sonnet 5, plus Codex gpt-5.6 (Sol, Terra, Luna) and gpt-6-astra, at the providers' published rates. Fable 5.1 and Opus 5.5 were priced at nothing before, so 30-day totals could read about half the true figure.
- Built-in prices now always win over the models.dev catalogue, which only fills in models a release does not know yet. The catalogue refresh had stopped updating on 1 August and was being re-downloaded on nearly every scan; it now keeps only the Anthropic and OpenAI entries, fetches at most about once a day (every 6 hours while a model has no price), and no longer reads CodexBar's cache folder.
- A total that leaves out usage with no known price is marked with a "+" (for example "$4,458+"), and the unpriced model appears in the list as "no price" with its token count, instead of being dropped silently.
- Claude fast mode is priced (twice the standard rate on Opus 5, Opus 5.5 and Opus 4.8). Fast turns on other models are shown as unpriced rather than guessed.
- Codex long-context rates now apply per turn, as OpenAI bills them, instead of to a whole day's usage, which had overcharged busy days.
- Sturdier log scanning: a half-written last line is read again next time instead of being lost, a replaced log file is re-read in full, repeated proxy snapshots count once, huge or malformed token counts can no longer crash a scan, and the cache is rebuilt after a time zone change.
- Lighter scans: model names are resolved once, out-of-window rows are skipped before pricing, and the cost cache is not rewritten when nothing changed. The first scan after updating rebuilds the cache once.
- SturtBar no longer refreshes Claude sign-in tokens. Refreshing spent Claude Code's own refresh token, which could sign Claude Code out and was the likely cause of repeated "sign in again" loops. When the token expires, the card keeps your last reading, greys it and says "Waiting for Claude Code to refresh its sign-in"; clicking it opens Claude Code, which renews the token, and SturtBar picks it up. If Claude Code has signed out, the card asks you to sign in instead of waiting. One fewer network destination: `platform.claude.com` is no longer contacted. If SturtBar already rotated your token before this update, run `claude /login` once.
- A token Anthropic rejects now leads to the sign-in banner instead of an endless "Refresh issue, retrying".
- Codex: an HTTP 403 now reads "Codex denied access to usage data" instead of wrongly asking you to sign in again, and a weekly-only or 30-day reply is labelled by its length (Weekly, Monthly) instead of "Session", with warnings for the monthly window too.
- The model rows read "Fable weekly" (and so on), a duplicate "All models" row no longer appears, and an empty routines payload no longer shows a fake 0% bar.
- When weekly usage stands in for a missing session window, the card shows it as Weekly (not Session) and warnings come from the weekly lane only instead of firing session warnings too.
- Error advice for a sign-in missing the usage scope now points at `claude /login` (the old `setup-token` advice produced a token with the same problem), and a malformed expiry in the credentials file can no longer crash a usage check.

- Keychain reads SturtBar makes without asking can no longer show macOS's older "wants to use your confidential information" dialog, and a prompt setting of Never now blocks only prompts, never the silent reads SturtBar relies on.
- If macOS stops letting SturtBar update its own cached copy of the token (for example after switching between builds), SturtBar replaces that one item quietly instead of staying stuck. It never touches Claude Code's own Keychain item.

## 1.3.1

- When Claude needs attention, the card now shows a proper banner instead of a red status line: what happened, a "Sign in to Claude Code" button, and (only when relevant) a smaller "Still not working? Allow Keychain access" fallback. Signing in via `claude /login` is always the first remedy; the Keychain ask is reserved for when a fresh sign-in has not helped.
- The sign-in helper now lives in `~/.sturtbar`, a folder that holds only that script, and runs `claude /login` from there. The terminal window explains in plain words what the folder is and what any Claude Code workspace prompt covers (that folder alone, never your home directory or files), then opens Claude Code after a short pause so you can read it. This also stops the macOS "access data from other apps" prompts the old Application Support location triggered; the old script is cleaned up on first use.

## 1.3.0

- The settings window is reorganised into six tabs (General, Providers, Display, Cost, Notifications, Updates) instead of one tall pane, at a fraction of the height. It keeps one steady size while you switch tabs.
- Built-in updates, strictly opt-in: SturtBar can ask GitHub once a day whether a newer release exists (asked once on first launch; toggle under Settings > Updates, and turning it off wipes the lane's stored state). The menu's "Check for Updates" becomes "Install Update X.Y.Z" when one is waiting; installing downloads the archive, verifies its SHA-256 checksum and Developer ID signature against the running app's own identity, swaps the bundle and relaunches. Standard users get the normal macOS administrator dialog; where that is unavailable, the verified update is revealed in Finder for a manual install.
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

## 1.2.0

- The popover card gains optional rows for model-scoped weekly limits, such as the Fable allowance, matching what Claude Code's `/usage` shows. Toggle under Settings > Display, on by default. (Recorded after release; 1.2.0 shipped without a changelog entry.)

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
