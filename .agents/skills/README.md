# Skills Reference

What a skill is and how to load one. The only skill index is `AGENTS.md` § Skills, which groups
the skills as **Stages** and **Cross-cutting**.

## What a Skill Is

A skill is a packaged constraint document that tells an agent *how* to carry out one specific stage of work. Each one lives in its own `<name>/` directory here. Reading a skill before implementing prevents re-deriving patterns that have already been agreed.

**Always invoke the relevant skill before implementing manually.** The skills index in `AGENTS.md` lists every skill and its trigger condition.

## Skill Directory Structure

Each skill directory follows this layout:

```
.agents/skills/<name>/
├── SKILL.md        # Always present — overview, scope, when to use, core pattern
├── REFERENCE.md    # Present for complex skills — mechanism detail and decision tables
├── EXAMPLES.md     # Present for complex skills — worked patterns and anti-patterns
└── scripts/        # Present only when SKILL.md or the orchestrator names a script in it
```

Load `SKILL.md` first. If the task is non-trivial, also load `REFERENCE.md` and `EXAMPLES.md` — they contain detail that `SKILL.md` compresses out.

## How to Read REFERENCE.md and EXAMPLES.md

`REFERENCE.md` contains decision tables and mechanism detail — the "why" behind the patterns. Read it before a stage starts to understand the invariants you are operating under.

`EXAMPLES.md` contains worked patterns — concrete before-and-after code or prompt snippets. Read it when you are mid-stage and unsure which of several options to pick. Examples are vetted; prefer them over re-deriving a pattern from first principles.

Both files are scoped to their skill — they never repeat content from `SKILL.md`, `AGENTS.md`, or `CONTEXT.md`. If the same constraint appears in both, the `AGENTS.md` or `CONTEXT.md` version is authoritative.

## Invocation Protocol

1. Identify the current stage from the issue body's `AGENT-STATE` JSON block. A Stages skill matches the stage; a Cross-cutting skill is loaded when its trigger in `AGENTS.md` § Skills applies.
2. Open the matching skill's `SKILL.md` in `.agents/skills/<name>/`.
3. If the skill has `REFERENCE.md`, load it now — before reading any source file.
4. If the skill has `EXAMPLES.md`, keep it open as a lookup during implementation.
5. Follow `AGENTS.md` §Session Initialisation → Context Protocol before opening source files.

Never substitute reading the skill for reading the codebase. Skills constrain *how* to work; the codebase tells you *what* exists.
