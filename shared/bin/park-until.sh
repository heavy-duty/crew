#!/usr/bin/env bash
# park-until.sh — park a wait with the engine and END the session (#760).
#
#   park-until.sh checks <owner/repo> <pr-number>
#
# For a wait longer than a session should hold open — a check run, a long
# build — the session records what it is waiting for and stops. The engine
# owns the wait from there: the builder's next tick reads every parked wait,
# and the host's tick reads them from the store while the box sleeps; the
# moment the checks conclude the session is dispatched again, resumed, with
# `why=wait#<repo>#<pr>` on its record. Nothing polls inside a session.
#
# The park is a file, `$DUTY_DIR/.wait-<repo>-<pr>`, one line: repo, number,
# the head it was parked at, when. Parking the same wait twice is one park.
set -uo pipefail
DUTY_DIR="${DUTY_DIR:-$HOME/duty}"
what="${1:-}"; repo="${2:-}"; num="${3:-}"
if [ "$what" != checks ] || [ -z "$repo" ] || [ -z "$num" ]; then
  echo "usage: park-until.sh checks <owner/repo> <pr-number>" >&2; exit 2
fi
case "$num" in *[!0-9]*) echo "park-until.sh: <pr-number> must be a number" >&2; exit 2 ;; esac
head="$(gh pr view "$num" -R "$repo" --json headRefOid --jq .headRefOid 2>/dev/null || echo unknown)"
file="$DUTY_DIR/.wait-${repo//\//_}-$num"
printf '%s %s %s %s\n' "$repo" "$num" "$head" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$file.tmp" && mv -f "$file.tmp" "$file"
echo "parked: the engine resumes you when the checks on $repo#$num at $head conclude. End your session now."
