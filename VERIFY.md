---
framework: claude-pm
version: "1.0"
---

# VERIFY — the risk-tiered merge gate

Why this exists: the old gate (`build + unit tests`) passed code with real integration
bugs. hometastic #72 shipped with all 57 tests green because the mocked seam bypassed the
production JSON decode path; #73 shipped because a single lucky screenshot "verified" a
launch-timing race. **Green must mean "works," proportional to risk.** This file defines
what "verified" means per tier. The orchestrator (partner) enforces it as a merge gate —
branch protection alone does not.

---

## Risk tiers

The orchestrator assigns a tier at spec time = the **highest** tier any changed file or
behavior touches (bias up when unsure). Record it as `verify_tier:` on the task in PLAN.md
and state it in the task prompt.

| Tier | Applies to | Gate (cumulative) |
|---|---|---|
| **R0 — pure logic** | internal refactor, algorithms; no external I/O, no UI, no (de)serialization boundary | build + unit tests + **diff review** (see below) |
| **R1 — integration boundary** | JSON decode/encode, HTTP, service calls, persistence, config parsing | R0 **+ real-path integration test**: a representative **real payload** through the **production code path** |
| **R2 — UI / user-visible data path** | views, tiles, anything whose correctness is visual or depends on live data rendering | R1 **+ "run the app and look"**: build, launch, drive to the state, screenshot, orchestrator inspects |

Mechanical checks (build, tests, R1 fixtures) run inside `dispatch.sh`'s verify loop via
the verify-cmd argument. R2 app-runs and the diff review are orchestrator steps after the
dispatch returns green.

---

## Diff review — cheap-first, Opus adjudicates (all tiers)

Every builder diff gets read for **intent and integration traps** — "does it do the thing,
match the spec, mock the right layer, stay in scope" — before merge. Compilation and tests
do not check intent; this rung is what catches the #72 class of bug.

Cost structure (this is deliberate — see RULES.md operating lesson 3):

1. **First pass runs on a cheap tier.** Dispatch a **read-only** review (`dispatch.sh
   --read-only` with `prompts/reviewer.md` rendered for the task) on the `standard` tier,
   or spawn a Sonnet subagent. The reviewer returns a verdict + findings, changes nothing.
2. **Opus adjudicates only.** The orchestrator (already Opus in the partner model) reads
   the reviewer's findings against the spec and decides merge / reject / re-dispatch. It
   does not perform the line-by-line first pass itself — that is Tech-Lead-tier work and
   burning Opus on it was the single biggest measured cost sink.

A diff merged without this rung is a gate violation regardless of tier.

---

## R1 rules — real payloads through the real path

- **Never mock the boundary under test.** Mocks above the boundary (to isolate logic that
  *consumes* it) are fine; the decode/transport/persistence code itself must run for real.
- **No replicas.** A test that rebuilds its own decoder/client "equivalent to" production
  stays green when production drifts (the #74 near-miss). The test must call the
  production function. If the dependency isn't injectable (e.g. code hard-wired to
  `URLSession.shared`), stub the transport underneath it (`URLProtocol` stub) and feed the
  fixture through the real call.
- **Fixtures are captured, not invented.** Pull representative payloads from the live
  system (e.g. via the project's MCP integration or a curl against the real API) and
  commit them under the target project's test fixtures directory (convention:
  `<Tests>/Fixtures/<source>-<endpoint>.json`, with a comment noting capture date/source).

## R2 rules — run the app and look

- **Reproduce the triggering interaction**, not just a static launch. A scroll bug needs a
  scroll; a tap bug needs a tap. Synthetic input (e.g. Quartz drag scripts) is valid for
  artifact presence/absence, weak for landing a precise frame — flag precise-frame checks
  as a human pass.
- **Races need N cold launches.** For launch-timing / nondeterministic renders: kill and
  relaunch **5–10×** (cold starts); pass only if the defect never appears. A single
  screenshot is not a valid pass for a race. `scripts/app_screenshot.sh` automates this
  for iOS simulators.
- **Demand a named mechanism, not a bundle.** A race fix must state *why* it is now
  deterministic. Two or three "complementary" changes shipped hoping one wins is a tell
  the race wasn't pinned — reject and ask for the mechanism.
- **Verify the data source before the pixels.** Before judging rendering, confirm the
  component actually receives the data it should (trace the binding/fetch). An empty data
  source mimics layout bugs and burns cycles (RULES.md operating lesson 1).
- **Use a build configuration where the real data path runs.** e.g. unsigned iOS sim
  builds can fail Keychain access and silently fall back to demo data — a demo-mode
  screenshot is NOT a valid R2 pass.
- **Scope discipline:** one bug = one mechanism per PR. Split unrelated changes so the
  fix's effect is attributable.

---

## Enforcement

- Task specs and PLAN.md tasks carry `verify_tier: R0|R1|R2`.
- The orchestrator does not merge until the tier's full ladder has passed and the diff
  review verdict is recorded (TASK_LOG event or PR comment).
- Genuinely device-only checks (GPU effects, haptics, perf feel) are flagged as an
  explicit human pass — never silently skipped, never auto-passed.
