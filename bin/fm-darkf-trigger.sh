#!/usr/bin/env bash
# Trigger dark-factory intake scan on the df-night-shift secondmate.
# Called by system cron hourly. Reads schedule in LOCAL time, converts to UTC for check.
# Usage: fm-darkf-trigger.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# Read schedule config
SCHEDULE="$FM_HOME/config/darkf-schedule"
if [ ! -f "$SCHEDULE" ]; then
  echo "error: $SCHEDULE not found" >&2
  exit 1
fi

START_HOUR=$(grep '^START_HOUR=' "$SCHEDULE" | cut -d= -f2)
END_HOUR=$(grep '^END_HOUR=' "$SCHEDULE" | cut -d= -f2)
TIMEZONE=$(grep '^TIMEZONE=' "$SCHEDULE" | cut -d= -f2)

START_HOUR=${START_HOUR:-0}
END_HOUR=${END_HOUR:-6}
TIMEZONE=${TIMEZONE:-$(date +%Z | tr '[:upper:]' '[:lower:]')}

# Validate hours
if ! [[ "$START_HOUR" =~ ^[0-9]+$ ]] || [ "$START_HOUR" -lt 0 ] || [ "$START_HOUR" -gt 23 ]; then
  echo "error: invalid START_HOUR=$START_HOUR (must be 0-23)" >&2
  exit 1
fi
if ! [[ "$END_HOUR" =~ ^[0-9]+$ ]] || [ "$END_HOUR" -lt 0 ] || [ "$END_HOUR" -gt 23 ]; then
  echo "error: invalid END_HOUR=$END_HOUR (must be 0-23)" >&2
  exit 1
fi

# Convert configured local hours to UTC for comparison
# We need to know: "what UTC hour corresponds to local START_HOUR right now?"
# Use date with TZ to get current UTC hour and current local hour, compute offset
LOCAL_HOUR=$(TZ="$TIMEZONE" date +%H | sed 's/^0*//')
LOCAL_HOUR=${LOCAL_HOUR:-0}
UTC_HOUR=$(date -u +%H | sed 's/^0*//')
UTC_HOUR=${UTC_HOUR:-0}

# Compute offset: UTC_HOUR - LOCAL_HOUR (mod 24)
# This tells us how many hours UTC is ahead of local time
OFFSET=$(( (UTC_HOUR - LOCAL_HOUR + 24) % 24 ))

# Convert schedule to UTC equivalents
UTC_START=$(( (START_HOUR + OFFSET) % 24 ))
UTC_END=$(( (END_HOUR + OFFSET) % 24 ))

# Debug (can be removed or gated by DEBUG=1)
if [ -n "${DEBUG:-}" ]; then
  echo "Local time: $(TZ="$TIMEZONE" date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "UTC time:   $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "Config: START_HOUR=$START_HOUR END_HOUR=$END_HOUR TZ=$TIMEZONE"
  echo "Offset: UTC is +${OFFSET}h from local"
  echo "Schedule in UTC: ${UTC_START}:00-${UTC_END}:00"
  echo "Current UTC hour: $UTC_HOUR"
fi

# Check if current UTC hour is in the window
# Handle midnight crossover in UTC (same logic as before)
if [ "$UTC_START" -lt "$UTC_END" ]; then
  # Same-day window in UTC
  if [ "$UTC_HOUR" -lt "$UTC_START" ] || [ "$UTC_HOUR" -ge "$UTC_END" ]; then
    if [ -n "${DEBUG:-}" ]; then
      echo "outside sleep window (UTC hour $UTC_HOUR not in [$UTC_START, $UTC_END))"
    fi
    exit 0
  fi
else
  # Overnight window in UTC (crosses midnight)
  if [ "$UTC_HOUR" -lt "$UTC_START" ] && [ "$UTC_HOUR" -ge "$UTC_END" ]; then
    if [ -n "${DEBUG:-}" ]; then
      echo "outside sleep window (UTC hour $UTC_HOUR not in [$UTC_START, $UTC_END) overnight)"
    fi
    exit 0
  fi
fi

# Send trigger to secondmate via fm-send
"$FM_ROOT/bin/fm-send.sh" df-night-shift "run intake now" || {
  echo "error: fm-send failed; is df-night-shift secondmate running?" >&2
  exit 1
}

if [ -n "${DEBUG:-}" ]; then
  echo "trigger sent to df-night-shift at UTC hour $UTC_HOUR (local $(TZ="$TIMEZONE" date +%H):00)"
fi
exit 0