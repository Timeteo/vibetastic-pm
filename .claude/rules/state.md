# State Management

## TASK_LOG Append Format

Every entry must follow this format exactly — append to the bottom of TASK_LOG.md:

```markdown
### <ISO8601> · <event_type>
```yaml
task_id: <id or null>
agent: <designer | architect | opencode | pm>
<relevant fields for this event type>
```
```

Include enough detail to reconstruct what happened without reading PLAN.md. On failures, include the full error message.

---

## Applying Results

After every agent return or OpenCode execution, before doing anything else:

1. Read current `PLAN.md` (do not use a cached version)
2. Apply the specific field updates for this task only
3. Write `PLAN.md`
4. Append to `TASK_LOG.md`

Never batch multiple task updates into one write. Each task result gets its own read-write cycle.

---

## Failure Handling

First distinguish **tier escalation** from a true failure. dispatch.sh **exit 20** means the
code runs but the verifier never passed within its attempt budget — this is *not* a failure:
follow Tier Escalation in `dispatch.md` (bump tier, log `tier_escalated`, re-dispatch, do **not**
touch `failure_count`). Only when a task is already at the `heavy` tier and still exits 20, or
opencode returns any other non-zero exit (infra/model failure), is it a true failure.

On a true task failure (agent error, malformed output, opencode infra failure, or heavy-tier
verifier exhaustion):

1. Increment `failure_count` on the task in PLAN.md
2. Write error message (or verifier tail) to the `error` field
3. Append `task_failed` to TASK_LOG

Then:

- **`failure_count == 1`**: Retry automatically. Append `task_retrying`. Re-dispatch.
- **`failure_count == 2`**: **Gate 2** — stop. Report both errors to user. Wait for decision:
  - *retry*: reset `failure_count` to 0, re-dispatch
  - *skip*: mark task `done` with note, continue (only if downstream tasks can proceed)
  - *abort*: halt all work, leave state as-is for manual inspection

Because dispatch.sh now self-corrects against the verifier and the PM escalates tiers
automatically, Gate 2 should fire rarely — only when even the `heavy` tier can't make the
verifier pass, or on repeated infra failures.

**Escalation log event** — `tier_escalated`, fields: `from_tier`, `to_tier`, `verifier_tail`,
`new_model`, `new_fallback_model`.

---

## Framework Updates

When the user says "pull framework updates":

1. Commit any dirty project files first:
   ```bash
   git add PLAN.md TASK_LOG.md SPEC.md prompts/
   git diff --staged --quiet || git commit -m "Checkpoint project state before framework update"
   ```
2. Pull the framework:
   ```bash
   git subtree pull --prefix framework framework main --squash
   ```
3. Report what changed.

Do not modify any files under `framework/` — it is a read-only subtree.

---

## Recovery Protocol

If invoked mid-project (context was reset, prior session ended):

1. Run the Startup Sequence in `lifecycle.md` — it will place you in the correct state.
2. Any task that was `in_progress` when context was lost → mark `failed`, `failure_count +1`, log `task_interrupted`. This prevents silent data loss from partial agent runs.
3. Re-evaluate from current PLAN.md. Do not assume prior agent output is valid unless the output file exists on disk.
4. If state is unclear, tell the user what you found and ask before acting.
