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

## Agent Roles

These agents are spawned via Claude Code's `Agent` tool, which accepts shorthand aliases
only (`opus`, `sonnet`, `haiku`) — not pinned version slugs. `opus` resolves dynamically
to Anthropic's current Opus release (Opus 4.8 as of May 2026).

| Role | Model | Notes |
|------|-------|-------|
| Designer | `opus` | Resolves to current Opus — creative and structural reasoning at planning stage |
| Architect | `opus` | Resolves to current Opus — architecture decisions require peak complex reasoning |
| Tech Lead | `opus` | Resolves to current Opus — strong spec reasoning |

---

## OpenCode Tiers

The Tech Lead recommends a tier (`fast` / `standard` / `heavy`) in its output metadata.
The PM maps that tier to the model below. For Stage 2 Architect-selected tasks, the
Architect classifies the task and picks a tier directly.

The PM passes `model` and `fallback_model` to dispatch.sh. If the primary exits non-zero,
dispatch.sh retries once with the fallback before returning failure to the PM.

**Escalation ladder:** the tiers below are ordered `fast` → `standard` → `heavy`. A task
starts at its assigned tier; when dispatch.sh's verifier loop is exhausted (exit 20) the PM
bumps to the next tier up and re-resolves `model`/`fallback` from this table. See Tier
Escalation in `.claude/rules/dispatch.md`.

| Tier | Model | Fallback | Confirmed | Use When |
|------|-------|----------|-----------|----------|
| `fast` | `openrouter/google/gemini-3-flash-preview` | `openrouter/anthropic/claude-sonnet-4.6` | no | Simple bug fix, isolated change, clear root cause, no API surface changes |
| `standard` | `openrouter/google/gemini-3.5-flash` | `openrouter/google/gemini-3-flash-preview` | no | Multi-file feature, new patterns, moderate complexity |
| `heavy` | `openrouter/anthropic/claude-opus-4.8` | `openrouter/z-ai/glm-5.2` | no | Complex architecture, new subsystems, large context, significant reasoning |

`deepseek-v4-flash` was removed from both tiers (it failed on every run). The reasoning-effort
(`--variant`) knob was also removed: it broke the gemini tiers in real tasks and opencode
provides no per-model validation for it.

**Slug format note:** Anthropic model slugs on OpenRouter use dots for version numbers
(`claude-opus-4.8`, `claude-sonnet-4.6`). Hyphens cause "model not found" errors.

Mark `confirmed` after testing each tier end-to-end in a real session.

---

## Pricing ($/Mtok)

Used by `cost-report.sh` to turn telemetry token counts into dollar estimates, and by the
PM/you when reasoning about tier choices. **Verify against current pricing before trusting
the dollar figures** — model prices change. Claude prices confirmed 2026-06-29.

| Model slug | $ in | $ out | Notes |
|------------|------|-------|-------|
| `opus` / `claude-opus-4.8` / `openrouter/anthropic/claude-opus-4.8` | 5.00 | 25.00 | Planning agents + heavy tier |
| `fable` / `claude-fable-5` | 10.00 | 50.00 | Not used by a role today |
| `sonnet` / `claude-sonnet-4.6` / `openrouter/anthropic/claude-sonnet-4.6` | 3.00 | 15.00 | Recommended PM + Tech Lead default |
| `haiku` / `claude-haiku-4-5` | 1.00 | 5.00 | Commit subagent / mechanical steps |
| `openrouter/z-ai/glm-5.2` | 1.20 | 4.10 | Heavy-tier fallback contender |
| `openrouter/google/gemini-3-flash-preview` | ? | ? | fast tier — verify on OpenRouter |
| `openrouter/google/gemini-3.5-flash` | ? | ? | standard tier — verify on OpenRouter |

Aliases (`opus`/`sonnet`/`haiku`/`fable`) are what the Claude Code Agent tool accepts for the
planning roles; the `openrouter/...` slugs are what dispatch.sh records for OpenCode builds.
Rows share a price across the aliases that resolve to the same model.

---

## Candidates

Models to evaluate for future tier assignments. Move to the table above once confirmed.

| Model | Potential tier | Notes |
|-------|---------------|-------|
| `openrouter/deepseek/deepseek-v4-pro` | standard/heavy | 80.6% SWE-bench, open-weight, strong reasoning |
| `openrouter/openai/gpt-5.4` | standard | 73.9% coding score, cheaper than 5.5 |
| `openrouter/qwen/qwen-2.5-coder-32b-instruct` | fast | Coding specialist, very cheap |
| `openrouter/z-ai/glm-5.2` | heavy | 62.1 SWE-bench Pro (>GPT-5.5), 74.4% FrontierSWE (~Opus 4.8), 1M context, open-weight, $1.20/$4.10 — heavy-primary contender |

---

## Previous Tier Models (pre-May 2026)

Retained for reference and rollback. Tag `pre-fallback-models` points to the last commit using these.

| Tier | Model |
|------|-------|
| `fast` | `openrouter/google/gemini-2.5-flash` |
| `standard` | `openrouter/google/gemini-2.5-pro` |
| `heavy` | `openrouter/anthropic/claude-sonnet-4.6` |
