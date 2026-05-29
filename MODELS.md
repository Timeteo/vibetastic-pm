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
| Tech Lead | `sonnet` | Pinned to Sonnet tier — token-heavy agent; Opus cost not justified for spec writing |

---

## OpenCode Tiers

The Tech Lead recommends a tier (`fast` / `standard` / `heavy`) in its output metadata.
The PM maps that tier to the model below. For Stage 2 Architect-selected tasks, the
Architect classifies the task and picks a tier directly.

The PM passes both `model` and `fallback_model` to dispatch.sh. If the primary exits
non-zero, dispatch.sh retries once with the fallback before returning failure to the PM.

| Tier | Model | Fallback | Confirmed | Use When |
|------|-------|----------|-----------|----------|
| `fast` | `openrouter/deepseek/deepseek-v4-flash` | `openrouter/google/gemini-3-flash-preview` | no | Simple bug fix, isolated change, clear root cause, no API surface changes |
| `standard` | `openrouter/google/gemini-3.5-flash` | `openrouter/deepseek/deepseek-v4-flash` | no | Multi-file feature, new patterns, moderate complexity |
| `heavy` | `openrouter/anthropic/claude-opus-4.8` | `openrouter/openai/gpt-5.5` | no | Complex architecture, new subsystems, large context, significant reasoning |

**SWE-bench Verified scores (May 2026):** fast primary 79%, standard primary 81%, heavy primary 88.6%

**Slug format note:** Anthropic model slugs on OpenRouter use dots for version numbers
(`claude-opus-4.8`, `claude-sonnet-4.6`). Hyphens cause "model not found" errors.

Mark `confirmed` after testing each tier end-to-end in a real session.

---

## Candidates

Models to evaluate for future tier assignments. Move to the table above once confirmed.

| Model | Potential tier | Notes |
|-------|---------------|-------|
| `openrouter/deepseek/deepseek-v4-pro` | standard/heavy | 80.6% SWE-bench, open-weight, strong reasoning |
| `openrouter/openai/gpt-5.4` | standard | 73.9% coding score, cheaper than 5.5 |
| `openrouter/qwen/qwen-2.5-coder-32b-instruct` | fast | Coding specialist, very cheap |

---

## Previous Tier Models (pre-May 2026)

Retained for reference and rollback. Tag `pre-fallback-models` points to the last commit using these.

| Tier | Model |
|------|-------|
| `fast` | `openrouter/google/gemini-2.5-flash` |
| `standard` | `openrouter/google/gemini-2.5-pro` |
| `heavy` | `openrouter/anthropic/claude-sonnet-4.6` |
