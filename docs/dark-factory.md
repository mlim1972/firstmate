# Dark Factory: The Full Workflow

Dark Factory turns a feature idea into merged PRs while you sleep. You start it
manually with `/darkfactory`; there is no scheduler, no cron, no secondmate.

This document walks the whole pipeline end to end, chapter by chapter, from the
first step (creating the issue) to the last (merging the PR). Each chapter names
the skill or script that owns it.

```
 1. CREATE   darkf-feature-breakdown  plan/spec  ->  GitHub epic + phased issues
 2. MAKE READY  labeling + assignee + 4 sections (done during create)
 3. INTAKE   /darkfactory + fm-darkf-intake.sh   issues  ->  ship backlog tasks
 4. DISPATCH /darkfactory (skill)                 tasks   ->  one at a time
 5. DELIVER  fm-brief / fm-spawn (normal ship lifecycle)  ->  PR
 6. MERGE    project yolo posture                 PR      ->  your review or auto
```

---

## 1. Create the issue: `darkf-feature-breakdown`

This is the freestanding front end. It exists independently of the rest of the
pipeline, and it is the first of the two disconnected chapters: an issue is not
born dark-factory-ready; something has to author it into that state.

`bin/fm-darkf-breakdown.sh` turns a feature plan into a GitHub issue hierarchy:

- A **parent epic** labeled `darkf-epic` that carries the full functionality and
  the ordered phase list. It is the source of truth.
- **Child sub-issues**, each labeled `darkf-todo` (all-eligible) plus `phase:N`
  (display-only), linked as sub-issues of the epic in creation order.

Children are titled `<Theme> - Phase <N>: <description>`, where `<Theme>` is the
epic title (shared by every child). The `phase:N` label is NEVER identity or
ordering - the parent's sub-issue list order is. `/darkfactory` walks that
order: Phase 1 first, then 2, 3, and so on.

### Inputs

| Input | Flag | What it reads |
|-------|------|---------------|
| Plan/spec file | `--plan SPEC.md` | A markdown file whose `## Phase N` headings define the phases; **the issues reference the spec by path**, the detailed content stays in the spec |
| Interactive | `--interactive` | Prompts for the feature description and each phase; the inline content IS the issue body |
| Lavish board | `--from-lavish ID` | Not yet implemented (falls back to `--plan` or `--interactive`) |

```bash
bin/fm-darkf-breakdown.sh --plan SPEC.md --repo owner/repo
bin/fm-darkf-breakdown.sh --interactive --repo owner/repo
bin/fm-darkf-breakdown.sh --plan SPEC.md --repo owner/repo --dry-run
```

The 4-section template is pre-filled into every sub-issue at creation time (see
chapter 2 for what those sections are and why they matter). The script runs on
**gh-axi** (never raw `gh`), provisions the dark-factory labels (`darkf-epic`,
`darkf-todo`, `darkf-wip`, `darkf-failed`) plus `phase:N` in the target repo, and
assigns each phase issue to the current user so it passes the intake gates
later.

A plan/spec file `## Phase N` sections feed this directly. A brainstorming,
grilling, or Lavish session that produces such a spec is the natural input.

### What labels mean here

| Label | Meaning |
|-------|---------|
| `darkf-epic` | The tracker issue carrying the full functionality and phase list; never processed itself |
| `darkf-todo` | Eligible for the pipeline (all children, from the start) |
| `darkf-wip` | The pipeline has claimed a child and a ship task exists |
| `darkf-failed` | Intake rejected a child; see the comment for what is missing |
| `phase:N` | Display/feed aid only; never identity or ordering |

---

## 2. Make the issue dark-factory-ready

Before the pipeline will touch an issue, three conditions must hold. The
breakdown skill already satisfies them at create time; a hand-filed issue must
satisfy them too.

1. **The `darkf-todo` label** - on the issue you want processed. Every child of
   a phased feature is all-eligible from the start; the epic itself does not
   carry `darkf-todo`.
2. **The issue is assigned to you** - the current gh-axi user. A `darkf-todo`
   issue assigned to someone else is a hard STOP for the serial run (it cannot
   skip forward past work that needs a different owner).
3. **The 4-section template is present** - in the body or any comment.

### The 4-section template

| Section | Purpose |
|---------|---------|
| `### Problem` | What is broken / needs to change |
| `### Impact` | Why this matters / user-facing impact |
| `### Proposed Solution` | High-level approach (may be "figure it out") |
| `### Acceptance Criteria` | Observable done condition (may be "make existing tests pass") |

For a phased feature, every child sub-issue carries this template. Order and
identity come from the parent epic's sub-issue list (chapter 3), not from any
`phase:N` label.

---

## 3. Run the intake: `/darkfactory` + `bin/fm-darkf-intake.sh`

You start the night with `/darkfactory`. It finds the parent epics in the
fleet's registered projects, walks each parent's ordered sub-issues, and runs
each child through the intake script.

### Invocation

```
/darkfactory            # scan all registered projects in data/projects.md
/darkfactory <project>  # /darkfactory brainiac collabhub  (one or more named)
```

For each candidate child the intake script `bin/fm-darkf-intake.sh <issue-url>`
enforces four gates, in order. Everything uses **gh-axi**; the current user is
read live from `gh-axi api user`, never hardcoded.

| # | Gate | On fail |
|---|------|---------|
| 1 | Open and carries `darkf-todo` | Skip (not ready) |
| 2 | Assigned to the current gh-axi user | **STOP** (exit 5) - halt the serial chain |
| 3 | (not in the all-eligible child flow; reserved for a labeled parent) | Skip - no point |
| 4 | All 4 required sections present | Label `darkf-failed`, comment what is missing |

On passing all four, the script creates a **ship backlog task** for the issue's
project, records `darkf_issue=`, `darkf_number=`, `darkf_repo=`, `darkf_assignee=`
in the task's meta, and adds the `darkf-wip` label.

`DRY_RUN=1 bin/fm-darkf-intake.sh <issue-url>` prints the gate decisions and the
would-be task without creating anything.

### The ordering rule (all-eligible, parent-ordered)

The `darkfactory` skill walks each parent epic's sub-issues **in their creation
order** (1, 2, 3 ...). Every child is already `darkf-todo` (all-eligible). It
processes them serially, one PR at a time, waiting for a review-and-merge before
the next (or auto-merge under yolo-on). If a child is `darkf-todo` but not
assigned to the operator, the run STOPS at that child - the chain cannot skip
forward past work that needs a different owner.

An issue whose repo is not registered in `data/projects.md` is skipped with a
note rather than aborting the scan.

---

## 4. Dispatch: `/darkfactory` (the skill), serial and in order

The created ship tasks are dispatched by the `darkfactory` skill through the
normal firstmate ship lifecycle. Three rules govern the runtime of the night.

- **Serially**: never two dark-factory ships at once. The next child dispatches
  only after the current one's PR is reviewed AND merged (or auto-merged under
  yolo-on). This avoids token spikes.
- **In parent-ordered sequence**: children run in the parent epic's sub-issue
  order. The `phase:N` label is never used to order.
- **Token-limit resilience**: on a quota/token wall, stop and retry that item
  when capacity clears instead of racing ahead or failing the night.

Dispatch goes through the standard `fm-brief.sh` and `fm-spawn.sh` machine, in a
clean isolated ship worktree, exactly as any other ship task would.

---

## 5. Deliver: the normal ship lifecycle

Each dark-factory ship task follows the selected project's delivery mode, which
is resolved per project from its registered posture with
`bin/fm-project-mode.sh <project>` (output is `<mode> <yolo>`) and passed
explicitly to `fm-brief` and `fm-spawn`.

| Registry mode | Behavior |
|---------------|----------|
| `no-mistakes` | Full pipeline: review, tests, lint, docs, push, PR, CI |
| `no-mistakes-prod-only` | Conditional policy - firstmate classifies each task's surface at dispatch (internal/release work ships direct-PR; product-facing or uncertain ships no-mistakes) |
| `direct-PR` | Push + PR, no pipeline |
| `local-only` | Stop at a clean branch; guarded local merge |

The worker's brief maps the issue spec (problem, impact, proposed solution,
acceptance criteria — chapter 2) into the task's `## Captain's intent`, with the
build instructions under `## Firstmate spec`.

---

## 6. Merge: only what your posture allows

`yolo` governs merge authority, per project.

- `yolo: off` (the default) keeps everything at a PR for **your** review in the
  morning.
- `yolo: on` lets firstmate merge green, in-scope PRs itself while you sleep.

Dark factory never merges anything except what a project's own registered `yolo`
posture authorizes. A red or out-of-scope PR is never merged under either
setting without your explicit word.

---

## Morning

Run `/bearings include PRs` to see the PRs produced overnight with full URLs.
Review each, request changes if needed, approve, and merge (yolo off keeps
merges yours).

---

## The two disconnected chapters

Dark Factory is a pipeline of two intentionally separate stages:

1. **Creating the issue** (chapter 1) - `darkf-feature-breakdown` authors the
   epic + phased issues. It is purely a GitHub authoring tool and runs whenever
   the captain wants, independent of the overnight run.
2. **Processing it into a PR** (chapters 2-6) - `/darkfactory` runs the issue
   through intake, dispatch, delivery, and merge.

They disconnect at the label: issues authored by chapter 1 are not processed
until the captain runs `/darkfactory`, and chapter 1 can produce issues without
ever running the pipeline. The `darkf-todo` label (all children are eligible)
plus assignment to the operator is the hand-off between them.

---

## Files

| Component | Location | Role |
|-----------|----------|------|
| Breakdown skill | `.agents/skills/darkf-feature-breakdown/SKILL.md` | Issue creation (chapter 1) |
| Breakdown script | `bin/fm-darkf-breakdown.sh` | Authors epic + phased issues |
| Dark-factory skill | `.agents/skills/darkfactory/SKILL.md` | The `/darkfactory` run (chapters 3-6) |
| Intake reference | `.agents/skills/darkf-intake/SKILL.md` | Intake template + gate semantics |
| Intake script | `bin/fm-darkf-intake.sh` | The four-gate intake (gh-axi, `DRY_RUN`) |
| This file | `docs/dark-factory.md` | The whole workflow |

## Safety

| Guarantee | Mechanism |
|-----------|-----------|
| No auto-merge unless yolo | Every task passes its project's registered yolo posture |
| Only your issues | Assignee gate reads the live gh-axi user and STOPS on a foreign child |
| Ordered phases | Parent epic's sub-issue list order, walked serially |
| No token spikes | Strictly serial dispatch, merge before next |
| Isolated work | Normal ship worktrees, unchanged |
| Unlanded work protected | Teardown still refuses dirty/unmerged work |