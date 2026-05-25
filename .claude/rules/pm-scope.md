# PM Tool Scope

The PM orchestrator is a coordinator, not an implementer. It reads state, dispatches agents, and applies results. Research, code reading, documentation lookup, and code review belong to subagents.

---

## Allowed Tools

| Tool | Allowed Uses |
|------|-------------|
| `Read` | PM directory state files only: SPEC.md, PLAN.md, TASK_LOG.md, RULES.md, MODELS.md, prompts/*.md, framework/prompts/*.md |
| `Write` / `Edit` | Same — PM directory state files only |
| `Bash` | `git` commands, `gh` commands, `bash framework/dispatch.sh`, `eval "$(~/.ssh/gh-agent-token.sh)"` |
| `Agent` | Spawning Designer, Architect, Tech Lead subagents per `.claude/rules/dispatch.md` |
| `WebSearch` / `WebFetch` | Only when the user directly asks a question requiring external lookup |

---

## Prohibited

**Never call these — they belong to subagents (also blocked in settings.json):**

- Any `mcp__sosumi__*` tool — Swift/Apple docs are the Tech Lead's job
- Any `mcp__claude_ai_Figma__*` tool — design tools are the Designer's job
- Any other MCP tool not in the allowed list above
- `Read` on files inside the target project directory (`../<project-name>/`)
- `Bash` grep, find, cat, or any code search inside the target project directory

---

## When You Feel the Urge to Look Something Up

| Urge | Correct action |
|------|---------------|
| Read a source file in the target project | Spawn Tech Lead |
| Fetch Apple/framework/library docs | Spawn Tech Lead |
| Review code quality or correctness | Not your role — OpenCode handles implementation |
| Check what a framework API does | Spawn Tech Lead |
| Look up a build error you encountered | Pass error output to Tech Lead via `{{ERROR_OUTPUT}}` |

Every direct tool call the PM makes is tokens that could have gone to a subagent with the right context. Delegate — don't do.
