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
    ├── CLAUDE.md
    ├── SPEC.md
    ├── PLAN.md
    ├── RULES.md
    ├── TASK_LOG.md
    └── prompts/
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
- Use fallback: `anthropic/claude-opus-4-7` for architecture/review, `anthropic/claude-sonnet-4-6` for implementation/design

---

## Escalation Triggers

The PM halts and escalates to the user when:

| Trigger | Action |
|---|---|
| SPEC status is `draft` | Present SPEC for approval before continuing |
| Circular dependency detected in task graph | Report cycle, request PLAN correction |
| Task `failed` with no remaining retry budget | Report error, request human decision |
| OpenRouter unreachable for >2 attempts | Use fallback model, log warning |
| Agent returns malformed/unparseable output | Log, retry once, then escalate |

Retry budget default: **1 retry per task**. Can be overridden per-task by adding `retry_budget: <n>` to the task entry in PLAN.md.

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

### OpenCode (via PM shell invocation)
- **Invoked with:** `opencode run --model <model> --dir <target-project-path> --dangerously-skip-permissions "$(cat prompts/build-spec.md)"`
- **PM captures:** stdout/stderr, exit code
- **On success:** PM marks task done, logs output summary
- **On failure:** PM writes exit code + stderr to `error` field, evaluates retry
