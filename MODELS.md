---
version: "1.0"
---

# Model Inventory

Curated model slugs for each PM framework role. All models are referenced via OpenRouter.
Update this file to change which models the framework uses. Mark `confirmed` only after
testing the model end-to-end in a real session.

**This is the single source of truth for model selection. Do not hardcode model slugs
anywhere else in the framework.**

---

## Orchestrator (the partner session — A1 model)

There is no standalone PM session (retired 2026-06-29). The orchestrator is the partner
session in the project's `<project>-run` workspace, typically on **Opus** because it also
serves as the human's thinking partner. That is only affordable because the orchestrator
**delegates**: spec-writing to the Tech Lead tier, first-pass diff review to the Reviewer
(cheap, read-only), open-ended diagnosis to read-only `standard`/`heavy` dispatches. The
measured failure mode is the partner absorbing those roles itself at Opus rates —
RULES.md operating lessons 2–3 exist because that burned a session budget in one day.

## Agent Roles

These agents are spawned via Claude Code's `Agent` tool, which accepts shorthand aliases
only (`opus`, `sonnet`, `haiku`, `fable`) — not pinned version slugs. `opus` resolves dynamically
to Anthropic's current Opus release (Opus 4.8 as of 2026-06).

Balanced cost bias (2026-06-29): the reasoning roles default to **Sonnet** and only the
Architect holds **Opus**, where peak reasoning earns its cost. Tier escalation (and re-speccing
a heavy-tier task that still fails Gate 2 on Opus) is the safety net. Telemetry
(`cost-report.sh`) drives further tuning — refine these once real data is collected.

| Role | Model | Escalate to | Notes |
|------|-------|-------------|-------|
| Designer | `sonnet` | `opus` | UI/structural reasoning; Sonnet handles most. (In Hometastic, design is frozen — Designer should not run at all.) |
| Architect | `opus` | — | Stage-2 subsystem design needs peak reasoning; invoked rarely, so low frequency = low cost |
| Tech Lead | `sonnet` | `opus` | Most frequently spawned reasoning role; a spec is cheap to redo, so default cheap. Escalate to Opus only for architecturally heavy work |
| Reviewer | opencode `standard` tier (or `sonnet` subagent) | orchestrator adjudicates | First-pass diff review runs cheap and read-only (`dispatch.sh --read-only` + `prompts/reviewer.md`); Opus reads only the verdict. See VERIFY.md |

To escalate a role for one spawn (e.g. a genuinely architectural Tech Lead pass), use the
`Escalate to` model and log it in the `cost_event` (see `.claude/rules/state.md`).

---

## OpenCode Tiers

The Tech Lead recommends a tier (`fast` / `standard` / `heavy`) in its output metadata.
The PM maps that tier to the model below. For Stage 2 Architect-selected tasks, the
Architect classifies the task and picks a tier directly.

The PM passes `model` and `fallback_model` to dispatch.sh. If the primary exits non-zero,
dispatch.sh retries once with the fallback before returning failure to the PM.

**Hard invariant — Anthropic runs on the subscription only.** opencode is a separate process
and cannot use Claude subscription; it can only authenticate to OpenRouter (paid API).
So **no `openrouter/anthropic/*` model may ever appear in these tiers or their fallbacks** —
routing Anthropic through the API bills it at full rate, the exact opposite of "offload cheap
work." The opencode tiers are **non-Anthropic only**. The Anthropic "big gun" lives exclusively
on the subscription side (the Architect / Tech Lead / PM via the Claude Code Agent tool). When
the non-Anthropic ladder is exhausted, control returns there (Gate 2 re-spec on subscription
Opus) — it never falls through to API Opus.

**Escalation ladder:** the tiers below are ordered `fast` → `standard` → `heavy`. A task
starts at its assigned tier; when dispatch.sh's verifier loop is exhausted (exit 20) the PM
bumps to the next tier up and re-resolves `model`/`fallback` from this table. Each rung is a
**different model family** so an escalation is a genuinely fresh attempt, not the same model
retried. Above `heavy`, escalation leaves the API lane entirely → subscription (see Tier
Escalation in `.claude/rules/dispatch.md`).

| Tier | Model | Fallback | Confirmed | Use When |
|------|-------|----------|-----------|----------|
| `fast` | `openrouter/qwen/qwen3-coder-flash` | `openrouter/deepseek/deepseek-v4-pro` | yes (e2e 2026-07-02) | Simple bug fix, isolated change, clear root cause, no API surface changes |
| `standard` | `openrouter/deepseek/deepseek-v4-pro` | `openrouter/z-ai/glm-5.2` | yes (e2e 2026-06-29) | Multi-file feature, new patterns, moderate complexity |
| `heavy` | `openrouter/z-ai/glm-5.2` | `openrouter/deepseek/deepseek-v4-pro` | yes (e2e 2026-06-29) | Complex architecture, new subsystems, large context, significant reasoning |

**`fast` re-anchored to a true cost rung (2026-07-02):** gemini-3-flash-preview was dropped —
it priced *above* deepseek-v4-pro on both sides ($0.50/$3.00 vs $0.43/$0.87), so its only
advantage was wall-clock latency, which Tim ruled immaterial. `qwen3-coder-flash`
($0.195/$0.975, 1M ctx) replaces it: coding-specialist, ~55% cheaper than deepseek on input,
and — decisive given the gemini-3.5-flash stall history — a **non-reasoning** model, so the
reasoning-stall failure mode can't occur. **E2e-confirmed 2026-07-02**: multi-file task
through dispatch.sh, verify passed attempt 1, 39s, $0.016 billed, no stall.

All three primaries have **1M context** (not "low-context flash" — verified on OpenRouter
2026-06-29) and were tested end-to-end through opencode (`opencode run` completed a multi-file
task, exit 0). `deepseek-v4-pro` is both the cheapest and strongest SWE-bench model here, so it
anchors `standard`; `glm-5.2` (different family, ~Opus-4.8 FrontierSWE) is the `heavy` last
non-Anthropic attempt before bouncing to subscription.

`deepseek-v4-flash` was removed earlier (it failed on every run). **`gemini-3.5-flash` was
removed as a primary (2026-06-29):** it is a reasoning model that, on large task prompts, spends
its whole token budget in `reasoning` and emits no content/tool-call — the root cause of the
hour-long opencode stall in `hometastic-pm/logs/task-T052-20260628-094058.log` (verify-exhaust →
needless escalation to the old API-Opus heavy tier). `reasoning:{effort:low}` fixes it via the
raw OpenRouter API but did not take through opencode's `provider.models[*].options` passthrough,
so the reasoning models are simply not used as primaries. The reasoning-effort (`--variant`)
knob was also removed earlier: it broke the gemini tiers and opencode provides no per-model
validation for it.

**Slug format note:** Anthropic model slugs on OpenRouter use dots for version numbers
(`claude-opus-4.8`, `claude-sonnet-4.6`). Hyphens cause "model not found" errors.

Mark `confirmed` after testing each tier end-to-end in a real session.

---

## Pricing ($/Mtok)

Used by `cost-report.sh` to turn telemetry token counts into dollar estimates, and by the
PM/you when reasoning about tier choices. **Verify against current pricing before trusting
the dollar figures** — model prices change. Claude prices confirmed 2026-06-29.

**Anthropic rows are subscription-side** (Agent tool) — the $ figures are list API rates shown
for relative reasoning only; under Anthropic plan that work is covered by the subscription, not
billed per-token. The `openrouter/...` rows are the **only** real per-token spend (the cheap
offload lane). Context/prices verified on OpenRouter 2026-06-29.

| Model slug | $ in | $ out | Ctx | Notes |
|------------|------|-------|-----|-------|
| `opus` / `claude-opus-4.8` | 5.00 | 25.00 | 1M | Subscription only (Architect; Gate-2 re-spec). **Never via API/opencode.** |
| `fable` / `claude-fable-5` | 10.00 | 50.00 | — | Not used by a role today |
| `sonnet` / `claude-sonnet-4.6` | 3.00 | 15.00 | 1M | Subscription only (PM + Tech Lead default) |
| `haiku` / `claude-haiku-4-5` | 1.00 | 5.00 | 200K | Subscription only (commit subagent / mechanical steps) |
| `openrouter/deepseek/deepseek-v4-pro` | 0.43 | 0.87 | 1M | **standard** primary; fast/heavy fallback — cheapest, top SWE-bench |
| `openrouter/z-ai/glm-5.2` | 0.95 | 3.00 | 1M | **heavy** primary; standard fallback (~Opus-4.8 FrontierSWE) |
| `openrouter/qwen/qwen3-coder-flash` | 0.195 | 0.975 | 1M | **fast** primary — non-reasoning coder specialist (e2e confirmed 2026-07-02) |
| `openrouter/google/gemini-3-flash-preview` | 0.50 | 3.00 | 1M | Dropped 2026-07-02 (priced above deepseek; latency-only advantage) |
| `openrouter/google/gemini-3.5-flash` | 1.50 | 9.00 | 1M | Dropped (reasoning-stall on big tasks); kept for reference |

Aliases (`opus`/`sonnet`/`haiku`/`fable`) are what the Claude Code Agent tool accepts for the
subscription-side planning roles; the `openrouter/...` slugs are what dispatch.sh records for
OpenCode builds. Rows share a price across the aliases that resolve to the same model.

---

## Candidates

Models to evaluate for future tier assignments. Move to the table above once confirmed.

| Model | Potential tier | Notes |
|-------|---------------|-------|
| `openrouter/openai/gpt-5.4` | standard | 73.9% coding score, cheaper than 5.5 — non-Anthropic alt if a tier needs swapping |
| `openrouter/qwen/qwen3.5-flash-02-23` | fast (budget floor) | $0.065/$0.26, 1M ctx — 3× cheaper than qwen3-coder-flash, but a **reasoning model** (the stall-risk class); only adopt after a stall-free e2e test |
| `openrouter/qwen/qwen3.7-plus` | standard | $0.32/$1.28, 1M ctx — newest Qwen general line; only marginally cheaper than deepseek, no reason to swap today |

(`qwen-2.5-coder-32b-instruct` removed 2026-07-02 — obsolete: $0.66/$1.00, 128K ctx; beaten
on every axis by the qwen3.x line.)

(`deepseek-v4-pro` and `glm-5.2` were promoted into the active tiers on 2026-06-29 — see OpenCode
Tiers. `glm-5.2` actual OpenRouter price is $0.95/$3.00, 1M ctx.)

---

## Previous Tier Models (pre-May 2026)

Retained for reference and rollback. Tag `pre-fallback-models` points to the last commit using these.

| Tier | Model |
|------|-------|
| `fast` | `openrouter/google/gemini-2.5-flash` |
| `standard` | `openrouter/google/gemini-2.5-pro` |
| `heavy` | `openrouter/anthropic/claude-sonnet-4.6` |
