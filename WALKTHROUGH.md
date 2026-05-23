# Walkthrough — Instantiating vibetastic-pm for a New Project

This guide walks through setting up and running the PM framework on a new project from first invocation to completed implementation.

---

## 1. Set Up the Instance

You need a target project directory (empty or existing) and a sibling `-pm/` directory containing the framework. The `-pm/` naming convention is defined in `RULES.md`.

### Recommended: git subtree (pulls future framework updates cleanly)

```bash
cd ~/dev/projects

# Target project (create or use existing)
mkdir my-app

# Create the pm directory as its own git repo
mkdir my-app-pm && cd my-app-pm && git init

# Pull vibetastic-pm framework files into a framework/ subdirectory
git subtree add --prefix framework \
  https://github.com/Timeteo/vibetastic-pm main --squash

# Symlink CLAUDE.md to the root so Claude Code auto-loads it
ln -s framework/CLAUDE.md CLAUDE.md
```

To pull framework updates later:
```bash
git subtree pull --prefix framework \
  https://github.com/Timeteo/vibetastic-pm main --squash
```

Project-specific files (`SPEC.md`, `PLAN.md`, `TASK_LOG.md`, `prompts/design-spec.md`, `prompts/build-spec.md`) live in the root alongside the `framework/` directory — they are not tracked by upstream.

### Simple alternative: cp -r (no upstream tracking)

```bash
cd ~/dev/projects
mkdir my-app
cp -r vibetastic-pm/ my-app-pm/
cd my-app-pm/
```

This works but framework improvements must be applied manually to each project instance.

---

## 2. Prerequisites

**OpenRouter API key** — the Architect agent queries OpenRouter for model selection. Set it in your shell environment before starting:

```bash
export OPENROUTER_API_KEY=sk-or-your-key-here
```

To persist it across sessions, add that line to your shell profile (`~/.zshrc`, `~/.bashrc`, etc.) and reload:

```bash
source ~/.zshrc
```

Claude Code inherits your shell environment at launch, so the Architect will see `$OPENROUTER_API_KEY` automatically when it runs.

**OpenCode** — must be installed and on your `$PATH`. The PM shells out to it directly for Stage 3 implementation tasks.

---

## 3. Start the PM

```bash
claude
```

Claude Code reads `CLAUDE.md` automatically. The PM runs its Startup Sequence — reads `SPEC.md` (status: `draft`, body empty) and begins the SPEC interview.

---

## 4. SPEC Interview

The PM asks all questions in one message:

> I'll ask a few questions to build the project spec before we start.
>
> 1. What problem does this project solve?
> 2. Who are the users?
> 3. What are the 3–5 most important things it must do?
> 4. What is explicitly out of scope?
> 5. Any technical constraints — stack, platform, existing APIs?
> 6. How will we know it's done and correct?

Answer them. The PM writes `SPEC.md`, sets `status: draft`, and appends `spec_drafted` to `TASK_LOG.md`.

---

## 5. Gate 1 — SPEC Approval

The PM presents the full spec in chat:

> Here's the project spec I've written. Please review it carefully.
>
> ---
> **Project:** my-app
> **Problem Statement:** ...
> **Goals:** ...
> *(full spec body)*
> ---
>
> Type **approved** to unlock the build plan, or give me feedback to revise it.

**Hard stop.** The PM does nothing until you respond.

- Give feedback → PM edits `SPEC.md`, re-presents, repeats
- Type `approved` → PM sets `status: approved`, writes `approved_at`, appends `spec_approved` to TASK_LOG, generates the plan

After approval, `SPEC.md` frontmatter looks like:

```yaml
project: my-app
status: approved
version: "1.0"
created: 2026-05-22T10:00:00Z
updated: 2026-05-22T10:14:00Z
approved_at: 2026-05-22T10:14:00Z
```

---

## 6. Plan Generation + Gate 3 (Stage 1)

The PM generates `PLAN.md` from the approved spec and presents a plain-language summary:

> Plan is ready. Here's what I'll build:
>
> **Stage 1 — Design** (1 task)
> T001: Designer agent produces `prompts/design-spec.md`
>
> **Stage 2 — Architecture** (1 task)
> T002: Architect agent produces `prompts/build-spec.md` and selects model
>
> **Stage 3 — Implementation** (2 tasks)
> T003: Set up project structure and auth
> T004: Build main feature screens
>
> Type **proceed** to begin Stage 1.

**Gate 3 fires immediately** — even before the first stage. The PM will not dispatch any task until you confirm.

---

## 7. Stage 1 Runs Autonomously

Type `proceed`. The PM:

1. Sets `stages[1].status: in_progress` in PLAN.md
2. Appends `stage_transition` to TASK_LOG
3. Reads `framework/prompts/designer.md`, substitutes `{{SPEC_CONTENT}}`
4. Spawns Designer agent
5. Receives design spec back
6. Writes output to `prompts/design-spec.md`
7. Updates T001 in PLAN.md: `status: done`, `completed_at`
8. Appends `agent_returned` + `task_completed` to TASK_LOG

No user input required during any of that. When T001 is done, Gate 3 fires for Stage 2:

> Stage 1 — Design is complete.
>
> **Output:** `prompts/design-spec.md`
> Covers: 3 user flows, 7 screens, 12 components, interaction model.
>
> Ready to begin Stage 2 — Architecture. Type **proceed** to continue, or review `prompts/design-spec.md` first and give me adjustments.

---

## 8. Stage 2 → Stage 3

Same pattern. Type `proceed`. The Architect agent runs, queries OpenRouter, writes `prompts/build-spec.md`, and returns a structured result block. The PM parses the `<!-- ARCHITECT_RESULT_START -->` delimiter, extracts `selected_model`, and writes it to the relevant tasks in PLAN.md. Gate 3 fires again before Stage 3.

At this point the state files look like:

```
my-app-pm/
├── CLAUDE.md           symlink → framework/CLAUDE.md
├── SPEC.md             status: approved
├── PLAN.md             T001 done, T002 done, T003/T004 pending
├── TASK_LOG.md         6+ entries
├── prompts/
│   ├── design-spec.md  ← Designer output
│   └── build-spec.md   ← Architect output
└── framework/          ← git subtree (vibetastic-pm); read-only
    ├── CLAUDE.md
    ├── RULES.md
    ├── WALKTHROUGH.md
    ├── dispatch.sh
    └── prompts/
        ├── designer.md
        ├── architect.md
        └── tech-lead.md
```

---

## 9. Stage 3 — OpenCode Executes

Type `proceed`. The PM runs each Implementation task via shell — no Agent spawn, direct execution. Before dispatching, it extracts a task-scoped prompt file containing only the preamble, execution notes, and the current task section (see CLAUDE.md for the awk command). Then:

```bash
bash framework/dispatch.sh <model> ../my-app/ prompts/task-T00X.md 2>&1
```

The model is the Architect's selection (written to `tasks[n].model` in PLAN.md). It will never be Opus — see the Model Tier Policy in `RULES.md`. Opus is reserved for the Designer and Architect planning agents only; OpenCode runs on the best available Sonnet-class or equivalent coding model.

PM captures exit code and output. On success: task marked `done`. Tasks with no inter-dependencies within a stage may run in parallel at the PM's discretion.

---

## 10. Mid-Project Work — Tech Lead

The Architect's build-spec covers the work known at project start. It will not cover every bug, regression, or new requirement that emerges during Stage 3. When new work appears, the PM invokes the Tech Lead agent before creating any new OpenCode task.

**What triggers the Tech Lead:**
- You report a bug or new requirement in chat
- Gate 2 fires and the fix needs speccing before retry
- A completed task reveals follow-on work not covered by the existing spec

**What the Tech Lead does:**
1. Reads relevant source files in the target project to understand current state
2. Fetches Apple/framework docs via Sosumi MCP if the issue involves Apple APIs
3. Writes a precise, self-contained task spec (root cause, files to change, implementation steps, commit plan)
4. Returns structured metadata: task title, branch, issue refs, suggested OpenCode model

**What you see in chat:**

> New work identified: OAuth redirect URI rejected by HA server.
> Running Tech Lead to spec the fix before dispatch.

The PM appends the Tech Lead's spec to `prompts/build-spec.md`, creates the new task in `PLAN.md`, and dispatches it to OpenCode — all without requiring your input unless a gate fires.

**Model:** Tech Lead runs on Sonnet by default. It suggests the OpenCode model in its returned metadata based on task complexity — simple bugs get Gemini Flash, complex architectural changes get Sonnet.

---

## 11. Gate 2 — Task Double-Failure

Gate 2 does not appear on the happy path. It fires only when a task fails twice.

If OpenCode exits non-zero on T003:

- PM increments `failure_count` to 1, writes the error to PLAN.md, appends `task_failed`
- PM retries automatically (first failure), appends `task_retrying`
- If it fails again: `failure_count` hits 2, **Gate 2 fires**:

> Task T003 — "Set up project structure and auth" has failed twice.
>
> **Failure 1:** `exit 1 — cannot find module 'vite'`
> **Failure 2:** `exit 1 — cannot find module 'vite'`
>
> How would you like to proceed?
> - **retry** — try again (resets failure count)
> - **skip** — mark done and continue (only if downstream tasks can proceed)
> - **abort** — halt everything, leave state for manual inspection

---

## 11. Recovery After a Crash

If Claude Code exits mid-run (context reset, terminal closed, process killed), restart from the same directory:

```bash
cd my-app-pm/
claude
```

The PM reads current state on startup. Any task that was `in_progress` when context was lost is marked `failed` (`failure_count +1`) and logged as `task_interrupted`. The PM re-evaluates from current PLAN.md state:

> Resuming project my-app.
> T003 was interrupted — marked failed (failure_count: 1). Retrying automatically.

One interrupted run counts as one failure. If the task was already at `failure_count: 1` before the crash, the interrupted re-run pushes it to 2 and Gate 2 fires.

---

## Gate Summary

| Gate | Fires when | Unlocked by |
|---|---|---|
| **Gate 1** | SPEC status is `draft` | User types `approved` |
| **Gate 2** | Task `failure_count` reaches 2 | User chooses retry / skip / abort |
| **Gate 3** | All tasks in a stage reach `done` | User types `proceed` |

Gate numbers refer to gate *type*, not the order they appear in a session. On a clean run, the sequence is: Gate 1 → Gate 3 → Gate 3 → Gate 3. Gate 2 only appears when something breaks.

---

## Full Flow at a Glance

```
claude
  ↓ SPEC interview (PM asks, you answer)
  ↓ Gate 1 — type "approved"
  ↓ Plan generated
  ↓ Gate 3 — type "proceed"         ← Stage 1: Design
  ↓ Designer (Opus) runs autonomously
  ↓ Gate 3 — type "proceed"         ← Stage 2: Architecture
  ↓ Architect (Opus) runs autonomously, selects OpenCode model
  ↓ Gate 3 — type "proceed"         ← Stage 3: Implementation
  ↓ OpenCode (Gemini Flash) runs autonomously
  ↓ [new bug or requirement]
  ↓ Tech Lead (Sonnet) specs the fix autonomously
  ↓ OpenCode runs autonomously
  ↓ Project complete
```

Three `proceed`s and one `approved`. Everything else is autonomous.

**Agent roster:**

| Agent | Model | Runs | Job |
|---|---|---|---|
| Designer | Opus | Once | Design spec |
| Architect | Opus | Once | Build spec + OpenCode model selection |
| Tech Lead | Sonnet | Per new mid-project task | Bug/feature → task spec |
| OpenCode | Gemini 2.5 Flash (or Architect selection) | Per implementation task | Write code |
