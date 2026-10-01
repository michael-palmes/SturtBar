---
name: sturtbar-pr-descriptions
description: Writes pull request titles and descriptions for the SturtBar repo to one fixed, short standard (Summary, Privacy, Testing). Use whenever opening a PR, writing, rewriting or updating a PR description, PR body or PR title, or running gh pr create or gh pr edit. Triggers on "open a PR", "create a pull request", "PR description", "PR body", "PR title", "update the PR".
---

# sturtbar-pr-descriptions

One fixed shape for every PR: Summary, Privacy and Testing, under 200 words. The diff, the commit list and the repo docs carry the detail.

## When to use

- Opening any PR in this repo (`gh pr create`)
- Writing, rewriting or updating a PR title or description (`gh pr edit`)

## The standard

**Title**: `type: lowercase imperative subject`, under 72 characters, no scope (AGENTS.md commit style). It becomes the squash-merge commit on `main`, so write it as one.

**Body**: under 200 words (#41 ran to 733 and #42 to 521; nobody reads that far), Australian English, no em dashes. Exactly these three sections:

```markdown
## Summary

- <3 to 5 bullets, one shipped change each, present tense>
- <a deliberate behaviour change or known limit is a bullet too>

## Privacy

<One or two lines on network destinations, file and keychain access, data handling. "No change." when nothing moved.>

## Testing

- <build, test count and lint in one line>
- <what the new tests cover, in one line>
- <manual checks still to do, as short bullets, only when the change needs them>
```

## Hard exclusions

PR text is public, and GitHub keeps every edited revision. Each of these has leaked before; the alternative is always available.

1. **Nothing that lives outside the repo.** #43 sent reviewers to a private planning doc they cannot open. No local paths, planning docs, handoffs, scratchpad files or memory notes. Put the steps that matter inline (as #43's Testing section now does) or point at a repo file such as `docs/TROUBLESHOOTING.md`.
2. **No planning vocabulary.** Gate labels (G1, G2), branch or stage numbers ("branch 5", "stages 1 and 2") and tracker shorthand ("July #1879") mean nothing without the private notes. Describe the check or the change itself.
3. **No session or review narrative.** Not "found while verifying" or "an independent review found". State what the PR does now; a fixed review finding is simply part of the change.
4. **No bare upstream numbers.** A bare `#1936` points at SturtBar's own issue 1936. Qualify it as `owner/repo#1936`, or leave it out.
5. **No commit-by-commit recounts.** The commit list already shows them.

## Instructions

1. **Draft** the title and body to the template, writing the body to a scratchpad file (never inside the repo).
2. **Pre-flight** the draft and fix until both checks are clean:
   ```bash
   wc -w <body-file>   # under 200
   grep -n $'\xe2\x80\x94' <body-file>   # em dashes: must print nothing
   grep -niE '/Users/|~/(Documents|Desktop|Downloads)|planning|handoff|scratch ?pad|memory note|(^|[^[:alnum:]])G[0-9]([^[:alnum:]]|$)|(branch|stage)s? [0-9]|(^|[^[:alnum:]/])#[0-9]{4,}' <body-file>   # must print nothing
   ```
3. **Open or update** the PR with gh on its own, not chained to other commands: `gh pr create --title "type: subject" --body-file <body-file>`, or `gh pr edit <n> --title "type: subject" --body-file <body-file>`.
4. **Read it back** with `gh pr view <n> --json title,body` and confirm every reference resolves inside the repo.

## Example

Title: `fix: unblock the 1.3.1 release run`

```markdown
## Summary

- `make release` no longer aborts at the DMG step (exit 141). The pre-flight `awk` now reads `hdiutil info` to EOF instead of exiting early and killing the script with SIGPIPE.
- The keychain fallback line uses `Text` interpolation, clearing a macOS 26 deprecation warning in release builds.

## Privacy

No change.

## Testing

- Release build is warning-free; `swift test` (785 tests) and `make lint` pass.
- The `awk` fix is checked against simulated multi-image `hdiutil info` output.
```
