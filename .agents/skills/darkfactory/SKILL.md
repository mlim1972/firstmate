---
name: darkfactory
description: >-
  Run the dark-factory overnight PR pipeline from the captain's registered
  projects. Load when the captain invokes /darkfactory (optionally with project
  names, e.g. /darkfactory brainiac collabhub). It walks parent epics (labeled
  darkf-epic) for their ordered sub-issues, turns each eligible (darkf-todo,
  assigned to the captain) child into a ship, and dispatches them serially - one
  PR at a time, waiting for a review-and-merge (or auto-merge under yolo-on)
  before the next. It STOPS when it reaches a child not assigned to the captain.
  Manual replacement for the old cron + df-night-shift secondmate scheduler: no
  scheduler, no secondmate, no auto-merge except a project's registered yolo-on
  posture.
user-invocable: true
metadata:
  internal: true
---

# darkfactory

The night-shift run, started by the captain instead of a scheduler or secondmate.
The captain invokes `/darkfactory` before stepping away; it walks the fleet's
parent epics and turns their ordered sub-issues into ships, one at a time.

## Invocation

- `/darkfactory` — scan the parent epics across every project registered in
  `data/projects.md`.
- `/darkfactory <project> [<project> ...]` — scan only the named project(s).

## The model: parent epic is the source of truth

- A **parent epic** (labeled `darkf-epic`) carries the full functionality in its
  body and lists its phases in execution order.
- Its **child sub-issues** are the work units (titled
  `<Theme> - Phase <N>: <description>`, all sharing the parent's theme). Each
  child is eligible from the start (`darkf-todo`) and assigned to the captain.
- **Order and identity come from the parent's sub-issue list**, never from the
  `phase:N` label (that label is display-only and could collide across epics).
- A child is processed **only if it is assigned to the captain**.

## What it does

1. Resolve the target projects from `data/projects.md` (all, or the named set).
   For each, derive the GitHub owner/repo from its clone's origin remote.
2. Find the parent epics (open issues labeled `darkf-epic`).
3. For each epic, list its sub-issues in order (`gh-axi issue subissue list`).
4. For each child in order, run `bin/fm-darkf-intake.sh <issue-url>`:
   - **exit 0** (clean skip, e.g. already closed or an epic label) — continue.
   - **exit 5** (STOP: `darkf-todo` but not assigned to the captain) — **halt
     the whole run** and report. The serial chain cannot skip forward past a
     child that needs a different owner.
   - **success** — creates the ship backlog task, records `darkf_*` in its
     meta, adds `darkf-wip`.
   - **exit 1** (template failure) — the intake labels it `darkf-failed` and
     comments; record it and continue.
5. Dispatch the created ships **serially, one at a time, in parent-ordered
   sequence**: `bin/fm-brief.sh <id> <project> --mode <mode>` then
   `bin/fm-spawn.sh <id> <project> --mode <mode> --yolo <yolo>`.
6. **Merge-before-next**: wait for the current child's PR to be reviewed AND
   merged before dispatching the next. Under a project's `yolo: on` posture the
   merge is automatic once green, so the next child starts then.
7. Report each landed phase and the night's outcome in plain English.

## Mode and yolo discipline

Resolve each task's `mode <yolo>` from the project's registered posture with
`bin/fm-project-mode.sh <project>` (output is `<mode> <yolo>`) and pass both
explicitly to `fm-brief.sh` and `fm-spawn.sh`. Never guess or hard-code them.
`no-mistakes-prod-only` is a registry policy, not a task mode: classify each
task's surface per `project-management` (internal-only tooling/release work
ships direct-PR; product-facing or uncertain ships no-mistakes). Nothing
auto-merges except a project whose registered posture is `yolo: on`; yolo-off
work stops at a PR and waits for the captain's review (the next phase is held
until that merge).

## Serial, order, and stop rules

- **Serially**: never two dark-factory ships at once. The next child dispatches
  only after the current one's PR is merged.
- **In parent-ordered sequence**: children run in the parent's sub-issue order
  (1, 2, 3 ...). The `phase:N` label is never used to order.
- **Stop on foreign assignment**: if a child carries `darkf-todo` but is not
  assigned to the captain, the intake exits 5 and the run halts - do not skip
  forward. Report it; the chain is blocked until the child's assignment is
  corrected.
- **Token limits**: on a quota/token wall, stop and retry that item when
  capacity clears instead of racing ahead or failing the night.

Dispatch only to registered projects. If a project is not registered, note it
and skip rather than aborting the scan. Pick the fitting crewmate / harness per
the normal dispatch path; never invent a second delegation system.

## Traceability

Each created task's `state/<id>.meta` records `darkf_issue=`, `darkf_number=`,
`darkf_repo=`, and `darkf_assignee=`. Use those to map a PR back to its source
issue for the captain's morning review.

## Definition of done for a run

The run is finished when every eligible child in every scanned epic has been
turned into a ship AND landed (PR merged, or auto-merged under yolo) - or the
run stopped (exit 5) because a child is not assigned to the captain. Give the
captain one plain-English summary of what landed, what is still open, and where.