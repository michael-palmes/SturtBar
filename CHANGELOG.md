# Changelog

All notable changes to SturtBar are recorded here.

## 1.1.0

- New opt-in Codex provider: track OpenAI Codex (ChatGPT) usage alongside Claude. Off by default: until you turn it on in Settings → Providers, SturtBar makes no calls to OpenAI and never reads `~/.codex`. When enabled it reads `~/.codex/auth.json` read-only (never writes it, never refreshes Codex tokens) and shows the 5-hour and weekly windows with the plan badge.
- Providers are now individually toggleable, Claude included (on by default). A disabled provider is fully inert: no network, no file reads, and its cached snapshot is wiped. With both off, the card says so plainly.
- With two providers enabled the popover stacks both sections in one card, and the menu bar follows whichever provider is most constrained (highest session usage) with a one-letter prefix ("C 45%", "X 81%"). A new "Menu bar shows" setting can pin it to one provider. Single-provider displays are unchanged.
- Notices to Mariners now name the coast: notification bodies open with the provider ("Claude: session spent…"), and per-provider notices no longer replace each other. One housekeeping note: the first notice after this upgrade may stack with one left over from an older version.
- Provider links in the menu (console/usage and status pages) follow the enabled set.

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
