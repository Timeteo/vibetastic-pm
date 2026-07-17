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
2. YAML block **after** the delimiter → extract `selected_tier`, read `framework/MODELS.md` to resolve the `model` and `fallback` columns for that tier, write to `tasks[n].model` and `tasks[n].fallback_model` in PLAN.md; log `model_fallback_used` if true. Also extract `security` and write it to `tasks[n].security` (default `false`); for a multi-task build spec, apply the per-task flag noted in each task section.

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
   - `security` → write to `security` on the task (default `false` if absent). A `security: true` task forces the review rung up at merge time (Sonnet-minimum first pass, mandatory Opus adjudication — see `framework/VERIFY.md`).
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
current `tier` **and current `backend`** (see Backend & Tier Escalation below). The backend
is the first entry of `builder_backends` in `PROJECT.md` (default `codex`) unless the task
has already cross-backend-escalated; resolve the tier→model mapping from that backend's
column in `framework/MODELS.md` (codex slugs may carry `@<effort>`; codex/claude backends
have no fallback model — pass `""`). Read the `Verify command` from `PROJECT.md` — the
sim-independent command that proves a task didn't break the project (e.g. the Hometastic
generic/iOS build). If `PROJECT.md` has no `Verify command`, pass an empty verifier and the
loop degrades to the legacy single-run behavior.

Dispatch:

```bash
bash framework/dispatch.sh --worktree "<branch>" <tasks[n].model> ../<project-name>/ "${TASK_PROMPT}" "<tasks[n].fallback_model>" "<verify-cmd>" 3 "<tasks[n].tier>" 2>&1
```

- `--worktree <branch>`: **always pass it for build tasks.** The builder runs in an isolated
  git worktree (`../<project-name>-worktrees/task-T0XX/`) on `<branch>`, never in the live
  checkout — the human's uncommitted work is untouchable and parallel dispatches can't
  collide. `<branch>` is the task's `branch_name` from its notes (Tech Lead tasks), or
  `task/<task-id>` if the task has none. dispatch.sh creates the branch from current HEAD if
  it doesn't exist, reuses the worktree on a re-dispatch (tier escalation) — including when
  the branch is already checked out under a *different* prompt name, so fixup dispatches onto
  an open PR branch reuse the existing worktree instead of failing — and prints the
  path to stderr as `[dispatch] worktree: <path>`. Worktree builders run with gh
  unauthenticated and the worktree's `remote.origin.pushurl` poisoned (per-worktree config),
  so they cannot push or open PRs — that stays the PM's job. Push the branch from the **live
  checkout** (`git -C ../<project-name>/ push origin <branch>`) before `gh pr create`, or
  first `git -C <worktree> config --worktree --unset remote.origin.pushurl`. Also: a builder
  that exits non-zero after self-committing completed work (new commits, clean tree) is
  salvaged — dispatch.sh skips the fallback and sends the committed state to the verifier.
  All other post-dispatch steps (staged-change check, commit) run **in that worktree path**,
  not the live checkout; after the PR is opened, remove it:
  `git -C ../<project-name>/ worktree remove <path>`. Read-only
  review/diagnosis dispatches may target either the worktree (to review its diff) or the
  live checkout, and don't need `--worktree` themselves.

- 4th arg `fallback_model`: if empty, pass `""` so the verifier stays positionally correct.
- 5th arg `verify-cmd`: the single-line verify command from `PROJECT.md`. dispatch.sh runs it
  in the target dir after opencode writes files and, on failure, feeds the verifier output back
  into the same opencode session and retries — entirely in bash, costing no PM tokens.
- 6th arg: max verify attempts (default 3).
- 7th arg `tier`: the task's current tier (`fast`/`standard`/`heavy`). Recorded in
  `logs/cost.jsonl` for cost telemetry only — it does not change dispatch behavior. Also append
  a `cost_event` to TASK_LOG before dispatching (see `state.md` → Cost telemetry).

Capture exit code and full stdout/stderr. dispatch.sh writes the complete opencode + verifier
log to a per-run file under `logs/` and prints its path to stderr; on any non-zero exit it
echoes the last 40 lines so a failure is never silent.

**Branch on dispatch.sh exit code:**

| Exit | Meaning | PM action |
|------|---------|-----------|
| `0` | Ran and (if a verifier was set) it passed | Proceed to the staged-change check, then PR Opening |
| `20` | Code runs but the verifier never passed within the attempt budget | **Tier escalation** (below) — not a `failure_count` event |
| `30` | Backend unavailable (CLI missing/unauthenticated, or quota exhausted) | **Backend skip** — re-dispatch same tier on the next backend in `builder_backends`; log `backend_skipped`; not a `failure_count` event |
| other non-0 | builder infra/model failure (even via fallback) | Task failure — see `state.md` (`failure_count +1`) |

**Exit 0 — staged-change check before opening PR** (run in the worktree path dispatch.sh
printed, not the live checkout):

```bash
git -C <worktree-path> diff --cached --quiet
git -C <worktree-path> status --short
```

- Staged uncommitted changes → spawn a `haiku` subagent to commit with an appropriate message (mechanical — no reasoning needed), then proceed to PR Opening
- Clean working tree with commits → proceed to PR Opening
- Nothing committed at all (no new commits vs. branch base) → treat as task failure, do not open PR

---

## Backend & Tier Escalation (two axes)

The cost lever: start on the primary flat-rate backend at the cheapest reasonable tier and
climb only when the verifier proves the model couldn't do the job. **Flat-rate capacity is
exhausted before metered tokens** — that is why `builder_backends` defaults to
`codex → claude → opencode` (see `framework/MODELS.md` → Builder Backends).

**Axis 1 — tier, within the current backend.** Ladder: `fast` → `standard` → `heavy`.

- A task's **starting tier** is the Tech Lead / Architect `suggested_tier`; bias toward
  `fast` — escalation is the safety net.
- On dispatch.sh **exit 20** below `heavy`: bump `tier`, re-resolve `model` (+`fallback_model`,
  opencode only) from the current backend's column in `framework/MODELS.md`, append
  `tier_escalated` (from→to tier, verifier tail), re-dispatch. No `failure_count` change.
- On codex, tier rungs are model-size steps (luna → terra → sol@low); exit 20 at `heavy`
  gets one effort bump (sol@low → sol@medium), then one **burn-gated** bump
  (sol@medium → sol@high) before the backend counts as exhausted. The @high bump fires only
  if the current ISO-week burn proxy in `logs/cost.jsonl` is **below**
  `codex_weekly_burn_threshold` (see `framework/MODELS.md` § Codex tier column); at/above it,
  skip @high and `backend_escalated` to the claude backend immediately. Log the skip reason
  in the escalation event. **Any `sol@high` dispatch must record the consulted burn-proxy
  reading in its `cost_event` (`burn_proxy:` — see `state.md`); an `@high` dispatch with no
  burn figure logged is an auditable violation.** Efforts above high are never
  auto-dispatched (weekly-cliff guard — Gate 2 only).

**Axis 2 — backend, when the current backend's ladder is exhausted or unavailable.**

- Exit 20 at `heavy` (post effort-bumps on codex — sol@medium, then burn-gated sol@high):
  move to the **next backend** in `builder_backends`, re-enter at `standard`, append
  `backend_escalated` (from→to backend, verifier tail). No `failure_count` change.
- Exit **30** (backend unavailable — CLI missing, auth failure, quota exhausted): skip to
  the next backend at the **same tier**, append `backend_skipped`. No `failure_count` change.
- All backends exhausted: increment `failure_count`, write the verifier output to `error`,
  and follow `state.md` Failure Handling → Gate 2: the Tech Lead (subscription Sonnet,
  escalating to subscription Opus for genuinely architectural cases) re-specs or fixes the
  task on the Agent tool, then it re-enters at the first backend, tier `fast`. Anthropic
  API billing never enters the picture: the claude *backend* runs on subscription auth
  (dispatch.sh strips `ANTHROPIC_API_KEY`), and API Opus is never a rung.

Cap: one pass up each axis per task. Re-dispatch at the same tier+backend is not retried
automatically except via the normal `failure_count` path.

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

After PR created: append `pr_opened` (with PR URL) to TASK_LOG, mark task `done`, and
remove the task's worktree (`git -C ../<project-name>/ worktree remove <worktree-path>`;
add `--force` only if you've confirmed nothing in it is still needed).

If `gh pr create` fails: log the error, mark task `done` anyway — do not let a PR failure block task completion.
