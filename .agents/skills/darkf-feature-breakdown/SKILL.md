---
name: darkf-feature-breakdown
description: Decompose a feature plan/spec into a GitHub epic with phased sub-issues labeled for dark-factory processing. Use after brainstorming/grill/lavish sessions when you have a plan doc and want to create structured, dependent issues for overnight dark-factory execution.
---

# darkf-feature-breakdown

Transforms a feature specification into a GitHub issue hierarchy:
- **Parent epic** (labeled `darkf-epic`) — tracks overall feature
- **Sub-issues** (labeled `darkf-todo,phase:N`) — each phase runs independently in dark-factory

## When to Load

- After a brainstorming/grill/lavish session produces a plan/spec doc
- Captain wants to break a large feature into overnight-executable phases
- Interactive mode: captain describes feature, skill proposes breakdown

## Input Sources

| Source | Flag | Description |
|--------|------|-------------|
| Plan/spec markdown file | `--plan SPEC.md` | Structured spec with phases/sections |
| Lavish board URL/ID | `--from-lavish board-123` | Visual design with phased comparisons |
| Brainstorming session artifact | `--from-brainstorming` | Reads `data/brainstorming-notes.md` or similar |
| Interactive | `--interactive` | Prompts captain for feature description |

## Output

```
GitHub Issues Created:
├── #123 "Epic: User Authentication System" [darkf-epic]
│   ├── #124 "Phase 1: MFA Core Implementation" [darkf-todo, phase:1]
│   ├── #125 "Phase 2: Recovery Codes & Backup" [darkf-todo, phase:2] (depends on #124)
│   ├── #126 "Phase 3: Device Trust & Remember Me" [darkf-todo, phase:3] (depends on #125)
│   └── #127 "Phase 4: Admin MFA Enforcement" [darkf-todo, phase:4] (depends on #126)
```

Each sub-issue contains the **4-section dark-factory template**:
- `### Problem`
- `### Impact`
- `### Proposed Solution`
- `### Acceptance Criteria`

## Procedure

### 1. Load Context
- Read plan doc / Lavish board / brainstorming notes
- Extract: feature name, phases, technical approach, risks, test requirements

### 2. LLM Decomposition (if not pre-structured)
Prompt:
```
Given this feature spec, decompose into 3-6 logical phases.
Each phase must be independently implementable and testable.
Output: phase name, description, dependencies, 4-section template content.
```

### 3. Lavish Review Board
Build interactive board:
- **Node per issue** (epic + phases)
- **Edges** = `depends-on` relationships
- **Click node** → edit 4 sections inline
- **Validate** all 4 sections present before create

### 4. Captain Confirmation
Show summary:
```
Epic: User Authentication System
  Phase 1: MFA Core (no deps) — 4 sections ✓
  Phase 2: Recovery Codes (depends on #1) — 4 sections ✓
  Phase 3: Device Trust (depends on #2) — 4 sections ✓
  Phase 4: Admin Enforcement (depends on #3) — 4 sections ✓

Create 5 issues in owner/repo? [y/N]
```

### 5. Create Issues via gh-axi
```bash
# Create epic
EPIC_ID=$(gh issue create --repo $REPO --title "Epic: $NAME" --label darkf-epic --body-file epic.md)

# Create phases in order
PREV_ID=""
for phase in phases; do
  ISSUE_ID=$(gh issue create --repo $REPO --title "$phase.title" \
    --label "darkf-todo,phase:$phase.num" --body-file phase.md)
  if [ -n "$PREV_ID" ]; then
    gh api graphql -f query="mutation { addSubIssue(input: {issueId: \"$EPIC_ID\", subIssueId: \"$ISSUE_ID\"}) }"
    # Also add depends-on in body: "Depends on: #$PREV_ID"
  fi
  PREV_ID=$ISSUE_ID
done
```

## Dark-Factory Integration

**Intake script (`fm-darkf-intake.sh`)** behavior with phases:

1. **Fetches** each `darkf-todo` issue individually (triggered hourly)
2. **Detects parent epic** via GitHub sub-issue relationship (GraphQL)
3. **Phase gating**:
   - **Phase 1** (`phase:1`): always processed immediately
   - **Phase N>1**: only processed if prior phase is complete
     - Prior phase has `darkf-done` label, OR
     - Prior phase PR is merged (checked via timeline)
   - **Standalone issues** (no parent epic): processed normally
4. **On validation pass** → creates backlog task, adds `darkf-wip` label

**Phase promotion script (`fm-darkf-phase-promote.sh`)** — called from merge flow:

1. Triggered when main firstmate detects PR merge (via merge poll)
2. Reads `AUTO_ADVANCE_PHASES` from `config/darkf-schedule`
3. If `true`: finds next phase sub-issue, adds `darkf-todo`, marks prior phase `darkf-done`
4. Next hourly intake scan picks up promoted phase

**Config** (`config/darkf-schedule`):
```ini
START_HOUR=0
END_HOUR=6
AUTO_ADVANCE_PHASES=false  # default false; enable after pilot confirms pipeline
```

## Commands

```bash
# From plan doc
bin/fm-darkf-breakdown.sh --plan SPEC.md --repo owner/repo

# From Lavish board
bin/fm-darkf-breakdown.sh --from-lavish board-456 --repo owner/repo

# Interactive
bin/fm-darkf-breakdown.sh --interactive --repo owner/repo

# With custom phase count
bin/fm-darkf-breakdown.sh --plan SPEC.md --repo owner/repo --phases 4
```

## Files Created

- `bin/fm-darkf-breakdown.sh` — executable entry point
- This skill document

## Dependencies

- `gh-axi` (GitHub CLI wrapper) — for issue creation + GraphQL sub-issue linking
- `lavish-axi` — for review board (optional, falls back to text review)
- `jq` — JSON parsing
- `darkf-intake` skill — downstream consumer