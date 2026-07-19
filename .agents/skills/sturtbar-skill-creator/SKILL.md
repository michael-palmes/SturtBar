---
name: sturtbar-skill-creator
description: Creates or updates project skills and slash commands for the SturtBar repo. Use when asked to "add a SturtBar skill", "create a project skill", "add a slash command", "update a skill", "document a workflow", or extend SturtBar's agent infrastructure under .agents/ or .claude/. Project-scoped distillation of ps-agent-skill-creator.
---

# sturtbar-skill-creator

Builds new in-repo skills and slash commands for SturtBar that actually work, not ones that merely look complete. Project-scoped; lives in and commits with this repo. For personal, cross-project skills use the global `ps-agent-skill-creator` instead.

## When to use

- Adding a new project skill under `.agents/skills/<name>/`
- Adding a slash command under `.claude/commands/<name>.md`
- Improving an existing SturtBar skill or command

## Instructions

1. **Interview first, ask before writing.** Ask focused multiple-choice questions covering: purpose, trigger phrases, the exact workflow, edge cases, failures already seen, and validation steps. Do not write skill content from assumptions; skipping this produces generic, low-value skills every time.
2. **Name it for the repo.** A descriptive `sturtbar-` or domain name in kebab-case (e.g. `sturtbar-release`). No `ps-` prefix: that is reserved for global personal skills.
3. **Place it correctly.**
   - Skill goes to `.agents/skills/<name>/SKILL.md` (plus `REFERENCE.md` if it would exceed ~250 lines). Claude Code discovers skills through the `.claude/skills` symlink; never replace that symlink with a real directory.
   - Command goes to `.claude/commands/<name>.md` (a real directory beside the symlink).
4. **Write to the quality bar** (below). No vague rules.
5. **Register it.** Add a one-line entry to the Skills section of `AGENTS.md`.
6. **Verify immediately.** Run the checklist and fix until clean before responding. Do not defer.

## Quality bar

- **Description is king.** The YAML `description` is the only thing seen before loading. Pack it with concrete trigger keywords and phrases, in third person. Vague descriptions never get loaded.
- **Only add what the agent doesn't know.** Cut general knowledge; the context window is shared.
- **One skill = one capability.** Never merge unrelated workflows; it breaks trigger matching.
- **Every rule traces to a real failure.** "Run `shasum` from inside `dist/` so the recorded filename is bare, or the updater's checksum parser rejects it" beats "name artefacts correctly".
- **Every prohibition includes an alternative.** A bare "don't" is a dead end.
- **One concrete example beats paragraphs.** Show a snippet.
- **Validation loop.** Give exact commands and say to fix and rerun until passing (`swift build && swift test`, `make lint` where the skill touches code).
- **House style.** Australian English, no em dashes anywhere (use commas, colons, parentheses or full stops). User-facing copy examples follow `docs/brand/BRAND.md`.
- **Skip what linters enforce.** Reference SwiftFormat and SwiftLint (`Scripts/lint.sh`) instead of restating style.

## Pre-finalisation checklist

- [ ] Description has concrete triggers, third person
- [ ] Instructions are numbered, actionable steps
- [ ] Every prohibition has an alternative
- [ ] No vague rules ("write clean code")
- [ ] Validation loop included (`swift build` / `swift test` / `make lint` as relevant)
- [ ] SKILL.md under ~250 lines (split to REFERENCE.md if not)
- [ ] One capability only
- [ ] Registered with a one-line entry in the Skills section of `AGENTS.md`
- [ ] No em dashes: `grep -rn $'\xe2\x80\x94' .agents/skills/<name>/` comes back empty

## Example: SKILL.md skeleton

```markdown
---
name: <name>
description: <what + when, third person, with trigger keywords>
---

# <name>

<one-sentence purpose>

## When to use
- <trigger>

## Instructions
1. **Step**: actionable, with exact command
2. **Verify**: run `swift build && swift test` and `make lint`; fix and rerun until clean
```
