---
name: sturtbar-release
description: Cutting a macOS release of SturtBar, covering Developer ID signing, Apple notarisation, the styled Retina DMG, the in-app updater's asset contract and the tag/GitHub draft-release flow. Use when asked to "cut a release", "make a DMG", "sign the app", "notarise", "staple", "ship it", "publish a build", "bump the version and release", or when touching Scripts/release.sh, Scripts/sign-and-notarize.sh, Scripts/make_dmg.sh, Scripts/package_app.sh or version.env.
---

# sturtbar-release

Ship a signed, notarised, stapled `.app` and DMG that open on any Mac with no Gatekeeper warning, offline, and that the in-app updater can install.

## Signing modes

`STURTBAR_SIGNING` selects how `Scripts/package_app.sh` signs (default `adhoc`):

- `none`: keeps SwiftPM's linker signature so the execution-policy exception survives; for sandboxed or agent contexts without the Developer Tools privacy permission.
- `adhoc`: throwaway local builds; keychain "Always Allow" ACLs do not survive rebuilds.
- `dev`: day-to-day local builds. A stable self-signed "SturtBar Development" identity (created by `Scripts/setup_dev_signing.sh`, one interactive trust step) so keychain ACLs keep working. Deliberately not an Apple Development cert: on macOS 26, AMFI kills team-ID-signed binaries without a provisioning profile.
- `developer-id`: releases only. Hardened runtime, timestamp and entitlements; requires `STURTBAR_SIGNING_IDENTITY`.

## One-time setup

1. **Xcode 27 selected** (`xcode-select -p`; `xcrun --show-sdk-version` prints 27.x). A 26-SDK build breaks the Settings pickers on macOS 27. `package_app.sh` links with `-isysroot` (SwiftPM's default build system otherwise records the deployment target as the SDK, so an Xcode 27 build still reported `sdk 26.0`) and refuses any binary whose `vtool -show-build` is not `sdk` ≥ 27 and `minos` 26.0. If it refuses, switch Xcode with `sudo xcode-select -s /Applications/<Xcode 27>.app` rather than editing the check.
2. A **Developer ID Application** cert in the keychain: `security find-identity -p codesigning -v`.
3. Notary credentials, exactly one mode (all three documented in the `sign-and-notarize.sh` header):
   - `STURTBAR_NOTARY_PROFILE`: a notarytool keychain profile, created once via `xcrun notarytool store-credentials <name> --apple-id <email> --team-id <TEAMID>` (prompts for an app-specific password from appleid.apple.com, never the Apple ID password).
   - `STURTBAR_NOTARY_KEY_ID` + `STURTBAR_NOTARY_ISSUER` + `STURTBAR_NOTARY_KEY_PATH` (App Store Connect API `.p8` on disk).
   - The same trio with `STURTBAR_NOTARY_KEY_P8` instead (inline key material; literal `\n` sequences allowed).
4. An authenticated `gh` CLI (`gh auth status`).
5. Export for the release run:
   ```bash
   export STURTBAR_SIGNING_IDENTITY="Developer ID Application: Your Name (<TEAMID>)"
   export STURTBAR_NOTARY_PROFILE="<profile name>"
   ```

## Cutting a release

1. **Check prices are current.** Open SturtBar and let a cost scan finish, then run `make cost-audit`. It reprices your local logs from its own rate table and diffs every model against the app's snapshot. Any `MISMATCH` or unpriced model means a new model or price change: add it to both `CostUsagePricing+Tables.swift` and the audit's table from the Anthropic and OpenAI pricing pages (never from models.dev or CodexBar alone; CodexBar had gpt-5.6-sol wrong), then rerun. A `+` on the app's cost line is the same signal.
2. **Bump `version.env`** (`MARKETING_VERSION` and `BUILD_NUMBER`) on a branch, open a PR, squash merge. The ruleset rejects direct pushes to main for everyone; tags are exempt and pushed by `release.sh` only. An already-tagged version is refused.
3. From a clean, up-to-date main checkout, run **`make release`**. It runs: guards (gh installed, clean tree, untagged version, `swift test -q`), then `sign-and-notarize.sh` (Developer ID package, signature verify, notarise, staple and Gatekeeper-check the app, then build the styled DMG and notarise, staple and Gatekeeper-check it separately), then zip + `.sha256` + dSYM zip, then the annotated tag `v<version>` pushed, then a draft GitHub release with DMG (listed first: the human installer), zip, sha256 and dSYM.
   - **Needs a GUI session.** Finder styles the DMG, so this cannot run headless or over SSH, and the first run prompts once for Finder automation permission.
   - Budget time for two notarisation waits (app, then DMG), mostly waiting on Apple.
4. **Publish the draft on GitHub.** This step is load-bearing: the in-app updater reads `releases/latest`, which excludes drafts and pre-releases, so a draft is invisible to every installed copy until published.

Partial flows:

- `make package`: local `dist/SturtBar.app` in the current signing mode.
- `make dmg`: package plus styled DMG; an unsigned preview unless `STURTBAR_SIGNING_IDENTITY` is set, and never notarised.
- `Scripts/sign-and-notarize.sh`: full sign, notarise and staple for app and DMG, no tag, no GitHub.

## The updater contract

`release.sh` and the updater (`Sources/SturtBarCore/Updates/`, `Sources/SturtBar/UpdateInstaller.swift`) share a strict asset contract. Break any line of it and installed apps cannot update:

- The tag must parse as semver; a leading `v` is fine (`v1.2.0`).
- The zip asset must be named exactly `SturtBar-<bareVersion>.zip` (no `v` prefix).
- The checksum asset must be named `<zip name>.sha256` and record a bare filename, which is why `release.sh` runs `shasum -a 256` from inside `dist/`. The installer is fail-closed: a missing or mismatched checksum aborts the install.
- The installer also verifies asset size, GitHub's reported digest, bundle id and version, and a code signature pinned to the running app's own Team ID. Dev and ad-hoc builds therefore never auto-swap; they reveal the download in Finder instead.

## Traps

- **The DMG must mount at `/Volumes/SturtBar`.** The Finder styling addresses the disk by volume name, so `-mountrandom` or `-nobrowse` makes it fail with error -1728. `make_dmg.sh` pre-detaches a stray volume from a crashed run and retries the styling four times; if it still fails, grant the terminal Finder automation (System Settings > Privacy & Security > Automation) and re-run `make dmg`.
- **DMG art is an exact pair**: `Resources/dmg/dmg_bg.png` (660x400) and `dmg_bg@2x.png` (1320x800), merged with `tiffutil -cathidpicheck` (1x first) so Finder serves the Retina rep. Icon positions (180,167) and (480,167) are empirically tuned against Finder's ~3pt icon-origin offset on macOS 26; re-measure if the art or the OS title-bar height changes.
- **`Scripts/SturtBar.entitlements` is intentionally empty.** Nothing in the app needs one (generic-password keychain reads need no entitlement). If a change seems to need an entitlement, question the change before adding one.
- **Stapling dirties the bundle.** `sign-and-notarize.sh` strips xattrs again after stapling because the ticket rewrite would otherwise dirty the later zips. Keep that ordering when editing the script.
- **Never xattr or re-sign the app while staging the DMG.** `make_dmg.sh` copies the already-signed, stapled bundle verbatim; touching it breaks the code seal. Fix signing problems back in `package_app.sh` / `sign-and-notarize.sh` instead.

## Verify

Run all of these and fix until clean:

```bash
codesign -dvv dist/SturtBar.app                    # Authority=Developer ID Application, runtime flag, timestamp
codesign -d --entitlements - dist/SturtBar.app     # expect no entitlement keys
xcrun stapler validate dist/SturtBar.app           # "The validate action worked!"
xcrun stapler validate dist/SturtBar-<version>.dmg # same
spctl -a -t exec -vv dist/SturtBar.app             # accepted, source=Notarized Developer ID
spctl -a -t open --context context:primary-signature -vv dist/SturtBar-<version>.dmg
```

Then mount the DMG, drag-install, launch, and after publishing confirm an installed copy's update check sees the new version.

## Troubleshooting

- **Finder styling fails (-1728)**: automation permission missing, a stray `/Volumes/SturtBar`, or the Finder registration race; see the first trap.
- **notarytool returns `Invalid`**: `xcrun notarytool log <submission-id> --keychain-profile <profile>` names the offending file.
- **The updater never sees the release**: it is still a draft or marked pre-release, or an asset name broke the contract above.
