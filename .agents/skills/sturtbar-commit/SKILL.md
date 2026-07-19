---
name: sturtbar-commit
description: Plans and creates git commits for the SturtBar repo. Reviews uncommitted changes for red flags, groups them into logical conventional commits and executes them. Use for every commit in this repo, whenever asked to "commit", "commit my changes", "plan commits", "review and commit", or before opening a PR. Project-scoped distillation of ps-commit.
---

# sturtbar-commit

Reviews all uncommitted changes, groups them into logical conventional commits and executes them. Every commit in this repo goes through this flow; never hand-roll `git commit` for substantive changes.

## When to use

- Any time work in this repo needs committing, including before opening a PR
- The user says "commit", "plan commits" or "review and commit"

## Instructions

1. **Gather.** `git status`, `git diff HEAD --stat`, `git ls-files --others --exclude-standard`, then read the full `git diff HEAD` and any untracked files. Nothing to commit: say so and stop. Merge conflicts: ask the user to resolve first and stop.
2. **Validate.** `swift build && swift test` and `make lint` must pass before any commit (AGENTS.md rule). Fix and rerun until clean; do not commit around a red suite.
3. **Light review.** Scan the diff for red flags before planning:
   - Leftover debug output: `print(`, `debugPrint(`, `dump(`, ad hoc `NSLog`
   - Hardcoded secrets, tokens or private URLs
   - Dead or commented-out code, TODO/FIXME without an owner
   - Accidental files: `.DS_Store`, `dist/`, `.build/`, `*.log`
   - House writing rules broken: em dashes, multi-line comments, comments that restate the code
   - Undisclosed network destinations or new file access (see the secure-change checklist in AGENTS.md)
4. **Group into commits.** One logical change per commit; split unrelated work, never split one cohesive change. Tests stage with the source they cover. Messages follow AGENTS.md: `type: subject`, lowercase imperative, under 72 characters, no scope, no body. Types: feat, fix, docs, refactor, perf, test, chore, ci, build, revert.
5. **Approve or auto-commit.** A single commit with no review findings commits straight away; report what was committed. Multiple commits or any finding: present the findings and the plan (message plus files per commit) and wait for approval.
6. **Execute.** `git reset HEAD` first, then per commit: `git add -- <files>` (hunk-split with `git add -p` when one file spans commits), verify with `git diff --cached --stat`, then `git commit -m "..."`. If a hook rejects the commit, stop and show its output; never retry with `--no-verify`.
7. **Verify.** `git log --oneline -n <count>` and `git status`; report anything left uncommitted and why.

## Edge cases

- Ambiguous hunk ownership: ask, do not guess
- Aborted mid-plan: stop; `git reset --soft HEAD~N` undoes the last N commits
- Binary or licensed assets: stage by name, never diff, and check they are meant to be committed
