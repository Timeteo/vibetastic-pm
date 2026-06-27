# Lifecycle

## Startup Sequence

After `eval "$(~/.ssh/gh-agent-token.sh)"`, check for `PROJECT.md`. If missing, run Onboarding. Otherwise read `PROJECT.md` for the code directory path, then:

1. Read `SPEC.md` — check `status`
2. Read `PLAN.md` — check stage and task statuses
3. Read `TASK_LOG.md` last 20 entries — understand what just happened

Branch on state:

| State | Action |
|---|---|
| `PROJECT.md` missing | Run Onboarding |
| SPEC doesn't exist | Begin SPEC Interview |
| SPEC `status: draft` | **Gate 1** — present spec for approval |
| SPEC `status: approved`, PLAN empty | Generate PLAN |
| PLAN has tasks `in_progress` | Mark them `failed` (`failure_count +1`), log `task_interrupted`, re-evaluate |
| PLAN has ready tasks, current stage `in_progress` | Resume dispatch loop |
| Awaiting Gate 3 (stage done, next stage `pending`) | Re-present Gate 3 prompt, wait for user |

---

## Onboarding

Run only when `PROJECT.md` does not exist. Note: `framework/setup.sh` does this automatically if run before the first session — check before asking.

Ask the user (one message):
- What is the project name?
- What is the absolute path to the code directory?
- What is the GitHub repo for issues and PRs? (format: `org/repo`)
- What single command verifies a change didn't break the project, runnable on *this* machine
  (sim-independent for iOS)? This becomes the per-task gate for the self-correction loop. If
  unknown, leave blank — the loop degrades to a single run with no auto-correction.

Write `PROJECT.md`:

```markdown
---
project: <project-name>
setup_at: <ISO8601>
---

## Project Paths

| Key | Path |
|-----|------|
| PM directory | `<absolute-path-to-this-pm-dir>` |
| Code directory | `<absolute-path-to-code-dir>` |
| Issue repo | `<org/repo>` |

## Verify command

<!-- Single-line command run in the code directory after each OpenCode task. Exit 0 = the
     task didn't break the project. Passed to dispatch.sh as the verifier; on failure the loop
     feeds its output back to the model and retries. Leave the code block empty to disable. -->

```
<verify-command-or-empty>
```

## Notes

<!-- Add any project-specific notes here for future PM sessions. -->
```

Check whether `.claude/settings.json` exists. If not, tell the user to run `bash framework/setup.sh <project-name> <code-dir>` from the PM directory and restart.

Append `onboarding_complete` to TASK_LOG. Then proceed to SPEC Interview.

---

## SPEC Interview

Goal: produce a complete, approved SPEC.md. Do not fabricate requirements — ask.

1. Tell the user you will ask a few questions to build the project spec.
2. Ask (can be batched in one message):
   - What problem does this project solve?
   - Who are the users?
   - What are the 3–5 most important things it must do?
   - What is explicitly out of scope?
   - Are there technical constraints (stack, platform, APIs, existing code)?
   - How will we know it's done and correct?
3. Write `SPEC.md`. Set `status: draft`, `created` and `updated` to current ISO8601.
4. Append `spec_drafted` to TASK_LOG.
5. **Gate 1**: Present spec. Wait for approval or revisions. Revise and re-present as needed.
6. On approval: set `status: approved`, write `approved_at`. Append `spec_approved` to TASK_LOG.

---

## Plan Generation

Only after SPEC `status: approved`.

1. Read `SPEC.md` in full.
2. Determine stages and tasks. Default structure:
   - **Stage 1 — Design**: one Designer task → `prompts/design-spec.md`
   - **Stage 2 — Architecture**: one Architect task → `prompts/build-spec.md`
   - **Stage 3 — Implementation**: one or more OpenCode tasks, each a single coherent invocation
3. Declare explicit `depends_on` for every task. Check for cycles before writing.
4. For each OpenCode task, set `tier` to the assigned starting tier (the suggested tier, or
   lower toward `fast` to bias for cost — see Tier Escalation in `dispatch.md`), then read the
   `model` and `fallback` columns from `framework/MODELS.md` for that tier and write them to the
   task as `model` and `fallback_model`. The PM re-resolves these on escalation.
5. Write `PLAN.md` with all tasks at `status: pending`, `failure_count: 0`.
5. Append `plan_generated` to TASK_LOG.
6. Present plan summary in plain language (not raw YAML) — stage names, task count, key dependencies.
7. **Gate 3 (Stage 1)**: *"Plan is ready. Stage 1 — Design is first. Type **proceed** to begin."*

---

## Lifecycle Gates

Three hard stops. Do not infer consent, do not proceed on timeout, do not self-approve.

| Gate | Trigger | What you say | What unlocks it |
|---|---|---|---|
| **Gate 1** | `SPEC.md status: draft` | Present spec, ask for "approved" or feedback | User types "approved" |
| **Gate 2** | Task `failure_count` reaches 2 | Show both errors, ask retry/skip/abort | User chooses an action |
| **Gate 3** | All tasks in Stage N are `done` | Summarize stage, ask for "proceed" | User types "proceed" |

### Gate 3 Detail — Stage Transition

When all tasks in Stage N reach `status: done`:

1. Set `stages[N].status: done` in PLAN.md.
2. Append `stage_complete` to TASK_LOG.
3. Present to user: what was accomplished, key output file paths, what Stage N+1 will do.
4. Say: *"Type **proceed** to begin Stage [N+1 name], or give me adjustments."*
5. Wait. Accept adjustments (update PLAN.md or SPEC.md as needed) or proceed.
6. On "proceed": set `stages[N+1].status: in_progress`, append `stage_transition`, enter dispatch loop.
