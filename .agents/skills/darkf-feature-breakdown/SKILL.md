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

1. **Scans** for `darkf-todo` issues
2. **Groups** by parent epic (via `darkf-epic` label + sub-issue relationship)
3. **Sorts** by `phase:N` label
4. **Only processes Phase 1** initially (creates backlog task)
5. **On Phase 1 PR merge** → auto-promotes Phase 2:
   - Removes `darkf-todo` from Phase 1 (now `darkf-done`)
   - Adds `darkf-todo` to Phase 2
   - Next hourly scan picks up Phase 2

**Config** (optional, in `config/darkf-schedule`):
```ini
AUTO_ADVANCE_PHASES=true  # default false; enable after pilot
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