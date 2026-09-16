#!/usr/bin/env bash
# Trigger dark-factory intake scan on the df-night-shift secondmate.
# Called by system cron hourly during sleep window.
# Usage: fm-darkf-trigger.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# Read schedule
SCHEDULE="$FM_HOME/config/darkf-schedule"
if [ ! -f "$SCHEDULE" ]; then
  echo "error: $SCHEDULE not found" >&2
  exit 1
fi
START_HOUR=$(grep '^START_HOUR=' "$SCHEDULE" | cut -d= -f2)
END_HOUR=$(grep '^END_HOUR=' "$SCHEDULE" | cut -d= -f2)
START_HOUR=${START_HOUR:-0}
END_HOUR=${END_HOUR:-6}

# Check current UTC hour
CURRENT_HOUR=$(date -u +%H | sed 's/^0*//')
CURRENT_HOUR=${CURRENT_HOUR:-0}

# Handle midnight crossover (e.g., START_HOUR=22, END_HOUR=7)
if [ "$START_HOUR" -lt "$END_HOUR" ]; then
  # Same-day window: outside if hour < start OR hour >= end
  if [ "$CURRENT_HOUR" -lt "$START_HOUR" ] || [ "$CURRENT_HOUR" -ge "$END_HOUR" ]; then
    echo "outside sleep window (UTC hour $CURRENT_HOUR not in [$START_HOUR, $END_HOUR))"
    exit 0
  fi
else
  # Overnight window (crosses midnight): outside if hour < start AND hour >= end
  # i.e., hour is in the gap between END_HOUR and START_HOUR
  if [ "$CURRENT_HOUR" -lt "$START_HOUR" ] && [ "$CURRENT_HOUR" -ge "$END_HOUR" ]; then
    echo "outside sleep window (UTC hour $CURRENT_HOUR not in [$START_HOUR, $END_HOUR) overnight)"
    exit 0
  fi
fi

# Send trigger to secondmate via fm-send
# This uses the main firstmate's fm-send to route to the secondmate's inbox
"$FM_ROOT/bin/fm-send.sh" df-night-shift "run intake now" || {
  echo "error: fm-send failed; is df-night-shift secondmate running?" >&2
  exit 1
}

echo "trigger sent to df-night-shift at UTC hour $CURRENT_HOUR"
exit 0