# Changelog

All notable changes to SturtBar are recorded here.

## Unreleased

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
