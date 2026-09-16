# Dark Factory: Overnight Issue-to-PR Pipeline

> **Status**: Scaffolded and ready for pilot. See [Quick Start](#quick-start) to run tonight.

---

## What It Does

While you sleep, Firstmate automatically:

1. **Scans** your registered projects for GitHub issues labeled `darkf-todo`
2. **Validates** each issue against a structured template (problem, impact, proposed solution, acceptance criteria)
3. **Creates** a Firstmate backlog task with the correct delivery mode for the project
4. **Dispatches** an isolated crew to implement the fix in a clean worktree
5. **Runs** the project's full validation pipeline (tests, lint, typecheck, docs)
6. **Opens** a **draft PR** with the changes
7. **Waits** for your morning review

You wake up to draft PRs ready for approval — no merge happens without you.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    YOUR SLEEP WINDOW (00:00–06:00 UTC)           │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐    ┌─────────────────┐    ┌────────────────┐  │
│  │ System cron  │───▶│ df-night-shift  │───▶│ Main Firstmate │  │
│  │ (hourly)     │    │ secondmate      │    │ (dispatches)   │  │
│  └──────────────┘    └─────────────────┘    └────────────────┘  │
│         │                    │                      │             │
│         ▼                    ▼                      ▼             │
│  fm-darkf-           Scans all              Creates backlog      │
│  trigger.sh          projects for          tasks, spawns        │
│                      darkf-todo            crews in isolated    │
│                      issues                worktrees             │
│                                               │                 │
│                                               ▼                 │
│                                        ┌────────────────┐       │
│                                        │ Validation     │       │
│                                        │ pipeline       │       │
│                                        │ (no-mistakes   │       │
│                                        │  / direct-PR)  │       │
│                                        └────────────────┘       │
│                                               │                 │
│                                               ▼                 │
│                                        ┌────────────────┐       │
│                                        │ Draft PR       │       │
│                                        │ + merge poll   │       │
│                                        └────────────────┘       │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                        MORNING REVIEW                            │
├─────────────────────────────────────────────────────────────────┤
│  /bearings include PRs  →  Review draft PRs  →  Approve/merge   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Components

| Component | Location | Purpose |
|-----------|----------|---------|
| **Intake skill** | `.agents/skills/darkf-intake/` | Validates GitHub issues against dark-factory template |
| **Intake script** | `bin/fm-darkf-intake.sh` | Fetches issue, checks 4 required sections, creates backlog task |
| **Trigger script** | `bin/fm-darkf-trigger.sh` | Cron-callable; checks schedule, sends trigger to secondmate |
| **Secondmate charter** | `data/df-night-shift/brief.md` | Persistent domain that runs intake on trigger |
| **Schedule config** | `config/darkf-schedule` | UTC hour window (default 00:00–06:00) |
| **Dispatch profile** | `config/crew-dispatch.json` | Routes intake work to `pi` harness with high effort |
| **Project posture** | `data/projects.md` | Each project's delivery mode (`no-mistakes-prod-only` default) |

---

## Configuration

### 1. Sleep Window (`config/darkf-schedule`)

```ini
# Dark-factory intake schedule (UTC, 24-hour format)
# Only processes triggers when START_HOUR <= current_hour < END_HOUR
START_HOUR=0
END_HOUR=6
```

**Adjust for your timezone:**
| Your Zone | UTC Equivalent | Config |
|-----------|----------------|--------|
| US Pacific (PST) | 00:00–06:00 UTC = 16:00–22:00 PST | `START_HOUR=0, END_HOUR=6` + cron `0 0-5 * * *` |
| US Pacific (PDT) | 00:00–06:00 UTC = 17:00–23:00 PDT | `START_HOUR=0, END_HOUR=6` + cron `0 0-5 * * *` |
| US Eastern (EST) | 00:00–06:00 UTC = 19:00–01:00 EST | `START_HOUR=0, END_HOUR=6` + cron `0 0-5 * * *` |
| Europe (CET) | 00:00–06:00 UTC = 01:00–07:00 CET | `START_HOUR=0, END_HOUR=6` + cron `0 0-5 * * *` |

**Or shift the window:**
```ini
# Run 02:00–08:00 UTC instead
START_HOUR=2
END_HOUR=8
```

### 2. Cron Trigger (on Firstmate host)

```bash
# Edit crontab (use UTC unless you set TZ)
crontab -e

# Hourly during sleep window (adjust hours to match your START_HOUR/END_HOUR)
0 0-5 * * * /path/to/firstmate/bin/fm-darkf-trigger.sh >> /tmp/darkf-trigger.log 2>&1
```

**With timezone override:**
```bash
# Run at 17:00–23:00 US Pacific (00:00–06:00 UTC)
0 17-23 * * * TZ=America/Los_Angeles /path/to/firstmate/bin/fm-darkf-trigger.sh ...
```

### 3. Project Registration (`data/projects.md`)

Projects must be registered with a delivery posture:

```markdown
- my-project [no-mistakes-prod-only] - description
- internal-tool [direct-PR] - description
- local-script [local-only] - description
```

**Delivery modes:**
| Mode | Behavior |
|------|----------|
| `no-mistakes-prod-only` | **Default**. Product-facing work → full `no-mistakes` pipeline. Internal tooling → `direct-PR`. |
| `no-mistakes` | All work: review → tests → lint → docs → push → PR → CI |
| `direct-PR` | Push + open PR (no no-mistakes pipeline) |
| `local-only` | Stop at clean branch; captain merges locally |

### 4. GitHub Issue Template

Add to each project's `.github/ISSUE_TEMPLATE/darkf-task.yml`:

```yaml
name: "darkf Task"
description: "Structured task for overnight dark-factory processing"
title: "[darkf] "
labels: ["darkf-todo"]
body:
  - type: markdown
    attributes:
      value: |
        Fill all four sections below. The agent implements directly from this spec.
  - type: textarea
    id: problem
    attributes:
      label: "### Problem"
      description: What is broken or needs to change?
    validations:
      required: true
  - type: textarea
    id: impact
    attributes:
      label: "### Impact"
      description: Why does this matter? User-facing impact?
    validations:
      required: true
  - type: textarea
    id: proposed-solution
    attributes:
      label: "### Proposed Solution"
      description: High-level approach (can be "figure it out", "you decide")
    validations:
      required: true
  - type: textarea
    id: acceptance-criteria
    attributes:
      label: "### Acceptance Criteria"
      description: Observable done condition (can be "make existing tests pass")
    validations:
      required: true
```

**Or manually:** Add the four `###` headers to any issue body/comment:
```markdown
### Problem
The login flow fails when MFA is enabled.

### Impact
Users with 2FA cannot sign in; blocks 15% of active users.

### Proposed Solution
Fix the token refresh logic in `auth/mfa.ts`. You decide the exact approach.

### Acceptance Criteria
All existing auth tests pass + manual MFA login works.
```

### 5. GitHub Permissions (PAT)

The `gh` CLI needs a token with:
| Permission | Access | Purpose |
|------------|--------|---------|
| Contents | Read & Write | Read repo, create branches, push commits |
| Issues | Read & Write | Poll labels, add labels/comments |
| Pull Requests | Read & Write | Create draft PRs, update metadata |
| Metadata | Read | Required for fine-grained tokens |

---

## Workflow Details

### Intake Validation (runs hourly in sleep window)

For each `darkf-todo` issue found:

```
1. Fetch issue via gh-axi (body + all comments)
2. Scan for 4 required section headers (case-insensitive):
   - ### Problem
   - ### Impact
   - ### Proposed Solution (or Proposed-Solution)
   - ### Acceptance Criteria (or Acceptance-Criteria)
3. ON PASS:
   - Create backlog task: "darkf: <issue title>" (kind=ship)
   - Record issue URL/number in task meta
   - Add 'darkf-wip' label, keep 'darkf-todo'
   - Report to main firstmate via parent status
4. ON FAIL:
   - Add 'darkf-failed' label, remove 'darkf-todo'
   - Comment listing missing sections
   - No backlog task created
```

### Dispatch & Execution (main Firstmate)

Validated backlog tasks are picked up by the normal dispatch loop:

1. **Dispatch profile** `dark-factory-intake` matches → harness `pi`, model `sonnet`, effort `xhigh`
2. **fm-spawn.sh** creates isolated worktree (asserted in brief scaffold)
3. **Brief** contains:
   - `{TASK}` = issue spec (problem, impact, proposed solution, acceptance criteria)
   - `{FIRSTMATE_SPEC}` = run project's validation (tests, lint, typecheck, docs)
4. **Agent** runs project's delivery pipeline:
   - `no-mistakes` → full pipeline → PR
   - `direct-PR` → push + `gh pr create --draft`
   - `local-only` → stop at clean branch
5. **fm-pr-check.sh** registers PR URL + head SHA, arms merge poll

### Merge Authority

| Setting | Behavior |
|---------|----------|
| `yolo: off` (default) | Captain approves every PR merge |
| `yolo: on` | Firstmate auto-merges green, in-scope PRs |

**Dark factory defaults to `yolo: off`** — you merge in the morning.

---

## Issue Creation: From Brainstorm to darkf-todo

Before the overnight pipeline can run, you need structured issues. Two skills bridge the gap:

### 1. Single Issue: `darkf-issue-from-session` (Lightweight)

For one-off features after a brainstorming/grill session:

```bash
# Quick template editor
cat > /tmp/darkf-issue.md <<'EOF'
### Problem


### Impact


### Proposed Solution


### Acceptance Criteria

EOF
$EDITOR /tmp/darkf-issue.md
gh issue create --repo owner/repo --label darkf-todo --title "[darkf] Your Title" --body-file /tmp/darkf-issue.md
```

**Future skill** (not yet implemented): `/darkf-issue-from-session --from-brainstorming --repo owner/repo` — auto-fills template from session notes, shows Lavish preview, creates issue.

### 2. Multi-Phase Feature: `darkf-feature-breakdown` (Scaffolded)

For large features needing phased execution with dependencies:

```bash
# From a plan/spec doc (markdown with ## Phase N headings)
bin/fm-darkf-breakdown.sh --plan SPEC.md --repo owner/repo

# Interactive (no prior doc)
bin/fm-darkf-breakdown.sh --interactive --repo owner/repo

# Dry run to preview
bin/fm-darkf-breakdown.sh --plan SPEC.md --repo owner/repo --dry-run
```

**Creates:**
- **Epic issue** labeled `darkf-epic` (tracks overall feature)
- **Sub-issues** labeled `darkf-todo,phase:N` with `depends-on` links
- Each sub-issue has the 4-section template pre-filled

**Dark-factory behavior with phases:**
1. Only **Phase 1** gets `darkf-todo` initially → picked up hourly
2. When Phase 1 PR merges → auto-promotes Phase 2 (if `AUTO_ADVANCE_PHASES=true` in `config/darkf-schedule`)
3. Subsequent phases execute sequentially overnight

**Plan doc format (markdown):**
```markdown
# Feature: User Authentication System

## Phase 1: MFA Core Implementation
### Problem
...
### Impact
...
### Proposed Solution
...
### Acceptance Criteria
...

## Phase 2: Recovery Codes & Backup
### Problem
...
...
```

---

## Quick Start (Pilot Tonight)

### 1. Add Issue Template to a Test Project
```bash
cd projects/brainiac  # or any registered project
mkdir -p .github/ISSUE_TEMPLATE
# Copy the template from above or create darkf-task.yml
```

### 2. File a Test Issue
- Create issue with the 4 sections
- Add label `darkf-todo`
- Note the issue URL

### 3. Start the Secondmate
```bash
# From Firstmate root
bin/fm-spawn.sh df-night-shift --harness pi --mode no-mistakes
```

### 4. Verify It's Running
```bash
# Watch secondmate status
tail -f state/df-night-shift.status

# Should show: working [key=intake-scan]: scanning N projects for darkf-todo issues
# Then: done [key=intake-scan]: created M tasks, failed K validations
```

### 4. Trigger Manually (Optional)
```bash
# Test intake on your test issue
bin/fm-darkf-intake.sh https://github.com/owner/repo/issues/123

# Or trigger full scan
bin/fm-darkf-trigger.sh
```

### 5. Before Bed
```bash
# Confirm secondmate is idle (empty queue = healthy)
bin/fm-crew-state.sh df-night-shift

# Add cron entry (adjust hours for your timezone)
crontab -e
# 0 0-5 * * * /path/to/firstmate/bin/fm-darkf-trigger.sh >> /tmp/darkf-trigger.log 2>&1
```

### 6. Morning
```bash
/bearings include PRs
# Shows all draft PRs created overnight with full URLs
# Review each PR, request changes if needed, approve → merge
```

---

## Monitoring & Debugging

### Secondmate Status
```bash
# Live tail
tail -f state/df-night-shift.status

# Recent history
cat state/df-night-shift.status
```

### Intake Logs
```bash
# Cron trigger log
cat /tmp/darkf-trigger.log

# Intake script output (in secondmate's inbox handling)
# Check secondmate's state/<task-id>.status for each intake task
```

### Backlog
```bash
# See created tasks
bin/fm-tasks-axi.sh list --state queued --repo brainiac

# Full task detail
bin/fm-tasks-axi.sh show <task-id> --full
```

### Common Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| `fm-send failed` | Secondmate not running | `bin/fm-spawn.sh df-night-shift --harness pi` |
| `gh not authenticated` | PAT expired/missing | `gh auth login` with correct scopes |
| `repo not in projects.md` | Project not registered | `bin/fm-project-mode.sh add <project>` |
| No tasks created | Issues missing template sections | Check issue has all 4 `###` headers |
| PR not created | Validation pipeline failed | Check crew's `state/<task-id>.status` for failure details |

---

## What Happens to Failed Validations

| Failure Point | Outcome |
|---------------|---------|
| Intake template missing sections | Issue labeled `darkf-failed`, commented, no backlog task |
| Crew validation fails (tests/lint) | Task status `failed`, backlog Held, captain decides retry |
| Crew stuck (stale wake) | `stuck-crewmate-recovery` attempts relaunch once |
| Rate limit hit | gnhf-style exponential backoff, retries next hour |
| PR merge conflict | Captain resolves manually; backlog stays queued |

---

## Extending the Pipeline

### Add More Projects
```bash
# Register new project (auto-detects delivery mode)
bin/fm-project-mode.sh add my-new-project
# Adds to data/projects.md with no-mistakes-prod-only
```

### Change Agent/Harness
Edit `config/crew-dispatch.json`:
```json
{
  "name": "dark-factory-intake",
  "harness": "claude",  // or codex, opencode
  "model": "anthropic/claude-sonnet-4-5",
  "effort": "xhigh"
}
```

### Add Custom Validation
Create a skill that runs before dispatch (e.g., security scan, dependency check) and hook it via dispatch profile or brief spec.

### Use gnhf for Multi-Iteration Refinement
In the brief's `{FIRSTMATE_SPEC}`, add:
```
Run gnhf --worktree --push --stop-when "tests pass and PR opened"
```
inside the worktree for iterative refinement before PR creation.

---

## Safety Guarantees

| Guarantee | Mechanism |
|-----------|-----------|
| **No auto-merge** | `yolo: off` by default; captain merges in morning |
| **Draft PRs only** | `gh pr create --draft` / no-mistakes opens draft |
| **Isolated worktrees** | Each crew gets clean `git worktree`; no cross-contamination |
| **Unlanded work protected** | Teardown refuses if worktree dirty or PR unmerged |
| **Rate limits respected** | gnhf-style wait with exponential backoff |
| **Captain approval required** | All merges escalate unless explicit `yolo: on` |
| **Destructive actions blocked** | Firstmate hard rules prevent force/discard without explicit captain word |

---

## Files Reference

```
firstmate/
├── .agents/skills/
│   ├── darkf-intake/
│   │   └── SKILL.md                 # Intake validation skill
│   └── darkf-feature-breakdown/
│       └── SKILL.md                 # Feature breakdown skill (epic + phases)
├── bin/
│   ├── fm-darkf-intake.sh       # Validates issue, creates backlog task
│   ├── fm-darkf-trigger.sh      # Cron trigger (checks schedule, fm-sends)
│   └── fm-darkf-breakdown.sh    # Decomposes plan into epic + phased sub-issues
├── config/
│   ├── darkf-schedule           # START_HOUR/END_HOUR (UTC), AUTO_ADVANCE_PHASES
│   └── crew-dispatch.json       # Dispatch profile for intake work
├── data/
│   └── df-night-shift/
│       └── brief.md             # Secondmate charter (time-gated)
├── docs/
│   └── dark-factory.md          # This file
└── projects/                    # Cloned repos (registered in data/projects.md)
```

---

## Related Documentation

- `AGENTS.md` §7 — Task lifecycle, delivery modes, merge authority
- `docs/project-configuration.md` — Project registry, delivery postures
- `docs/configuration.md` — Full config schema (config/*, data/*, state/*)
- `mlim1972/dark-factory` — Original dark-factory implementation (issue template, lease, sandbox, draft PR flow)
- `kunchenguid/gnhf` — Overnight runner (worktree, commit/rollback, rate-limit wait, `--stop-when`)

---

## TL;DR for Captain

1. **Add issue template** to projects you want processed overnight
2. **Label issues** `darkf-todo` with 4 sections filled
3. **Start secondmate** once: `bin/fm-spawn.sh df-night-shift --harness pi`
4. **Add cron** on your machine for 00:00–06:00 UTC hourly
5. **Sleep**
6. **Morning**: `/bearings include PRs` → review draft PRs → approve/merge

**No merge happens without you.** The pipeline stops at draft PR.