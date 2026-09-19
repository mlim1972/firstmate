#!/usr/bin/env bash
# Firstmate fork sync workflow - run from firstmate repo root
#
# Usage:
#   bin/fm-sync-workflow.sh sync-main    # fetch upstream, rebase main, push to origin
#   bin/fm-sync-workflow.sh rebase-mine  # rebase my-changes onto fresh main
#   bin/fm-sync-workflow.sh status       # show branch status

set -euo pipefail

REPO_ROOT="/Users/mlim/Projects/mlim1972/firstmate"
cd "$REPO_ROOT"

case "${1:-status}" in
  sync-main)
    echo "=== Syncing main from upstream ==="
    git checkout main
    git fetch upstream
    git rebase upstream/main
    git push origin main --force-with-lease
    echo "=== main synced ==="
    ;;
  rebase-mine)
    echo "=== Rebasing my-changes onto main ==="
    git checkout my-changes
    git rebase main
    echo "=== my-changes rebased ==="
    ;;
  status)
    echo "=== Branch status ==="
    echo "main:        $(git log --oneline -1 main)"
    echo "upstream/main: $(git log --oneline -1 upstream/main)"
    echo "my-changes:  $(git log --oneline -1 my-changes 2>/dev/null || echo 'branch not found')"
    echo ""
    git status --short --branch
    ;;
  *)
    echo "Usage: $0 {sync-main|rebase-mine|status}"
    exit 1
    ;;
esac