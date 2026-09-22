---
name: nightly-darkfactory
description: >-
  Run the dark-factory overnight PR pipeline with optional secondmate
  correlation. On main firstmate: executes darkfactory and reports summary to
  chat. On secondmate: executes darkfactory and writes a correlated status
  line (with corr_id from the steer message) so the parent firstmate's
  pending-reply mechanism can resolve the steer expectation.
user-invocable: true
metadata:
  internal: true
---

# nightly-darkfactory

Wrapper around the darkfactory pipeline that works on both the main firstmate
and a persistent secondmate. When run on a secondmate, it extracts the
correlation ID from the steer message that invoked it and writes a correlated
`done` status line, allowing the parent firstmate's pending-reply machinery to
resolve the outstanding expectation.

## Invocation

- `/nightly-darkfactory` — run on all projects registered in `data/projects.md`
- `/nightly-darkfactory <project> [<project> ...]` — run only on named project(s)
- `/nightly-darkfactory --corr <corr_id>` — (internal) explicit correlation ID;
  normally auto-detected from inbox on secondmate

## Behavior by Context

### Main Firstmate (default)
Runs the darkfactory pipeline exactly as the `darkfactory` skill does: scans
parent epics (`darkf-epic`), validates children via `fm-darkf-intake.sh`,
dispatches ships serially with merge-before-next, and prints a plain-English
summary to chat. No correlation ID is used.

### Secondmate (detected via `.fm-secondmate-home`)
1. Reads its own task ID from metadata (or inbox)
2. Reads the latest steer message from its steering inbox
3. Extracts the `corr=<16hex>` token from the marker
3. Runs the darkfactory pipeline
4. Appends a correlated status line to its own `state/<task_id>.status`:
   `done [corr=<corr_id>]: nightly darkfactory complete - <summary>`
5. The remote reply mirror (if remote) or local status fold picks this up and
   resolves the parent's pending-reply expectation.

## Cron / Scheduling

**Main firstmate cron** (option A — no secondmate needed):
```bash
0 2 * * * FM_HOME=/path/to/firstmate /path/to/firstmate/bin/fm-nightly-darkfactory.sh
```

**Main firstmate steering secondmate** (option B — secondmate runs it):
```bash
0 2 * * * FM_HOME=/path/to/firstmate /path/to/firstmate/bin/fm-send.sh nightly-darkfactory "/nightly-darkfactory"
```
The steer creates a pending-reply expectation; the secondmate's correlated
`done` line resolves it.

**Remote secondmate self-cron** (option C — secondmate runs itself):
```bash
0 2 * * * FM_HOME=/path/to/secondmate/home /path/to/secondmate/home/bin/fm-nightly-darkfactory.sh
```
No parent correlation (fire-and-forget). Use only when you don't need the
parent to track completion.

## Prerequisites

- Projects with `darkf-epic` issues must be registered in `data/projects.md`
- `gh-axi` authenticated as the captain (assignee gate checks this)
- Projects with `yolo: on` in registry auto-merge; others wait for captain review
- On secondmate: projects must be cloned in the secondmate's home

## Output

- Main: summary printed to chat (landed phases, open items, stop reasons)
- Secondmate: correlated `done` status line + summary logged locally
- Both: individual phase PRs created and tracked via `darkf_*` task meta

## Integration with darkfactory Skill

This skill reuses the darkfactory intake and dispatch logic via the shared
`bin/fm-nightly-darkfactory.sh` script. It does not duplicate the darkfactory
skill's internal logic — it orchestrates the same steps in a scriptable form.