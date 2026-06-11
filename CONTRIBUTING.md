# Contributing to SturtBar

Thanks for considering it. SturtBar is a small, deliberately narrow project: one provider, zero third-party dependencies, nothing leaves your Mac. Contributions that keep it that way are very welcome.

## Issues first

- **Bug reports** are always welcome. Use the bug report form; precise bearings get fast fixes.
- **Features**: open an issue before writing code. SturtBar says no to most feature ideas on principle (see the scope notes in the feature request form), and it would be a shame to waste your evening on a PR that does not fit the chart. Small fixes (typos, obvious bugs) can skip straight to a PR.

## Development setup

You need macOS 26+ and Xcode. No package installs; the system toolchain is all there is.

```sh
make build      # swift build
make test       # swift test (Swift Testing, not XCTest)
make lint       # SwiftFormat + SwiftLint (install via Scripts/install_lint_tools.sh)
make format     # auto-format
make run        # build, package, and launch a local dev build
```

## Conventions

The short version (AGENTS.md has the detail):

- Swift 6 strict concurrency. Explicit `self.` is required and enforced by SwiftFormat.
- Zero third-party dependencies. System frameworks only; do not add packages.
- Run `make lint` and `make test` before pushing; CI enforces both.
- User-facing copy is Australian English, sentence case, no em dashes.

## Pull requests

`main` is protected: every change lands via a pull request with green CI, squash-merged. That includes the maintainer's.

1. Fork and branch from `main`.
2. Make the change, keep the diff focused.
3. Fill in the PR template; CI (`build-test`) must pass.
4. The maintainer reviews and squash-merges. PRs are taken case by case; small and well-aimed beats large and sweeping.

## Releases

Releases are cut manually by the maintainer (signing and notarisation happen locally; no release credentials live in CI). You do not need to do anything release-related in a PR beyond updating CHANGELOG.md.
