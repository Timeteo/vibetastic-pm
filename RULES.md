---
framework: claude-pm
version: "1.0"
---

## Directory Convention

Each project gets a sibling PM directory named `<project-name>-pm/`:

```
Developer/
├── my-app/          ← target project (any stack)
└── my-app-pm/       ← PM framework instance (this structure)
    ├── CLAUDE.md    ← symlink → framework/CLAUDE.md
    ├── SPEC.md
    ├── PLAN.md
    ├── TASK_LOG.md
    ├── prompts/     ← PM-written project outputs (design-spec, build-spec, task files)
    └── framework/   ← git subtree tracking vibetastic-pm; read-only
        ├── CLAUDE.md
        ├── RULES.md
        ├── WALKTHROUGH.md
        ├── dispatch.sh
        └── prompts/ ← agent prompt templates (designer, architect, tech-lead)
```

The `-pm/` directory is the sole source of truth for project state. The target project directory is treated as an opaque build output.

---

## File Ownership

The PM orchestrator is the **sole writer** to all state files. Subagents receive context slices as input and return structured results. The PM applies those results to state files — subagents never write directly.

| File | Writer | Readers |
|---|---|---|
| SPEC.md | PM | PM, Designer |
| PLAN.md | PM | PM |
| RULES.md | Human (setup) | PM, all agents |
| TASK_LOG.md | PM (append-only) | PM (recovery) |
| prompts/design-spec.md | PM (from Designer output) | Architect, Tech Lead |
| prompts/build-spec.md | PM (from Architect output, Stage 2 only — never modified after) | Tech Lead |
| prompts/task-T0XX.md | PM (awk extract for Architect tasks; direct write for Tech Lead tasks) | OpenCode |
| framework/* | git subtree (read-only) | PM, all agents |

---

## Task Lifecycle

```
pending → in_progress → done
                      → failed
```

- **pending**: task exists but has unmet dependencies or has not been dispatched
- **in_progress**: PM has dispatched the task to an agent; awaiting return
- **done**: agent returned successfully; PM has written outputs and updated PLAN.md
- **failed**: agent returned an error; PM writes `error` field and evaluates retry budget

**Ready computation (PM, each dispatch cycle):**
A task is ready to dispatch when `status == pending` AND all tasks in `depends_on` have `status == done`.

The PM resolves the dependency DAG on each cycle. It does not store `ready` or `blocked` states — those are always computed, never persisted, to avoid stale state.

---

## Dependency Rules

- Dependencies are declared as task ids in `depends_on`.
- Circular dependencies are a fatal error — PM escalates to user and halts.
- A task with `depends_on: []` is always ready to dispatch (after SPEC is approved).
- Tasks with the same dependency profile and no inter-dependency may be dispatched in parallel at PM's discretion.

---

## SPEC Approval Gate

The PM **cannot generate or modify PLAN.md** while `SPEC.md` has `status: draft`.

Flow:
1. PM interviews user, populates SPEC.md body, sets `status: draft`.
2. PM presents SPEC.md to user for review.
3. On user approval: PM sets `status: approved`, writes `approved_at`, updates `updated`.
4. PM generates PLAN.md and appends `spec_approved` event to TASK_LOG.md.

---

## Model Selection

All model assignments are defined in `framework/MODELS.md`. That file is the single source of truth — do not hardcode model slugs in prompts or instructions.

**For agent roles** (Designer, Architect, Tech Lead): use the model in the Agent Roles table.

**For OpenCode tasks**: the Tech Lead recommends a tier (`fast` / `standard` / `heavy`) in its output metadata. The PM reads `framework/MODELS.md` and writes the corresponding model slug to `tasks[n].model` in PLAN.md before dispatching. For Stage 2 Architect-selected tasks, the Architect classifies the task complexity and picks a tier directly.

**Fallback**: if the selected model is unavailable, use the `fast` tier model from `framework/MODELS.md`.

---

## Stages

A **Stage** is a named group of tasks in PLAN.md that represents a logical phase of the project. Stages are defined in the `stages:` list and referenced by `stage:` on each task.

Default stages:
- **Stage 1 — Design**: Designer agent produces `prompts/design-spec.md`
- **Stage 2 — Architecture**: Architect agent produces `prompts/build-spec.md` and selects model
- **Stage 3 — Implementation**: OpenCode executes against the target project

The PM generates stage definitions as part of plan generation. Custom projects may have more or fewer stages.

**Stage status transitions:** `pending → in_progress → done`

A stage moves to `done` when all tasks with that `stage:` id have `status: done`. When a stage reaches `done`, the PM auto-advances to the next stage (see Gate 3 below) — it posts a summary but does not wait.

---

## Lifecycle Gates

**Two hard gates** require an explicit pause for user confirmation in chat: Gate 1 (SPEC approval) and Gate 2 (task double-failure). The PM **must not proceed** past either — no timeout, no self-approval, no inference of consent from prior messages. **Gate 3 (stage transition) auto-advances**: the PM posts a stage summary and continues to the next stage without waiting. The user can interject adjustments at any time, but the default is forward motion.

### Gate 1 — SPEC Approval

**Trigger:** SPEC.md has `status: draft`

**PM behavior:**
1. Display the full SPEC.md body to the user in chat
2. Say: *"Please review the spec above. Type **approved** to unlock the build plan, or give me feedback to revise it."*
3. Wait for user response. If feedback: revise SPEC, re-present, repeat.
4. On approval: set `status: approved`, write `approved_at`, append `spec_approved` to TASK_LOG, then proceed to plan generation.

**PM must not:** generate PLAN.md, dispatch any agent, or take any other action while `status: draft`.

---

### Gate 2 — Task Double-Failure

**Trigger:** A task's `failure_count` reaches 2

**PM behavior:**
1. Do not retry automatically.
2. Report to user in chat: task id, title, both error messages (from TASK_LOG), and current state of PLAN.md.
3. Say: *"Task T00X has failed twice. How would you like to proceed? Options: **retry** / **skip** / **abort**."*
4. Wait for explicit user decision. Apply it.

**Retry budget:** 1 automatic retry per task (i.e., PM retries once on first failure, increments `failure_count`, then hits Gate 2 on second failure). Not configurable — Gate 2 is always at `failure_count == 2`.

---

### Gate 3 — Stage Transition (auto-advance)

**Trigger:** All tasks in Stage N reach `status: done`

**PM behavior:**
1. Mark the stage `status: done` in PLAN.md.
2. Summarize the completed stage in chat: what was built/produced, key outputs, and what Stage N+1 will do.
3. Say: *"Stage N ([name]) is complete — auto-advancing to Stage N+1 ([name]). Reply now if you want to adjust or pause."*
4. **Do not wait.** Immediately mark the next stage `status: in_progress`, append `stage_transition` to TASK_LOG, and dispatch the first ready tasks.
5. If the user sends adjustments before or during Stage N+1, accept them and update PLAN.md/SPEC.md (re-dispatch as needed).

**Rationale:** the self-correction loop and tier escalation keep per-task quality bounded without a human, so the stage boundary no longer needs a hard stop. Gate 1 still guarantees the spec was right before any of this runs.

---

## Escalation Triggers (Autonomous — No Gate)

The PM handles these autonomously without pausing for user input:

| Trigger | Action |
|---|---|
| Circular dependency detected in task graph | Report to user, halt, request PLAN correction |
| OpenRouter unreachable for >2 attempts | Use fallback model, log `model_fallback` event |
| Agent returns malformed/unparseable output | Log, retry once; if second parse failure, treat as task failure (increments `failure_count`) |

---

## Operating lessons (hard-won 2026-06-29)

These override convenience. Each cost real cycles when ignored.

1. **Verify inputs/data before pixels or "looks done".** A component that compiles, passes mocked tests, and renders can still be fed empty or wrong data. Before judging a UI/feature, confirm it is actually *receiving the data it should* — trace the data source, not just the rendered output. Mock-backed tests that bypass the real fetch/decode/transport path are not verification; an integration test must exercise the production path with a real payload. (Cost of ignoring: an empty data binding was mistaken for layout/glass bugs across ~5 build cycles.)

2. **Route open-ended diagnosis to the cheap-but-capable OpenCode tiers, not Anthropic.** Reading code to find a root cause is grunt reasoning the `standard`/`heavy` tiers (deepseek/glm) do well and cheaply. Doing it on the Anthropic subscription burns the biggest cost lever for no quality gain. Dispatch a **read-only** "investigate X → report root cause + minimal fix, change nothing" task; reserve Anthropic for genuine peak-judgment and gate decisions.

3. **Keep spec-writing and code review on the Tech Lead tier (Sonnet/cheap) — never silently on Opus.** The PM/orchestrator must not absorb the Tech Lead role and run every build-prompt and diff-review itself at peak cost. Delegate spec + review to the Tech Lead; the orchestrator decides and gates, it does not personally author and review on Opus. For diff review this is structural: the first pass runs as a read-only Reviewer dispatch (`dispatch.sh --read-only` + `prompts/reviewer.md`, standard tier) or a Sonnet subagent; the orchestrator only adjudicates the verdict (see `VERIFY.md` § Diff review).

4. **Tight visual/layout tuning does not belong in the dispatch loop.** Build + test + screenshot per nudge is far too slow for "move it up 40pt." Do trivial visual nudges directly, or hand the on-device visual pass to the human. Automated screenshots confirm an artifact's presence/absence; they are weak for landing a precise interaction frame (e.g. a mid-scroll state).

---

## Agent Contracts

### Designer
- **Receives:** SPEC.md (full), design brief in prompt
- **Returns:** Structured design spec (markdown) to be written to `prompts/design-spec.md`
- **Does not:** Write files, invoke tools, make implementation decisions

### Architect
- **Receives:** SPEC.md, `prompts/design-spec.md`, target project path, RULES.md (model selection section)
- **Returns:** Structured build spec (markdown) to be written to `prompts/build-spec.md`, plus selected model id
- **Does:** Query OpenRouter for model selection, construct OpenCode invocation command
- **Does not:** Execute OpenCode directly — returns the command string to PM

### Tech Lead
- **Receives:** Issue description, full build-spec, PLAN.md summary, target project path, optional error output
- **Does:** Reads actual source files in the target project to understand current state; fetches Apple/framework docs via Sosumi MCP if relevant; writes a precise task spec
- **Returns:** Task spec section (appended to build-spec.md) + structured YAML metadata (task title, branch, issue refs, depends_on, suggested model)
- **Does not:** Write code, execute commands in the target project, or make implementation decisions beyond speccing
- **Model:** Sonnet by default; PM may use Opus for complex architectural tasks

### Reviewer (first-pass diff review — cheap tier, read-only)
- **Invoked with:** `bash framework/dispatch.sh --read-only <standard-tier-model> <target-project-path> <rendered-reviewer-prompt>` (template: `framework/prompts/reviewer.md`), or as a Sonnet `Agent` subagent with the same rendered prompt
- **Receives:** task spec, `verify_tier`, diff range
- **Returns:** VERDICT (APPROVE / APPROVE-WITH-FOLLOWUPS / REJECT) + findings; the orchestrator adjudicates against the spec and decides merge / reject / re-dispatch
- **Does not:** modify any file (enforced — dispatch exits 21 on a dirty tree), merge, or decide
- **Why:** the intent-review rung of the gate (`VERIFY.md`) must run on every diff; running it on Opus was the measured top cost sink, so Opus only adjudicates

### OpenCode (via PM shell invocation)
- **Invoked with:** `bash framework/dispatch.sh <model> <target-project-path> <per-task-prompt-file>` — PM extracts a task-scoped prompt file via awk before calling dispatch (see CLAUDE.md OpenCode section)
- **PM captures:** stdout/stderr, exit code
- **On success:** PM marks task done, logs output summary
- **On failure:** PM writes exit code + stderr to `error` field, evaluates retry
