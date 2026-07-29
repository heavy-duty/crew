#!/usr/bin/env bash
# Fixture coverage for claim-issue.sh and the builder active-slot decision.
# shellcheck disable=SC1091,SC2034 # runtime-resolved sources; dynamic-scope fixture vars
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SHARED="$(dirname "$HERE")"
PASS=0
FAIL=0

t() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Each invocation gets scripted issue reads and a shared timeline winner.
# Mutations are recorded verbatim so the tests can prove a losing claimant
# touches only itself and repairs the queue only when nobody else remains.
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
calls="${CLAIM_CALLS:?}"
log="${CLAIM_LOG:?}"
if [ "$1 $2" = "issue view" ]; then
  n="$(cat "$calls" 2>/dev/null || echo 0)"
  n=$((n + 1))
  echo "$n" >"$calls"
  case "${CLAIM_MODE:?}:$n" in
    success:1|cross-winner:1|cross-loser:1|orphan-loser:1|verify-fail:1|mutation-fail:1)
      printf '%s\n' '{"state":"OPEN","labels":[{"name":"ready"}],"assignees":[]}' ;;
    success:2)
      printf '%s\n' '{"state":"OPEN","labels":[{"name":"claimed"}],"assignees":[{"login":"bot-a"}]}' ;;
    cross-winner:2|cross-loser:2|orphan-loser:2)
      printf '%s\n' '{"state":"OPEN","labels":[{"name":"claimed"}],"assignees":[{"login":"bot-a"},{"login":"bot-b"}]}' ;;
    cross-loser:3)
      printf '%s\n' '{"state":"OPEN","labels":[{"name":"claimed"}],"assignees":[{"login":"bot-b"}]}' ;;
    orphan-loser:3|verify-fail:3|mutation-fail:2)
      printf '%s\n' '{"state":"OPEN","labels":[{"name":"claimed"}],"assignees":[]}' ;;
    verify-fail:2) exit 1 ;;
    lost:1)
      printf '%s\n' '{"state":"OPEN","labels":[{"name":"claimed"}],"assignees":[{"login":"bot-b"}]}' ;;
    assigned:1)
      printf '%s\n' '{"state":"OPEN","labels":[{"name":"ready"}],"assignees":[{"login":"bot-b"}]}' ;;
    closed:1)
      printf '%s\n' '{"state":"CLOSED","labels":[{"name":"ready"}],"assignees":[]}' ;;
    *) exit 1 ;;
  esac
elif [ "$1 $2" = "issue edit" ]; then
  printf '%s\n' "$*" >>"$log"
  if [ "${CLAIM_MODE:?}" = mutation-fail ] && printf '%s\n' "$*" | grep -q -- '--add-assignee'; then
    exit 1
  fi
elif [ "$1" = api ]; then
  case "${CLAIM_MODE:?}" in
    success|cross-winner)
      printf '%s\n' bot-a ;;
    cross-loser|orphan-loser)
      printf '%s\n' bot-b ;;
    *) exit 1 ;;
  esac
elif [ "$1 $2" = "issue comment" ]; then
  :
else
  exit 1
fi
EOF
chmod +x "$TMP/bin/gh"

run_claim() {
  : >"$TMP/calls"
  : >"$TMP/log"
  CLAIM_MODE="$1" CLAIM_CALLS="$TMP/calls" CLAIM_LOG="$TMP/log" \
    CLAIM_SETTLE_SECONDS=0 PATH="$TMP/bin:$PATH" \
    "$SHARED/bin/claim-issue.sh" o/r 7 bot-a \
    >"$TMP/out" 2>"$TMP/err"
}

run_claim success; rc=$?
t success-rc 0 "$rc"
t success-two-reads 2 "$(cat "$TMP/calls")"
t success-one-mutation 1 "$(wc -l <"$TMP/log" | tr -d ' ')"
t success-adds-self 1 "$(grep -c -- '--add-assignee bot-a' "$TMP/log")"
t success-swaps-labels 1 "$(grep -c -- '--remove-label ready --add-label claimed' "$TMP/log")"

run_claim lost; rc=$?
t selected-loser-rc 1 "$rc"
t selected-loser-one-read 1 "$(cat "$TMP/calls")"
t selected-loser-no-mutation 0 "$(wc -l <"$TMP/log" | tr -d ' ')"

run_claim assigned; rc=$?
t assigned-loser-rc 1 "$rc"
t assigned-loser-no-mutation 0 "$(wc -l <"$TMP/log" | tr -d ' ')"

run_claim cross-winner; rc=$?
t crossed-race-winner-rc 0 "$rc"
t crossed-race-two-reads 2 "$(cat "$TMP/calls")"
t crossed-race-winner-one-mutation 1 "$(wc -l <"$TMP/log" | tr -d ' ')"

run_claim cross-loser; rc=$?
t crossed-race-loser-rc 1 "$rc"
t crossed-race-loser-three-reads 3 "$(cat "$TMP/calls")"
t crossed-race-loser-two-mutations 2 "$(wc -l <"$TMP/log" | tr -d ' ')"
t crossed-race-removes-self 1 "$(grep -c -- '--remove-assignee bot-a' "$TMP/log")"
t crossed-race-never-removes-other 0 "$(grep -c -- '--remove-assignee bot-b' "$TMP/log")"
t crossed-race-keeps-claimed-for-winner 0 "$(grep -c -- '--remove-label claimed --add-label ready' "$TMP/log")"

run_claim orphan-loser; rc=$?
t orphan-loser-rc 1 "$rc"
t orphan-loser-restores-ready 1 "$(grep -c -- '--remove-label claimed --add-label ready' "$TMP/log")"

run_claim verify-fail; rc=$?
t verify-failure-rc 1 "$rc"
t verify-failure-cleans-self 1 "$(grep -c -- '--remove-assignee bot-a' "$TMP/log")"
t verify-failure-restores-ready 1 "$(grep -c -- '--remove-label claimed --add-label ready' "$TMP/log")"

run_claim mutation-fail; rc=$?
t mutation-failure-rc 1 "$rc"
t mutation-failure-cleans-self 1 "$(grep -c -- '--remove-assignee bot-a' "$TMP/log")"
t mutation-failure-restores-ready 1 "$(grep -c -- '--remove-label claimed --add-label ready' "$TMP/log")"

run_claim closed; rc=$?
t closed-issue-rc 1 "$rc"

# Drive the production gate itself. Bash's dynamic scoping lets the helper
# mutate the same locals used by _builder_repo; the fixture then commits the
# exact post-gate set through the production ledger helper.
# shellcheck source=../lib/duty-builder.sh
source "$SHARED/lib/duty-builder.sh"
# shellcheck source=../lib/common.sh
source "$SHARED/lib/common.sh"
log() { :; }

R=o/r
open_pr_count=1
ready_count=1
ready_items='o/r#7 2026-07-29T10:00:00Z'
cr_items='o/r#166 2026-07-29T11:00:00Z'
_gate_ready_for_open_pr; rc=$?
t awaiting-review-occupies-slot 0 "$ready_count"
t awaiting-review-gate-fired 0 "$rc"
GATE_LEDGER="$TMP/gated-seen"
printf '%s\n%s\n' "$ready_items" "$cr_items" | ledger_commit "$GATE_LEDGER"
t gated-ready-absent-from-seen 0 "$(grep -c '^o/r#7 ' "$GATE_LEDGER")"
t owed-round-still-enters-seen 1 "$(grep -c '^o/r#166 ' "$GATE_LEDGER")"

open_pr_count=0
ready_count=1
ready_items='o/r#8 2026-07-29T12:00:00Z'
_gate_ready_for_open_pr; rc=$?
t post-merge-closed-pr-frees-slot 1 "$ready_count"
t post-merge-gate-not-fired 1 "$rc"

echo "claim: passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
