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
| prompts/* | PM (from agent output) | Architect, OpenCode |
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

## Model Selection Algorithm

Used by the Architect agent when preparing an OpenCode invocation.

### Model Tier Policy

Two tiers, non-negotiable:

| Role | Model class | Rationale |
|---|---|---|
| Designer agent | Opus (latest) | Creative and structural reasoning at planning stage |
| Architect agent | Opus (latest) | Architecture decisions require peak complex reasoning |
| OpenCode invocation | Best coding-optimized model (Sonnet-class or equivalent) | Code generation is throughput work — Opus is overkill and expensive for keystrokes |

Opus-class models are **excluded** from OpenCode model selection. The selection algorithm below applies only to the OpenCode invocation model, and must filter out Opus before ranking.

Fallback for Designer and Architect agents (if API unavailable): `claude-opus-4-7`  
Fallback for OpenCode: `claude-sonnet-4-6`

### Step 1 — Classify task type

| Task type | Capability requirements |
|---|---|
| `design` | strong reasoning, creativity, instruction-following |
| `architecture` | complex reasoning, large context window |
| `implementation` | code generation, language-specific capability |
| `review` | analysis, attention to detail, long context |

### Step 2 — Query OpenRouter

```
GET https://openrouter.ai/api/v1/models
```

Filter models where:
- The model's reported capabilities match the requirements for the task type
- Context window ≥ minimum required (default: 32k for implementation, 128k for architecture/review)

### Step 3 — Rank and select

Rank filtered models by priority:
1. Capability match score (higher = better)
2. Context window (larger = better, up to task requirement)
3. Cost per token (lower = better)

Select rank 1. Write selected model id to `tasks[n].model` in PLAN.md before dispatching.

### Step 4 — Fallback

If OpenRouter query fails or returns no matching models:
- Log `model_selection_failed` event in TASK_LOG.md with reason
- Use fallback: `google/gemini-2.5-flash` for OpenCode invocations (never Opus — see Model Tier Policy above)

---

## Stages

A **Stage** is a named group of tasks in PLAN.md that represents a logical phase of the project. Stages are defined in the `stages:` list and referenced by `stage:` on each task.

Default stages:
- **Stage 1 — Design**: Designer agent produces `prompts/design-spec.md`
- **Stage 2 — Architecture**: Architect agent produces `prompts/build-spec.md` and selects model
- **Stage 3 — Implementation**: OpenCode executes against the target project

The PM generates stage definitions as part of plan generation. Custom projects may have more or fewer stages.

**Stage status transitions:** `pending → in_progress → done`

A stage moves to `done` when all tasks with that `stage:` id have `status: done`. When a stage reaches `done`, the PM hits Gate 3 (see below) before advancing.

---

## Lifecycle Gates

Three gates require an explicit pause for user confirmation in chat. The PM **must not proceed** past a gate autonomously. Each gate is a hard stop — no timeout, no self-approval, no inference of consent from prior messages.

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

### Gate 3 — Stage Transition

**Trigger:** All tasks in Stage N reach `status: done`

**PM behavior:**
1. Mark the stage `status: done` in PLAN.md.
2. Summarize completed stage in chat: what was built/produced, key outputs.
3. Say: *"Stage N ([name]) is complete. Ready to begin Stage N+1 ([name]). Type **proceed** to start, or give me any adjustments first."*
4. Wait for explicit user go-ahead. Accept feedback or adjustments before advancing.
5. On confirmation: mark next stage `status: in_progress`, append `stage_transition` event to TASK_LOG, dispatch first ready tasks.

**PM must not:** dispatch any task in Stage N+1 until user has explicitly confirmed.

---

## Escalation Triggers (Autonomous — No Gate)

The PM handles these autonomously without pausing for user input:

| Trigger | Action |
|---|---|
| Circular dependency detected in task graph | Report to user, halt, request PLAN correction |
| OpenRouter unreachable for >2 attempts | Use fallback model, log `model_fallback` event |
| Agent returns malformed/unparseable output | Log, retry once; if second parse failure, treat as task failure (increments `failure_count`) |

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

### OpenCode (via PM shell invocation)
- **Invoked with:** `bash framework/dispatch.sh <model> <target-project-path> <per-task-prompt-file>` — PM extracts a task-scoped prompt file via awk before calling dispatch (see CLAUDE.md OpenCode section)
- **PM captures:** stdout/stderr, exit code
- **On success:** PM marks task done, logs output summary
- **On failure:** PM writes exit code + stderr to `error` field, evaluates retry
