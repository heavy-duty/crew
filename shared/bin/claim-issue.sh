#!/usr/bin/env bash
# claim-issue.sh — claim one ready issue without building through a crossed race.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: claim-issue.sh <owner/repo> <issue-number> <login>" >&2
  exit 2
fi

REPO="$1"
NUM="$2"
ME="$3"

issue_json() {
  gh issue view "$NUM" -R "$REPO" --json state,labels,assignees
}

claimable() {
  jq -e '
    .state == "OPEN"
    and ([.labels[].name] | index("ready")) != null
    and ([.labels[].name] | index("claimed")) == null
    and (.assignees | length) == 0
  ' >/dev/null
}

before="$(issue_json)" || {
  echo "$REPO#$NUM: cannot read issue; not claiming" >&2
  exit 1
}
if ! claimable <<<"$before"; then
  echo "$REPO#$NUM: no longer open, ready, unclaimed, and unassigned; not claiming" >&2
  exit 1
fi

if ! gh issue edit "$NUM" -R "$REPO" \
  --add-assignee "$ME" --remove-label ready --add-label claimed >/dev/null; then
  echo "$REPO#$NUM: claim mutation failed" >&2
  exit 1
fi

after="$(issue_json)" || {
  gh issue edit "$NUM" -R "$REPO" --remove-assignee "$ME" >/dev/null 2>&1 || true
  echo "$REPO#$NUM: cannot verify claim; removed only @$ME assignment" >&2
  exit 1
}

if jq -e --arg me "$ME" '
  .state == "OPEN"
  and ([.labels[].name] | index("claimed")) != null
  and ([.labels[].name] | index("ready")) == null
  and ([.assignees[].login] == [$me])
' >/dev/null <<<"$after"; then
  exit 0
fi

gh issue edit "$NUM" -R "$REPO" --remove-assignee "$ME" >/dev/null 2>&1 || true
echo "$REPO#$NUM: crossed claim race; removed only @$ME assignment" >&2
exit 1
