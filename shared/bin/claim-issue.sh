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

withdraw_self() {
  gh issue edit "$NUM" -R "$REPO" --remove-assignee "$ME" >/dev/null 2>&1 || true
}

restore_ready_if_unowned() {
  local current
  current="$(issue_json)" || return 0
  if jq -e '
    .state == "OPEN"
    and ([.labels[].name] | index("claimed")) != null
    and ([.labels[].name] | index("ready")) == null
    and (.assignees | length) == 0
  ' >/dev/null <<<"$current"; then
    gh issue edit "$NUM" -R "$REPO" \
      --remove-label claimed --add-label ready >/dev/null 2>&1 || true
  fi
}

lose_claim() {
  local winner="${1:-unknown}"
  withdraw_self
  restore_ready_if_unowned
  if [ "$winner" != unknown ]; then
    gh issue comment "$NUM" -R "$REPO" \
      --body "Withdrawing — claim race with @$winner, who claimed first. Releasing to them." \
      >/dev/null 2>&1 || true
  fi
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
  lose_claim
  echo "$REPO#$NUM: claim mutation failed" >&2
  exit 1
fi

# A deterministic tie-break only works after competing writes have had time
# to arrive. Tests set this to zero; production deliberately waits 30 seconds.
sleep "${CLAIM_SETTLE_SECONDS:-30}"

after="$(issue_json)" || {
  lose_claim
  echo "$REPO#$NUM: cannot verify claim; withdrew @$ME and repaired an unowned queue item if visible" >&2
  exit 1
}

if ! jq -e --arg me "$ME" '
  .state == "OPEN"
  and ([.labels[].name] | index("claimed")) != null
  and ([.labels[].name] | index("ready")) == null
  and ([.assignees[].login] | index($me)) != null
' >/dev/null <<<"$after"; then
  lose_claim
  echo "$REPO#$NUM: claim state changed unexpectedly; withdrew @$ME" >&2
  exit 1
fi

winner="$(gh api --paginate "repos/$REPO/issues/$NUM/timeline" \
  --jq '[.[] | select(.event == "assigned" and .assignee.login != null)]
        | sort_by(.created_at, .assignee.login)
        | .[0].assignee.login // empty')" || {
  lose_claim
  echo "$REPO#$NUM: cannot determine claim winner; withdrew @$ME" >&2
  exit 1
}

if [ "$winner" = "$ME" ]; then
  exit 0
fi

lose_claim "${winner:-unknown}"
echo "$REPO#$NUM: crossed claim race; winner is @${winner:-unknown}, withdrew @$ME" >&2
exit 1
