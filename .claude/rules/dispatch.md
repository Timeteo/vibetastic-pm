# Dispatch

## Task Dispatch Loop

```
loop:
  read PLAN.md
  ready = tasks where status == pending AND all depends_on tasks have status == done
  if no ready tasks:
    if all tasks done → project complete (report to user, stop)
    else → blocked state (investigate and report to user)
    break
  for each task in ready (parallel only if same stage and no inter-dependencies):
    dispatch task
    on return → apply result (see state.md)
  re-evaluate ready tasks
```

---

## Designer

Invoke at Stage 1, and again mid-project for any new UI work (new screen, new component, visual design decisions). Skip for bug fixes and non-UI changes.

Read `framework/prompts/designer.md`. Substitute:
- `{{SPEC_CONTENT}}` → full body of `SPEC.md`

For mid-project invocations, also prepend a brief description of the specific UI addition so the Designer scopes to the new work only.

Spawn a fresh Agent with the rendered prompt.

After return:
- **Stage 1:** Write output verbatim to `prompts/design-spec.md`
- **Mid-project:** Append as a new section; note the addition in TASK_LOG
- Append `agent_returned` + `task_completed` to TASK_LOG
- Update task in PLAN.md: `status: done`, `completed_at`

---

## Architect

Read `framework/prompts/architect.md`. Substitute:
- `{{SPEC_CONTENT}}` → full body of `SPEC.md`
- `{{DESIGN_SPEC_CONTENT}}` → full contents of `prompts/design-spec.md`
- `{{TARGET_PROJECT_PATH}}` → absolute path to `../<project-name>/`

Spawn a fresh Agent with the rendered prompt.

After return, parse on delimiter `<!-- ARCHITECT_RESULT_START -->`:
1. Everything **before** the delimiter → write to `prompts/build-spec.md`. **Written once, never appended to again.**
2. YAML block **after** the delimiter → extract `selected_tier`, read `framework/MODELS.md` to resolve the `model` and `fallback` columns for that tier, write to `tasks[n].model` and `tasks[n].fallback_model` in PLAN.md; log `model_fallback_used` if true.

Then: append `model_selected`, `agent_returned`, `task_completed` to TASK_LOG. Update task: `status: done`, `completed_at`.

Missing delimiter or malformed YAML → treat as parse failure (increments `failure_count`).

---

## Tech Lead

Invoke when new work is identified not already specced in `prompts/build-spec.md`: user-reported bugs, new requirements, Gate 2 fix-before-retry, follow-on work revealed by a completed task.

**Routing rule — always apply:**
- New screen, new UI component, or any feature with visual design decisions → **Designer first, then Tech Lead**
- Bug fix or non-UI change → **Tech Lead directly**

Do not create a PLAN.md task without first running Tech Lead (unless trivially covered by existing spec). Do not run Tech Lead on UI work without a Designer pass first.

Read `framework/prompts/tech-lead.md`. Substitute:
- `{{ISSUE_DESCRIPTION}}` → bug/requirement as described by the user (or PM's failure analysis)
- `{{BUILD_SPEC_CONTENT}}` → full contents of `prompts/build-spec.md`
- `{{PLAN_SUMMARY}}` → one line per task: id, title, status, notes
- `{{TARGET_PROJECT_PATH}}` → absolute path to `../<project-name>/`
- `{{ERROR_OUTPUT}}` → full stderr/stdout from a failed task, or "none"

Spawn a fresh Agent with the rendered prompt.

After return, parse on delimiter `<!-- TECH_LEAD_RESULT_START -->`:
1. Everything **before** the delimiter → write to `prompts/task-T0XX.md` using the assigned task id. Do not append to `prompts/build-spec.md`.
2. YAML block **after** the delimiter → create new task in PLAN.md:
   - `task_title` → `title`
   - `branch_name`, `issue_refs` → store in `notes`
   - `depends_on` → `depends_on`
   - `suggested_tier` → look up `model` and `fallback` columns in `framework/MODELS.md` for that tier; write to `model` and `fallback_model`
   - Assign next available task id
   - Set `status: pending`, `agent: opencode`, `failure_count: 0`

Then: append `tech_lead_returned` + `task_created` to TASK_LOG. New task enters the normal dispatch loop.

Missing delimiter or malformed YAML → treat as parse failure.

---

## OpenCode

Do not spawn an Agent. Execute via the dispatch wrapper.

**`framework/dispatch.sh` is read-only. Never modify it. Report issues to the user.**

OpenCode always receives a task-scoped file at `prompts/task-T0XX.md`:

- **Tech Lead tasks:** PM writes the file directly from Tech Lead output (before delimiter). Pass straight to dispatch.
- **Architect-generated tasks (Stage 3):** Extract the task section from `prompts/build-spec.md` with awk:

```bash
TASK_ID="<tasks[n].id>"
TASK_PROMPT="prompts/task-${TASK_ID}.md"

awk -v id="${TASK_ID}" '
BEGIN { mode = "preamble" }
/^## OpenCode Execution Notes/ { mode = "notes"; print; next }
/^## T[0-9]/ {
  if (mode == "preamble") { mode = "skip"; next }
  if (mode == "task") { exit }
  if ($0 ~ ("^## " id "( |$)")) { mode = "task"; print; next }
  mode = "skip"; next
}
mode == "preamble" || mode == "notes" || mode == "task" { print }
' prompts/build-spec.md > "${TASK_PROMPT}"
```

Look up `tasks[n].model` and `tasks[n].fallback_model` in PLAN.md, resolved from the task's
current `tier` (see Tier Escalation below). Read the `Verify command` from `PROJECT.md` — the
sim-independent command that proves a task didn't break the project (e.g. the Hometastic
generic/iOS build). If `PROJECT.md` has no `Verify command`, pass an empty verifier and the
loop degrades to the legacy single-run behavior.

Dispatch:

```bash
bash framework/dispatch.sh <tasks[n].model> ../<project-name>/ "${TASK_PROMPT}" "<tasks[n].fallback_model>" "<verify-cmd>" 3 2>&1
```

- 4th arg `fallback_model`: if empty, pass `""` so the verifier stays positionally correct.
- 5th arg `verify-cmd`: the single-line verify command from `PROJECT.md`. dispatch.sh runs it
  in the target dir after opencode writes files and, on failure, feeds the verifier output back
  into the same opencode session and retries — entirely in bash, costing no PM tokens.
- 6th arg: max verify attempts (default 3).

Capture exit code and full stdout/stderr. dispatch.sh writes the complete opencode + verifier
log to a per-run file under `logs/` and prints its path to stderr; on any non-zero exit it
echoes the last 40 lines so a failure is never silent.

**Branch on dispatch.sh exit code:**

| Exit | Meaning | PM action |
|------|---------|-----------|
| `0` | Ran and (if a verifier was set) it passed | Proceed to the staged-change check, then PR Opening |
| `20` | Code runs but the verifier never passed within the attempt budget | **Tier escalation** (below) — not a `failure_count` event |
| other non-0 | opencode infra/model failure (even via fallback) | Task failure — see `state.md` (`failure_count +1`) |

**Exit 0 — staged-change check before opening PR:**

```bash
git -C ../<project-name>/ diff --cached --quiet
git -C ../<project-name>/ status --short
```

- Staged uncommitted changes → spawn subagent (`anthropic/claude-sonnet-4-6`) to commit with appropriate message, then proceed to PR Opening
- Clean working tree with commits → proceed to PR Opening
- Nothing committed at all (no new commits vs. branch base) → treat as task failure, do not open PR

---

## Tier Escalation

The cost lever: start a task at the cheapest reasonable tier and climb only when the verifier
proves the model couldn't do the job. This finds the lowest tier capable of completing each
task without you in the loop.

**Ladder (from `framework/MODELS.md`):** `fast` → `standard` → `heavy`.

- A task's **starting tier** is the Tech Lead / Architect `suggested_tier`. To bias harder for
  cost savings, lower starting tiers toward `fast`; escalation is the safety net either way.
- On dispatch.sh **exit 20** (verifier exhausted):
  1. If the task's current `tier` is below `heavy`: bump `tier` to the next rung, re-resolve
     `model` + `fallback_model` from `framework/MODELS.md`, append `tier_escalated` to TASK_LOG
     (record from→to tier and the verifier tail), and **re-dispatch**. Do **not** increment
     `failure_count` — escalation is expected, not a failure.
  2. If the task is already at `heavy`: this is a real failure. Increment `failure_count`, write
     the verifier output to `error`, and follow `state.md` Failure Handling (which leads to
     Gate 2 only after the heavy tier also can't pass verification).
- Cap escalations at one pass up the ladder per task (fast→standard→heavy). Re-dispatch at the
  same tier is not retried automatically except via the normal `failure_count` path.

---

## PR Opening

After successful OpenCode exit, **you (the PM) run `gh pr create`**. OpenCode does not open PRs.

Read `issue_repo` from `PROJECT.md` — the GitHub repo (`org/repo`) for all PRs and issues.

```bash
gh pr create \
  --repo <issue_repo> \
  --title "<task title>" \
  --body "$(cat <<'EOF'
## Summary
<1-3 bullet points from task notes and build spec>

Closes #<issue number from task notes>

## Test plan
<bulleted checklist from build spec acceptance criteria>
EOF
)" \
  --base develop
```

- PR title from `tasks[n].title` in PLAN.md
- Issue number from `tasks[n].notes`
- Summary and test plan from the relevant section of `prompts/build-spec.md`

After PR created: append `pr_opened` (with PR URL) to TASK_LOG, mark task `done`.

If `gh pr create` fails: log the error, mark task `done` anyway — do not let a PR failure block task completion.
