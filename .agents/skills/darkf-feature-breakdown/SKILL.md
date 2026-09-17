---
name: darkf-feature-breakdown
description: Decompose a feature plan/spec into a GitHub epic with phased sub-issues labeled for dark-factory processing, OR break it down inline from conversation. Use after brainstorming/grill/lavish sessions when you have a plan doc and want to create structured, dependent issues for overnight dark-factory execution.
---

# darkf-feature-breakdown

Transforms a feature specification into a GitHub issue hierarchy:
- **Parent epic** (labeled `darkf-epic`) — carries the full functionality and the
  ordered phase list. It is the source of truth.
- **Child sub-issues** (labeled `darkf-todo`, `phase:N`) — the work units, each
  dispatched as one ship in order.

This is the **create** front end of the dark-factory pipeline (chapter 1 of
`docs/dark-factory.md`). It authors issues into the dark-factory-ready state.
The `darkfactory` skill is the operator: it walks the parent's ordered children
and turns them into ships. The two are separate stages joined by the
`darkf-todo` label.

## When to Load

- After a brainstorming/grill/lavish session produces a plan/spec doc
- Captain wants to break a large feature into overnight-executable phases
- Captain describes the feature inline and wants per-phase issues created
- `bin/fm-darkf-breakdown.sh` is the executable backing this skill

## What the script does

`bin/fm-darkf-breakdown.sh` uses **gh-axi only** (never raw `gh`). It:

1. Resolves the current user from `gh-axi api user` (never hardcoded).
2. Creates the epic (labeled `darkf-epic`) whose body carries the full
   functionality and the ordered phase list.
3. Creates one child issue per phase, each titled
   `<Theme> - Phase <N>: <description>` (Theme = epic title, shared by all
   children), labeled `darkf-todo` (all-eligible) and `phase:N` (display only),
   assigned to the current user by default, and carrying the 4-section template.
4. Links each child as a sub-issue of the epic, in creation order. That ordering
   is what `/darkfactory` walks (1, 2, 3 ... one PR at a time).

## Inputs

| Input | Flag | How issues get their content |
|-------|------|------------------------------|
| Plan/spec markdown | `--plan SPEC.md` | Phases from `## Phase N` headings. Each issue REFERENCES the spec by path; the detailed proposed-change content stays in the spec. |
| Interactive | `--interactive` | Captain describes the feature + each phase inline; the inline content IS the issue body. |
| Lavish board | `--from-lavish ID` | Not yet implemented; use `--plan` or `--interactive`. |

```bash
# From a spec (content stays in the spec; issues point at it by path)
bin/fm-darkf-breakdown.sh --plan SPEC.md --repo owner/repo

# Interactive: break the spec/feature down inline into per-phase issues
bin/fm-darkf-breakdown.sh --interactive --repo owner/repo

# Preview without creating anything
bin/fm-darkf-breakdown.sh --plan SPEC.md --repo owner/repo --dry-run
```

The script provisions the dark-factory labels (`darkf-epic`, `darkf-todo`,
`darkf-wip`, `darkf-failed`) and `phase:N` in the target repo automatically, so
issue creation never fails on a missing label.

## Output shape

Each child carries the **4-section dark-factory template**, is labeled
`darkf-todo, phase:N`, is assigned to the current user, and is titled with the
epic theme and phase so it passes the intake gates (assigned to you + template
present + `darkf-todo`):

- `### Problem` — the phase description
- `### Impact` — inline description (interactive), or empty (plan: see spec)
- `### Proposed Solution` — points at the spec path (plan) or inline content
- `### Acceptance Criteria` — done condition / reference

```
GitHub Issues Created:
├── #123 Epic: User Authentication System  [darkf-epic]  (full functionality)
│   ├── #124 "User Authentication System - Phase 1: MFA Core" [darkf-todo, phase:1]
│   ├── #125 "User Authentication System - Phase 2: Recovery Codes" [darkf-todo, phase:2]
│   ├── #126 "User Authentication System - Phase 3: Device Trust" [darkf-todo, phase:3]
│   └── #127 "User Authentication System - Phase 4: Admin MFA Enforcement" [darkf-todo, phase:4]
```

All children are all-eligible (`darkf-todo`). The `phase:N` label is display-only;
identity and ordering come from the parent's sub-issue list. Duplicate theme in
the title is intentional - it makes the theme + phase visible on every child and
limits cross-epic confusion.

## Hand-off

After creation, every child is tagged `darkf-todo` and assigned to the current
user. `/darkfactory` walks the parent's children in order, one PR at a time
(waiting for review-and-merge, or auto-merge under yolo-on, before the next), and
stops if it reaches a child that is not assigned to the operator.

## Dependencies

- `gh-axi` (GitHub CLI wrapper) — issue creation, sub-issue linking, labels
- `darkf-intake` / `darkfactory` skill — downstream consumers
- `jq` — not required; output fields are parsed from gh-axi output

## Files Created

- `bin/fm-darkf-breakdown.sh` — executable, gh-axi only, `--dry-run`, label provisioning
- This skill document