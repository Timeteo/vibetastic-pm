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

These models are fixed per role and are not subject to tier selection.

| Role | Model | Confirmed | Notes |
|------|-------|-----------|-------|
| Designer | `anthropic/claude-opus-4-7` | yes | Creative and structural reasoning at planning stage |
| Architect | `anthropic/claude-opus-4-7` | yes | Architecture decisions require peak complex reasoning |
| Tech Lead | `anthropic/claude-sonnet-4-6` | yes | Code reading and spec writing |

---

## OpenCode Tiers

The Tech Lead recommends a tier (`fast` / `standard` / `heavy`) in its output metadata.
The PM maps that tier to the model below. For Stage 2 Architect-selected tasks, the
Architect classifies the task and picks a tier directly.

| Tier | Model | Confirmed | Use When |
|------|-------|-----------|----------|
| `fast` | `google/gemini-2.5-pro` | yes | Simple bug fix, isolated change, clear root cause, no API surface changes |
| `standard` | `google/gemini-2.5-pro` | yes | Multi-file feature, new patterns, moderate complexity |
| `heavy` | `anthropic/claude-sonnet-4-6` | yes | Complex architecture, new subsystems, large context, significant reasoning |

**Fallback** (if selected model unavailable): `google/gemini-2.5-pro`

Note: `fast` and `standard` intentionally map to the same model. The tier distinction is preserved so a cheaper model can be slotted into `fast` once confirmed (see Candidates). The Tech Lead's tier recommendation still matters — it signals task complexity even when the model is the same.

---

## Candidates

Models to evaluate for future tier assignments. Move to the table above once confirmed.

| Model | Potential tier | Notes |
|-------|---------------|-------|
| `google/gemini-2.5-flash` | fast | Removed — silent output truncation on large tasks |
| `openai/o4-mini` | heavy | Strong reasoning + coding |
| `deepseek/deepseek-r1` | heavy | Cost-effective reasoning |
| `qwen/qwen-2.5-coder-32b-instruct` | fast | Coding specialist, very cheap |
| `anthropic/claude-haiku-4-5-20251001` | fast | Fast and cheap, needs coding eval |
