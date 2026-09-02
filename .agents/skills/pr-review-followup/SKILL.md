---
name: pr-review-followup
description: >-
  Agent-only playbook for responding to review feedback on a PR whose worker
  was already torn down at PR-open (AGENTS.md section 7).
  Use on a `check:` wake naming a changes-requested review result.
  Owns confirming the feedback is still live, filing the follow-up work item,
  and briefing a fresh crewmate to update the EXISTING PR branch in place.
user-invocable: false
metadata:
  internal: true
---

# pr-review-followup

A ship task is torn down as soon as its PR is open, well before merge
(AGENTS.md section 7), so by the time a reviewer requests changes the original
worker and its worktree are already gone.
The armed merge poll (`bin/fm-pr-check.sh`) keeps watching the same PR after
that teardown, and also reports a changes-requested review as a distinct
`check:` wake carrying `changes_requested` in its payload (`bin/fm-pr-poll.sh`,
`bin/fm-watch.sh`) instead of staying silent until the eventual merge.
That wake is re-armed independently for each new head, so a second, third, or
later round of feedback on the same PR produces its own fresh wake - this
playbook's response is the same every time, repeating until merge.

## Confirm before dispatching

The wake means GitHub's `reviewDecision` was `CHANGES_REQUESTED` at poll time.
Read the PR with `gh-axi` before dispatching: confirm no one has already
pushed a fix and re-requested review since the poll ran, and skim the review
comments to judge whether they are addressable by a worker or need a captain
decision (a design disagreement, a destructive suggestion, scope creep).
Escalate a captain-level call the normal way (`ask-user-authority` if it is an
ask-user-shaped finding, or a plain decision otherwise) rather than dispatching
a worker to adjudicate it.

## File the follow-up work item

The original backlog item already closed Done at PR-open teardown, so this is
new work: file a fresh backlog item for it (section 10) rather than trying to
reopen the closed one.
Note the PR's URL and the original item's recorded delivery mode in the new
item, since `state/<id>.meta` for the original task is gone and the mode is
otherwise only recoverable from that Done record or the PR itself.

## Brief the fresh crewmate

Scaffold with `bin/fm-brief.sh` using the SAME delivery mode as the original
task, then hand-edit two things the scaffold cannot know:

- **Setup**: replace the default `git checkout -b fm/<new-id>` with fetching
  and checking out the PR's EXISTING head branch (`fm/<original-task-id>`, or
  whatever `gh-axi pr view` reports as the head ref) - never create a new
  branch for this task, since it must land on the SAME open PR.
- **Task**: point the worker at the PR's own `## Orientation for follow-up`
  section (`bin/fm-dod-lib.sh`) for design context and where to look first,
  and at the actual review comments and requested changes via `gh-axi`
  (`gh-axi pr view`, review threads, and inline comments) - not at a
  re-explanation of the original task.

Definition of done: address the feedback, push to the SAME branch (updating
the SAME PR, never opening a new one), and report `done:` the same way the
mode's scaffold already expects (`PR {url}` for direct-PR, `PR {url} checks
green` for no-mistakes) - do not run `bin/fm-pr-check.sh` again for this task,
since the original poll is already armed for this exact PR and a second one
would double-report the eventual merge.

## After the fresh crewmate reports done

Tear down exactly as section 7 already directs for any PR-based ship task:
as soon as the push lands, not once it merges.
Nothing else is special about this teardown - the pre-existing poll from the
original task keeps tracking merge on its own, and a further changes-requested
wake on the new head restarts this same playbook.
