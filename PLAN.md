---
project: "<project-name>"
created: "<ISO8601>"
updated: "<ISO8601>"
tasks:
  - id: T001
    title: "Design UI and interaction model"
    agent: designer
    status: pending
    depends_on: []
    inputs: []
    outputs:
      - prompts/design-spec.md
    model: null
    started_at: null
    completed_at: null
    error: null

  - id: T002
    title: "Architect build plan"
    agent: architect
    status: pending
    depends_on: [T001]
    inputs:
      - prompts/design-spec.md
    outputs:
      - prompts/build-spec.md
    model: null
    started_at: null
    completed_at: null
    error: null

  - id: T003
    title: "<implementation task title>"
    agent: opencode
    status: pending
    depends_on: [T002]
    inputs:
      - prompts/build-spec.md
    outputs: []
    model: null
    started_at: null
    completed_at: null
    error: null
---

## Task Overview

<!-- PM generates this summary from SPEC.md after approval. Describes phases, key dependencies, and expected deliverables. -->
