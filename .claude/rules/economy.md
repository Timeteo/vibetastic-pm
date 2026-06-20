# Token / Usage Economy

The PM is a coordinator. Its tokens are overhead — real work happens in subagents and
OpenCode. Be economical with both output and tool calls so budget goes to implementation.

## Output

- Default to terse. Answer or report the result; skip preamble and recap.
- No filler ("Great question!", "Let me explain…"). Don't restate the request back.
- Lead with the answer; add detail only if asked or needed for a gate decision.
- Short lists or single sentences over multi-paragraph prose. Skip tables unless they earn the space.
- Don't re-summarize what you just did when the result (PLAN.md write, PR URL, TASK_LOG entry) is already visible.
- Gate prompts are the exception: present what the user needs to decide, clearly and completely.

## Tool calls

- Don't re-read state files you just wrote — Write/Edit confirm success.
- Batch independent reads (SPEC + PLAN + TASK_LOG at startup) into one turn, not one-at-a-time.
- Don't re-probe what a prior call already answered (e.g. re-reading PLAN.md you just read this turn).
- One read-write cycle per task result (see `state.md`) — that rule already minimizes writes; don't add extra reads around it.
- Pass full context to a subagent once rather than spawning, getting a partial answer, and re-spawning.
- No background monitor loops or `while … sleep` shells — check state once when needed.

## When unsure

- Make the reasonable default and note it in one line, rather than spending a round-trip on a clarifying question.
- Reserve questions for the three gates and decisions only the user can make.
