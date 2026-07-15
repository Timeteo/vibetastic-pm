# Design: Multi-backend builder dispatch (codex → claude → opencode)

Status: **implemented 2026-07-15** (approved by Tim) · probed against codex-cli 0.144.4

Implementation notes vs. this design:
- codex e2e-verified through dispatch.sh: fresh run, verify-fail → `exec resume` feedback →
  pass on attempt 2; telemetry (incl. reasoning_tokens) lands in cost.jsonl; exit 30 works.
- **`codex exec resume` gotcha (verified):** it runs in the *caller's* cwd, not the thread's
  original cwd, and accepts no `-C`/`-s` — dispatch.sh cd's into the target dir for resumes.
- claude backend e2e-verified 2026-07-15 (user-run — the orchestrator session's permission
  layer blocks spawning `claude -p --dangerously-skip-permissions` itself): verify-fail →
  `--resume` feedback → pass on attempt 2, 15s; telemetry in cost.jsonl (cost_usd null,
  subscription lane). All three backends confirmed.

## Why

Codex subscription (weekly-only limits) + Claude Pro (5-hour windows) are flat-rate lanes;
OpenRouter/opencode is metered. Invert the default: exhaust flat capacity first, spill to
metered. Default backend order `codex → claude → opencode`, selectable per project.

## Probe results (facts, not assumptions)

- **CLI**: `codex exec [OPTIONS] [PROMPT]`, non-interactive; `-C <dir>` sets working root;
  `--skip-git-repo-check`; sandbox via `-s read-only|workspace-write|danger-full-access`.
- **Session continuation** (verify feedback loop): `codex exec resume <THREAD_ID> "<prompt>"`.
  Thread id comes from the first JSONL event: `{"type":"thread.started","thread_id":"…"}`.
- **Telemetry**: `--json` emits JSONL; final event
  `{"type":"turn.completed","usage":{input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens}}`.
  Per-run token capture is mechanical. **No in-band weekly-quota data** — no `usage`
  subcommand, no rate-limit table in local state DB. Weekly cap must be tracked as a
  burn-proxy from tokens + reconciled manually against the ChatGPT UI.
- **Models available** (from `~/.codex/models_cache.json`, refetch via `codex debug models`):
  - `gpt-5.6-sol` — frontier, default effort *low*, efforts low→ultra, priority 1
  - `gpt-5.6-terra`, `gpt-5.6-luna` — frontier variants
  - `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini` — prior gen
- **Effort selection**: `-c model_reasoning_effort=<low|medium|high|xhigh|max|ultra>`.
- **Final output capture**: `-o/--output-last-message <file>`.

## Backend interface

Each backend implements three operations; dispatch.sh keeps its existing contract
(worktree isolation, verifier loop, exit codes 0/20/other):

| Op | codex | claude | opencode (today) |
|---|---|---|---|
| invoke | `codex exec --json -C <worktree> -s workspace-write -m <model> -c model_reasoning_effort=<e> "$(cat prompt)"` | `claude -p --output-format json` (subscription auth — see invariant) | current `opencode run` |
| continue w/ verifier feedback | `codex exec resume <thread_id> --json "<verifier tail>"` | `claude -p --resume <session_id>` | current session continue |
| usage record | parse `turn.completed.usage` → cost.jsonl | parse result JSON usage → cost.jsonl | current parsing |

Thread/session id is captured from the first invoke and held for the attempt loop.

## Tier matrix (replaces flat MODELS.md tiers)

MODELS.md becomes backend × tier → (model, effort/params):

The gpt-5.6 family is a size ladder (catalog descriptions): Sol = frontier, Terra =
balanced everyday, Luna = fast/affordable — a direct Opus/Sonnet/Haiku analog. Model size
is the primary quota lever, reasoning effort the secondary one.

| tier | codex | claude | opencode |
|---|---|---|---|
| fast | gpt-5.6-luna @ medium (its default) | sonnet | current fast row |
| standard | gpt-5.6-terra @ medium | sonnet (or opus-low) | current standard row |
| heavy | gpt-5.6-sol @ low→medium (sol's default is low; "highly capable at lower efforts") | opus | current heavy row |

Escalation within codex climbs **model first, effort second**: luna → terra → sol@low; if
sol@low exits 20, one effort bump to sol@medium counts as the heavy retry. high/xhigh/max/
ultra and prior-gen models (5.5/5.4/5.4-mini — dominated by the 5.6 ladder) are **not** on
the auto-ladder; sol@high+ is reachable only by explicit user decision at Gate 2.

## Escalation: two axes

1. **Within backend** (exit 20): climb fast→standard→heavy as today. On codex this is an
   effort bump, not a model swap — cheaper per rung.
2. **Across backends** (heavy exhausted, or backend unavailable/rate-limited): move to the
   next backend in the project's order, re-entering at `standard`. Log `backend_escalated`.
3. All backends exhausted → Gate 2 (unchanged: human + subscription Tech Lead re-spec).

Backend *unavailability* (weekly cap hit, auth failure, CLI missing) is detected at invoke
time and skips to the next backend without burning a failure_count.

## PROJECT.md additions

```yaml
builder_backends: [codex, claude, opencode]   # preference order, set at onboarding
```

Onboarding detects installed CLIs (`command -v codex claude opencode`) and offers the
detected set, default order as above.

## Telemetry & budget pacing

- Every dispatch appends to `logs/cost.jsonl` with new fields: `backend`, `model`, `effort`,
  `input_tokens`, `cached_input_tokens`, `output_tokens`, `reasoning_output_tokens`.
- `cost-report.sh` gains a **weekly burn view** for codex: tokens (esp. reasoning) per
  ISO-week, trend vs. prior weeks. It is a proxy, not authority — the report header says so
  and prompts periodic reconciliation against the ChatGPT usage UI.
- Soft guardrail: a configurable weekly token budget in PROJECT.md; when the proxy crosses
  it, dispatch warns and prefers the next backend (does not hard-stop).

## Hard invariants (carried forward)

- Claude backend runs on **subscription auth only** — dispatch guard: refuse to invoke the
  claude backend if `ANTHROPIC_API_KEY` is set in its env.
- Builders never touch the live checkout (`--worktree` unchanged); codex gets
  `-s workspace-write -C <worktree>`; push credentials stay stripped.
- VERIFY.md merge gate, Gate 1/Gate 2, plan-lint: unchanged.

## Implementation order (when approved)

1. dispatch.sh: extract backend functions (invoke/resume/usage-parse); codex backend first.
2. MODELS.md → matrix; PLAN.md task schema gains `backend`.
3. Escalation logic in rules (`dispatch.md`, `state.md`): backend axis + unavailability skip.
4. cost-report.sh weekly burn view + PROJECT.md budget field.
5. Onboarding/setup.sh backend detection.
6. e2e smoke drill (same as the 2026-07 hardening drill) per backend.
