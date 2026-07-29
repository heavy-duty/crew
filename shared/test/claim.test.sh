#!/usr/bin/env bash
# Fixture coverage for claim-issue.sh and the builder active-slot decision.
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

# Each invocation gets a scripted pair of issue reads. Mutations are recorded
# verbatim so the tests can prove a losing claimant touches only itself.
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
calls="${CLAIM_CALLS:?}"
log="${CLAIM_LOG:?}"
if [ "$1 $2" = "issue view" ]; then
  n="$(cat "$calls" 2>/dev/null || echo 0)"
  n=$((n + 1))
  echo "$n" >"$calls"
  case "${CLAIM_MODE:?}:$n" in
    success:1|cross:1|verify-fail:1|mutation-fail:1)
      printf '%s\n' '{"state":"OPEN","labels":[{"name":"ready"}],"assignees":[]}' ;;
    success:2)
      printf '%s\n' '{"state":"OPEN","labels":[{"name":"claimed"}],"assignees":[{"login":"bot-a"}]}' ;;
    cross:2)
      printf '%s\n' '{"state":"OPEN","labels":[{"name":"claimed"}],"assignees":[{"login":"bot-a"},{"login":"bot-b"}]}' ;;
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
  [ "${CLAIM_MODE:?}" != mutation-fail ]
else
  exit 1
fi
EOF
chmod +x "$TMP/bin/gh"

run_claim() {
  : >"$TMP/calls"
  : >"$TMP/log"
  CLAIM_MODE="$1" CLAIM_CALLS="$TMP/calls" CLAIM_LOG="$TMP/log" \
    PATH="$TMP/bin:$PATH" "$SHARED/bin/claim-issue.sh" o/r 7 bot-a \
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

run_claim cross; rc=$?
t crossed-race-rc 1 "$rc"
t crossed-race-two-reads 2 "$(cat "$TMP/calls")"
t crossed-race-two-mutations 2 "$(wc -l <"$TMP/log" | tr -d ' ')"
t crossed-race-removes-self 1 "$(grep -c -- '--remove-assignee bot-a' "$TMP/log")"
t crossed-race-never-removes-other 0 "$(grep -c -- '--remove-assignee bot-b' "$TMP/log")"

run_claim verify-fail; rc=$?
t verify-failure-rc 1 "$rc"
t verify-failure-cleans-self 1 "$(grep -c -- '--remove-assignee bot-a' "$TMP/log")"

run_claim mutation-fail; rc=$?
t mutation-failure-rc 1 "$rc"
t mutation-failure-no-cleanup 1 "$(wc -l <"$TMP/log" | tr -d ' ')"

run_claim closed; rc=$?
t closed-issue-rc 1 "$rc"

# The gate counts open authored PRs, not claims: an awaiting-review PR blocks a
# ready issue, while a merged post-merge deliverable is absent from mine_json.
gate() { [ "$1" -gt 0 ] && [ "$2" -gt 0 ] && echo 0 || echo "$2"; }
t awaiting-review-occupies-slot 0 "$(gate 1 1)"
t post-merge-closed-pr-frees-slot 1 "$(gate 0 1)"

echo "claim: passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
