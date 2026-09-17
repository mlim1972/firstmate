---
name: darkf-intake
description: Validate GitHub issues against the dark-factory task template before dispatching as Firstmate ship tasks. Use when a GitHub issue labeled `darkf-todo` needs intake validation, or when building a dark-factory pipeline that converts issues into validated backlog items.
---

# darkf-intake

Intake validation skill for the dark-factory pipeline. Ports the intake gate from `mlim1972/dark-factory` (packages/core/src/issueTemplate.ts) into Firstmate's skill system.

## When to Load

- A GitHub issue labeled `darkf-todo` appears in a project registered in `data/projects.md`
- The `darkfactory` skill (the captain-invoked entry point) dispatches intake for a scanned issue
- Captain invokes `/darkf-intake <issue-url>` for manual validation

## Reference

The `darkfactory` skill is the operational entry point: it scans projects, runs
this intake on each candidate issue, and dispatches ships serially. This skill
documents the intake template and gate semantics only.

## Contract

**Input**: GitHub issue URL or issue number + repo context
**Output**: 
- Success → backlog item created with `kind=ship`, mode resolved from project posture, `darkf-todo` label retained, `darkf-wip` added
- Failure → issue labeled `darkf-failed`, `darkf-todo` removed, comment posted with missing sections

## Required Template Sections

The issue body **or any comment** must contain all four section headers (case-insensitive, label-insensitive):

| Section | Purpose |
|---------|---------|
| `problem` | What is broken / what needs to change |
| `impact` | Why this matters / user-facing impact |
| `proposed-solution` | High-level approach (can be "figure it out", "you decide") |
| `acceptance-criteria` | Observable done condition (can be "make existing tests pass") |

Headers are matched by regex: `/^###\s*(problem|impact|proposed[- ]?solution|acceptance[- ]?criteria)\b/i`

## Validation Procedure

```bash
# 1. Fetch issue (gh-axi)
gh-axi issue view <issue-url> --json body,comments,labels,number,title

# 2. Concatenate body + all comment bodies
# 3. Scan for four required headers
# 4. On PASS:
#    - bin/fm-tasks-axi.sh add "darkf: <title>" --kind ship --repo <project>
#    - Record issue URL, number in task meta (darkf_issue=, darkf_number=)
#    - gh-axi issue edit --add-label darkf-wip
# 5. On FAIL:
#    - gh-axi issue edit --remove-label darkf-todo --add-label darkf-failed
#    - gh-axi issue comment --body "Intake failed: missing sections: <list>"
```

## Integration Points

- The `darkfactory` skill routes scanned candidate issues through this intake
- Assignee and dependency gates are enforced in `bin/fm-darkf-intake.sh`, not here
- The assignee gate STOPS (exit 5) when a child is not assigned to the operator, so
  the serial chain halts rather than skipping forward; the dependency gate skips
- Project posture from `data/projects.md` resolves delivery mode at dispatch
- Merge authority stays with the captain (`yolo: off` by default)

## Error Handling

- Missing `gh` auth → escalate to captain (credential needed)
- Private repo not cloned → `project-management` add/clone first
- Network failure → re-queue via backlog `blocked` state, retry on next heartbeat
- Malformed issue (no body) → treat as missing all sections

## Files Created

- `bin/fm-darkf-intake.sh` — executable intake gate (gh-axi, with `DRY_RUN`)
- This skill document

## Testing

```bash
# Valid issue
fm-darkf-intake.sh https://github.com/owner/repo/issues/123

# Invalid issue (should label darkf-failed)
fm-darkf-intake.sh https://github.com/owner/repo/issues/456
```