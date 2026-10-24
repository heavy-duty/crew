#!/usr/bin/env bash
# shared/test/common/ledger.sh — standalone suite for shared/lib/common/ledger.sh.
#
# One suite per module at the mirrored relative path: this file covers that one
# and nothing else. The invariant is the layout, not this file (#507).
set -uo pipefail

# ../ : lib.sh lives beside the subject suites, one level up from the module
# tree, and derives HERE from itself so both depths resolve the same paths.
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"
export DUTY_DIR="$TMP"
export HOME="${HOME:-$TMP}"
# shellcheck source=shared/lib/common.sh
source "$SHARED/lib/common.sh"

# --- seen-ledgers: ledger_filter / ledger_commit (the refire fix) ---------
# A wake whose signal is present but UNCHANGED must not re-launch a session;
# it may only wake on new-or-advanced activity. This is what stops the mention
# and held-discussion refire that burned the triage box's Fable quota.
LG="$TMP/ledger"
# cold ledger (first look): everything is new
t ledger-cold 2 "$(printf '111 2026-07-24T19:00:00Z\n222 2026-07-24T19:05:00Z\n' | ledger_filter "$LG" | n)"
printf '111 2026-07-24T19:00:00Z\n222 2026-07-24T19:05:00Z\n' | ledger_commit "$LG"
# same state again: SUPPRESSED (the burn fix)
t ledger-suppress 0 "$(printf '111 2026-07-24T19:00:00Z\n222 2026-07-24T19:05:00Z\n' | ledger_filter "$LG" | n)"
# one timestamp advanced: only that id re-wakes
t ledger-advance "111 2026-07-24T20:30:00Z" "$(printf '111 2026-07-24T20:30:00Z\n222 2026-07-24T19:05:00Z\n' | ledger_filter "$LG")"
# brand-new id wakes
t ledger-newid 1 "$(printf '333 2026-07-25T01:00:00Z\n' | ledger_filter "$LG" | n)"
# commit is monotonic: a stale (older) commit must not lower the mark
printf '111 2026-07-24T20:30:00Z\n' | ledger_commit "$LG"
printf '111 2026-07-01T00:00:00Z\n' | ledger_commit "$LG"
t ledger-monotonic 0 "$(printf '111 2026-07-24T20:30:00Z\n' | ledger_filter "$LG" | n)"
# empty input is safe and preserves the ledger (no session -> nothing to commit)
printf '' | ledger_commit "$LG"
t ledger-empty-safe 0 "$(printf '111 2026-07-24T20:30:00Z\n' | ledger_filter "$LG" | n)"

# cross-repo collision: discussion numbers are PER-REPO but the ledger is one
# file across every repo in repos.txt, so keys must be repo-qualified. After
# committing ceremony#1, an unchanged/older rig#1 must still wake — a bare "1"
# key would shadow it and triage would never see rig's discussion (codex, #16).
LG2="$TMP/ledger-disc"
printf 'heavy-duty/ceremony#1 2026-07-24T19:00:00Z\n' | ledger_commit "$LG2"
t ledger-crossrepo-distinct 1 "$(printf 'heavy-duty/rig#1 2026-07-20T00:00:00Z\n' | ledger_filter "$LG2" | n)"
t ledger-crossrepo-samekey  0 "$(printf 'heavy-duty/ceremony#1 2026-07-24T19:00:00Z\n' | ledger_filter "$LG2" | n)"

# --- ledger_suppressed: the exact inverse of ledger_filter (#59) ------------
# The two must partition the input between them. If they can ever disagree, the
# engine either pays for work it meant to suppress or goes quiet about work it
# meant to report — and the second is the dangerous one.
LG3="$TMP/ledger-inv"
printf 'o/r#1 2026-07-27T10:00:00Z\no/r#2 2026-07-27T10:00:00Z\n' | ledger_commit "$LG3"
IN3="$(printf 'o/r#1 2026-07-27T10:00:00Z\no/r#2 2026-07-27T11:00:00Z\no/r#3 2026-07-27T09:00:00Z\n')"
# #1 unchanged -> suppressed; #2 advanced -> fresh; #3 unseen -> fresh
t suppressed-unchanged "o/r#1 2026-07-27T10:00:00Z" "$(printf '%s\n' "$IN3" | ledger_suppressed "$LG3")"
t suppressed-fresh-count 2 "$(printf '%s\n' "$IN3" | ledger_filter "$LG3" | n)"
# Partition: filter + suppressed together account for every input line, exactly
# once. Asserted rather than assumed — the set-arithmetic version of this that
# I wrote first reported NOTHING suppressed whenever the fresh list was empty.
t suppressed-partitions 3 "$(printf '%s\n' "$IN3" | { ledger_filter "$LG3"; printf '%s\n' "$IN3" | ledger_suppressed "$LG3"; } | n)"
t suppressed-disjoint 0 "$(comm -12 \
  <(printf '%s\n' "$IN3" | ledger_filter "$LG3" | sort) \
  <(printf '%s\n' "$IN3" | ledger_suppressed "$LG3" | sort) | n)"
# A cold ledger hides nothing.
t suppressed-cold 0 "$(printf 'o/r#9 2026-07-27T10:00:00Z\n' | ledger_suppressed "$TMP/nope" | n)"

# --- report_suppressed: stop paying, do NOT stop saying (#59) ---------------
# A ledger converts a burn into silence. An unactioned item is still a live
# board-invariant violation, so the suppressed set has to surface — but at one
# tick per five minutes, a line every tick would bury the log it informs. So:
# warn when the SET CHANGES, and again from scratch after it clears.
ST="$TMP/suppressed-state"
r1="$(printf 'o/r#1 2026-07-27T10:00:00Z\n' | report_suppressed "$ST" "o/r: board")"
case "$r1" in *"1 item(s)"*"o/r#1"*) r2=warned ;; *) r2="$r1" ;; esac
t report-first warned "$r2"
# Same set again: silent.
t report-repeat "" "$(printf 'o/r#1 2026-07-27T10:00:00Z\n' | report_suppressed "$ST" "o/r: board")"
# Set grows: speaks again.
r3="$(printf 'o/r#1 2026-07-27T10:00:00Z\no/r#2 2026-07-27T10:00:00Z\n' | report_suppressed "$ST" "o/r: board")"
case "$r3" in *"2 item(s)"*) r4=warned ;; *) r4="$r3" ;; esac
t report-grew warned "$r4"
# Emptied: silent, and the state file goes, so a recurrence is reported afresh
# rather than being swallowed as "same as last time".
t report-cleared "" "$(printf '' | report_suppressed "$ST" "o/r: board")"
if [ -f "$ST" ]; then r5=kept; else r5=removed; fi
t report-state-removed removed "$r5"
r6="$(printf 'o/r#1 2026-07-27T10:00:00Z\n' | report_suppressed "$ST" "o/r: board")"
case "$r6" in *"1 item(s)"*) r7=warned ;; *) r7="$r6" ;; esac
t report-recurrence-speaks warned "$r7"
# Blank lines are not items and must not render as the malformed `()`.
r8="$(printf '\no/r#1 2026-07-27T10:00:00Z\n' | report_suppressed "$TMP/sup-blank" "review")"
case "$r8" in *'()'*) r9=MALFORMED ;; *) r9=clean ;; esac
t report-blank-line-format clean "$r9"

# An incomplete sweep cannot compare its partial set with the previous complete
# set. Preserve the state byte-for-byte; otherwise one flaky repo makes every
# healthy repo's standing suppression look changed twice (drop + return).
ST_PART="$TMP/sup-partial"
printf 'o/a#1 T1\no/b#1 T1\n' | report_suppressed "$ST_PART" "review" >/dev/null
before_part="$(cat "$ST_PART")"
printf 'o/a#1 T1\n' \
  | report_suppressed_if_complete 0 "$ST_PART" "review" >/dev/null
t report-partial-preserves-state "$before_part" "$(cat "$ST_PART")"
# The next complete steady set remains silent, proving the partial tick did not
# replace the state and manufacture a second warning when repo B returns.
t report-after-partial-still-settled "" \
  "$(printf 'o/a#1 T1\no/b#1 T1\n' \
      | report_suppressed_if_complete 1 "$ST_PART" "review")"

# --- suppression state must be PER REPO (#60 review) ------------------------
# Both duty modules call report_suppressed inside a per-repo loop. With ONE
# shared state file, repo B's set replaces repo A's, and a repo with nothing
# suppressed rm -f's the file outright — so A's unchanged set looks new on the
# next tick and warns again, every tick, on exactly the 3-repo production box
# this was written to protect. codex-bot and grok-bot both caught it; grok-bot
# reproduced the flip-flop with these helpers.
sup_says() { if grep -q 'item(s)'; then echo warned; else echo silent; fi; }
SUP_A='o/a#1 2026-07-27T10:00:00Z'
SUP_B='o/b#1 2026-07-27T10:00:00Z'

# Per-repo files: each repo settles independently and stays quiet.
STA="$TMP/sup.o_a"; STB="$TMP/sup.o_b"
printf '%s\n' "$SUP_A" | report_suppressed "$STA" "o/a: board" >/dev/null
printf '%s\n' "$SUP_B" | report_suppressed "$STB" "o/b: board" >/dev/null
t report-perrepo-a-settles silent "$(printf '%s\n' "$SUP_A" | report_suppressed "$STA" "o/a: board" | sup_says)"
t report-perrepo-b-settles silent "$(printf '%s\n' "$SUP_B" | report_suppressed "$STB" "o/b: board" | sup_says)"

# The shape that was wrong, kept as a negative control: sharing one file makes
# A speak again after B has been through it. If this ever reads `silent` the
# helper has changed and the per-repo keying above may no longer be load-bearing.
SUP_SHARED="$TMP/sup.shared"
printf '%s\n' "$SUP_A" | report_suppressed "$SUP_SHARED" "o/a: board" >/dev/null
printf '%s\n' "$SUP_B" | report_suppressed "$SUP_SHARED" "o/b: board" >/dev/null
t report-shared-state-refires warned "$(printf '%s\n' "$SUP_A" | report_suppressed "$SUP_SHARED" "o/a: board" | sup_says)"

# ...and the modules must actually key by repo, not just be capable of it.
for pair in "duty-triage.sh:suppressed-triage-board" "duty-builder.sh:suppressed-build"; do
  mod="${pair%%:*}"; sfile="${pair##*:}"
  if grep -qE "$sfile\.\\\$\{?(R|slug)" "$SHARED/lib/$mod"; then r1=perrepo; else r1=SHARED; fi
  t "suppression-state-perrepo-$mod" perrepo "$r1"
done

# --- every state signal is ledgered (#59) -----------------------------------
# The engine had TWO ledgers, both in triage, while builder and reviewer had
# none — so any signal cleared by an in-session action the agent may DECLINE
# re-fired a model session every tick forever. These pin the wiring: a new
# signal site added without a ledger is the regression.
for pair in "duty-triage.sh:.seen-triage-board" "duty-builder.sh:.seen-build" \
            "duty-review.sh:.seen-review" "duty-attention.sh:.seen-attention"; do
  mod="${pair%%:*}"; led="${pair##*:}"
  if grep -q "$led" "$SHARED/lib/$mod"; then r1=ledgered; else r1=UNGUARDED; fi
  t "signal-ledgered-$mod" ledgered "$r1"
  # ...and committed only after a session that actually completed.
  if grep -q 'RUN_SESSION_RC:-1}" -eq 0' "$SHARED/lib/$mod"; then r1=gated; else r1=UNGATED; fi
  t "ledger-commit-gated-$mod" gated "$r1"
  # ...and what it hides must be reported.
  if grep -q 'report_suppressed' "$SHARED/lib/$mod"; then r1=reported; else r1=SILENT; fi
  t "suppression-reported-$mod" reported "$r1"
done

# --- the fourth session shape: a session that died with its box (#478) -------
#
# run_session writes SESSION END on every path its own process survives. A
# session killed WITH the box survives none of them, so duty.log keeps a start
# nothing answers and every reader counts it as still running. These drive the
# reconciler over fixture logs, appending its output to the log it read exactly
# as tick.sh appends duty.sh's stdout — which is what makes the second pass
# below a real second pass rather than a re-read.

ORPH_BOOT="$(_session_boot_id)"
# A pid that is certainly not running: a child, reaped. Asserted rather than
# assumed. If this box ever handed the pid straight back out, every case below
# would read `live` and red for a reason that has nothing to do with the
# reconciler, so the fixture states its own precondition first.
: & ORPH_DEAD=$!
wait "$ORPH_DEAD" 2>/dev/null
if kill -0 "$ORPH_DEAD" 2>/dev/null; then r1=STILL-LIVE; else r1=dead; fi
t orphan-fixture-dead-pid-is-dead dead "$r1"

orph_fixture() { mkdir -p "$1/logs"; : >"$1/duty.log"; }

orph_start() {  # orph_start <dir> <ts> <kind> <key> <holder>
  printf '%s SESSION START kind=%s key=%s timeout=7200s log=%s/logs/%s.log%s\n' \
    "$2" "$3" "$4" "$1" "$3" "${5:+ holder=$5}" >>"$1/duty.log"
}

orph_end() {  # orph_end <dir> <ts> <kind> <key>
  printf '%s SESSION END kind=%s key=%s rc=0 dur=12s outcome=ok acted=yes reply_tail=\n' \
    "$2" "$3" "$4" >>"$1/duty.log"
}

# orph_pass <dir> [mutant] — one reconciler pass. `alert` is captured rather
# than sent; everything else is the library.
#
# Stdout goes where tick.sh sends duty.sh's — into duty.log — because that is
# the shape a real tick has, and $ORPH_STDOUT overrides it for the cases that
# drive a HAND run. The redirect no longer delivers the reconciler's answer:
# the module appends the reconstructed terminal to the log by path, and what
# stdout carries here is only the human-facing summary. That is the whole point
# of the override below — with the answer riding stdout, `orph_pass` was wiring
# for the function the very contract under test.
# shellcheck disable=SC2317  # alert is reached from inside the library
orph_pass() (
  local dir="$1" mutant="${2:-}" alerts="$1/alerts" out="${ORPH_STDOUT:-$1/duty.log}"
  DUTY_DIR="$dir"; LOG_DIR="$dir/logs"; DUTY_TICK_ID='tick-orphan'
  SESSION_TERMINAL_THRESHOLD=3
  alert() { printf '%s\n' "$*" >>"$alerts"; }
  # shellcheck disable=SC1090
  [ -z "$mutant" ] || source "$mutant"
  session_reconcile_orphans >>"$out" 2>&1
)

orph_lines() { grep -F "outcome=$SESSION_ORPHAN_OUTCOME" "$1/duty.log" || true; }
orph_count() { orph_lines "$1" | n; }
orph_kv() { sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<<"$1"; }

# orph_mutant <name> <sed-expr> [source] — write a mutated source copy to
# $TMP/ledger-mutant-<name>.sh, and assert the sed BIT. The optional source is
# what lets the parity probes mutate both SESSION END emitters through the same
# guarded helper. A probe that silently matched nothing would run production
# code and report a kill it never made.
#
# The path is derived by the caller rather than printed here, and that is not a
# style choice: `$(orph_mutant …)` would run this in a subshell, where the `t`
# below increments a FAIL nobody ever reads and prints its diagnosis into the
# captured path. An inert probe would then be inert AND silent.
orph_mutant() {
  local name="$1" expr="$2" source="${3:-$SHARED/lib/common/ledger.sh}"
  local out="$TMP/ledger-mutant-$1.sh" applied
  sed "$expr" "$source" >"$out"
  if cmp -s "$out" "$source"; then applied=INERT; else applied=applied; fi
  t "orphan-mutation-$name-applies" applied "$applied"
}

# Read the field names from an emitter's own SESSION END source line. A suffix
# variable is resolved through the helper assigned to it, so an appender cannot
# evade parity merely by interpolating a pre-built string (#475). Neither side
# is listed here: adding a field to run_session must red until the reconstructed
# emitter gains it too, including fields nobody anticipated when this guard was
# written.
session_end_tokens() {
  local source="$1" line var helper
  line="$(sed -n '/^[[:space:]]*log "SESSION END / { p; q; }' "$source")"
  {
    printf '%s\n' "$line" \
      | grep -oE '(^| )[[:alpha:]_][[:alnum:]_]*=' \
      | tr -d ' ='
    while IFS= read -r var; do
      helper="$(awk -v v="$var" '
        {
          line = $0
          sub(/^[[:space:]]*/, "", line)
          prefix = v "=\"$("
          if (index(line, prefix) == 1) {
            line = substr(line, length(prefix) + 1)
            sub(/[)[:space:]\"].*$/, "", line)
            print line
            exit
          }
        }
      ' "$source")"
      [ -n "$helper" ] || continue
      awk -v sig="$helper() {" '
        $0 == sig { body = 1 }
        body { print }
        body && /^}/ { exit }
      ' "$source" \
        | grep -oE "(^|[\"']) [[:alpha:]_][[:alnum:]_]*=" \
        | tr -d "\"' ="
    done < <(printf '%s\n' "$line" \
      | grep -oE '\$[[:alpha:]_][[:alnum:]_]*' \
      | tr -d '$' \
      | awk '!seen[$0]++')
  } | awk '!seen[$0]++'
}

session_end_missing() {
  comm -23 \
    <(session_end_tokens "$1" | sort -u) \
    <(session_end_tokens "$2" | sort -u)
}

session_end_order_mismatch() {
  awk '
    NR == FNR { observed[++n] = $0; wanted[$0] = 1; next }
    $0 in wanted { reconstructed[++m] = $0 }
    END {
      for (i = 1; i <= n; i++) {
        if (observed[i] != reconstructed[i]) print observed[i]
      }
    }
  ' <(session_end_tokens "$1") <(session_end_tokens "$2")
}

# The three shapes the test plan names, in one log: an orphaned start, a
# live-held start, and a well-formed pair. Exactly one reconstruction is owed.
#
# Interleaved with what a real duty.log is mostly made of — tick markers, a
# WARN, and a SESSION SKIP. The SKIP is the one that has to be got right on
# purpose: it names the same kind and key as a start and is not an end, so a
# scanner reading "a SESSION line mentioning this key" instead of the two
# verbs would silently answer the orphan with it.
ORPH1="$TMP/orphan-basic"; orph_fixture "$ORPH1"
{
  printf '2026-08-14T03:00:00Z duty run start\n'
} >>"$ORPH1/duty.log"
orph_start "$ORPH1" 2026-08-14T03:00:01Z build  o/r#1  "$ORPH_DEAD.$ORPH_BOOT"
{
  printf '2026-08-14T03:05:00Z duty run start\n'
  printf '2026-08-14T03:05:00Z SESSION SKIP kind=build key=o/r#1 reason=budget over=sessions\n'
  printf '2026-08-14T03:05:00Z WARN: session budget: kind=build reached its ceiling\n'
} >>"$ORPH1/duty.log"
orph_start "$ORPH1" 2026-08-14T03:05:01Z review o/r#2  "$$.$ORPH_BOOT"
orph_start "$ORPH1" 2026-08-14T03:10:00Z triage board  "$ORPH_DEAD.$ORPH_BOOT"
orph_end   "$ORPH1" 2026-08-14T03:12:00Z triage board
orph_pass "$ORPH1"
ORPH1_LINE="$(orph_lines "$ORPH1")"

t orphan-reconciles-exactly-one 1 "$(orph_count "$ORPH1")"
t orphan-closes-the-dead-session "build|o/r#1" \
  "$(orph_kv "$ORPH1_LINE" kind)|$(orph_kv "$ORPH1_LINE" key)"
# The other half of D1, and the one an age threshold gets wrong: a build may
# legitimately run for two hours, so the live-held start must survive a
# reconciler that has no idea how old it is.
t orphan-live-holder-untouched 0 \
  "$(grep -cF "kind=review key=o/r#2 rc=- dur=- outcome=$SESSION_ORPHAN_OUTCOME" \
      "$ORPH1/duty.log" || true)"
t orphan-complete-pair-untouched 0 \
  "$(grep -cF "kind=triage key=board rc=- dur=- outcome=$SESSION_ORPHAN_OUTCOME" \
      "$ORPH1/duty.log" || true)"

# D2. The reconciler knows the session started and knows nobody is running it;
# it knows nothing whatever about how the session exited or how long it took.
t orphan-claims-no-rc  '-' "$(orph_kv "$ORPH1_LINE" rc)"
t orphan-claims-no-dur '-' "$(orph_kv "$ORPH1_LINE" dur)"
t orphan-names-the-start-it-answers 2026-08-14T03:00:01Z \
  "$(orph_kv "$ORPH1_LINE" started)"
t orphan-acted-is-unknown-not-no unknown "$(orph_kv "$ORPH1_LINE" acted)"
t orphan-tier-is-unknown-not-default unknown "$(orph_kv "$ORPH1_LINE" tier)"
t orphan-input-tokens-is-unmeasured '-' "$(orph_kv "$ORPH1_LINE" input_tokens)"
t orphan-output-tokens-is-unmeasured '-' "$(orph_kv "$ORPH1_LINE" output_tokens)"
t orphan-cache-creation-is-unmeasured '-' \
  "$(orph_kv "$ORPH1_LINE" cache_creation_input_tokens)"
t orphan-cache-read-is-unmeasured '-' \
  "$(orph_kv "$ORPH1_LINE" cache_read_input_tokens)"
t orphan-cost-is-unmeasured '-' "$(orph_kv "$ORPH1_LINE" cost_usd)"
t orphan-session-id-is-unknown unknown "$(orph_kv "$ORPH1_LINE" session_id)"
t orphan-model-is-unknown unknown "$(orph_kv "$ORPH1_LINE" model)"
t orphan-model-count-is-unmeasured '-' "$(orph_kv "$ORPH1_LINE" models)"
t orphan-pool-is-unknown unknown "$(orph_kv "$ORPH1_LINE" pool)"
# The parity guard below requires the token; only this requires its VALUE, and
# the two failure directions differ. `-` here would claim the reconciler was
# owed a transcript id and lost it with the box; `unknown` says it never held
# one, which is true — a resume stub is written only by the session that minted
# the id, so a reconstructed line naming one would name a transcript nothing
# can open. The space-anchored read is what keeps this off `session_id=`.
t orphan-sid-is-unknown unknown "$(orph_kv "$ORPH1_LINE" sid)"
# `started=` is this writer's own field and sits past every OBSERVED one — that
# is what this assertion has always been protecting, and it is why it was
# written as "stays last" while this writer was the only one appending. `sid=`
# now sits after it, so the two halves are pinned apart: `started=` past the
# last observed token, and `sid=` last on the line, which is #538's first
# criterion holding on BOTH emitters rather than on `run_session`'s alone.
case "$ORPH1_LINE" in
  *' pool=unknown started=2026-08-14T03:00:01Z'*) r1=past-every-observed ;;
  *) r1=MOVED ;;
esac
t orphan-started-sits-past-every-observed-field past-every-observed "$r1"
case "$ORPH1_LINE" in *' sid=unknown') r1=last ;; *) r1=NOT-LAST ;; esac
t orphan-sid-stays-last last "$r1"
# D1/D3. Token parity is source-derived on both sides; this is the standing
# guard that makes the next observed field fail on the PR that adds it.
t orphan-session-end-token-parity '' \
  "$(session_end_missing "$SHARED/lib/common/session.sh" "$SHARED/lib/common/ledger.sh")"
t orphan-session-end-token-order '' \
  "$(session_end_order_mismatch "$SHARED/lib/common/session.sh" "$SHARED/lib/common/ledger.sh")"
# "Distinguishable by its outcome ALONE" is a claim about the token, not about
# the rest of the line: no verdict run_session can reach may spell it. Read off
# session.sh's own assignments so a fourth observed verdict added there without
# a thought for this one reds here.
t orphan-outcome-is-no-observed-verdict 0 \
  "$(grep -c "verdict=$SESSION_ORPHAN_OUTCOME" "$SHARED/lib/common/session.sh" || true)"

# AC5. The reconstructed terminal answers the start, so a second tick finds
# nothing owed — and it does so without the reconstructed line becoming a
# read-back bound, which is what D4 words as "newest OBSERVED".
orph_pass "$ORPH1"
t orphan-second-pass-adds-nothing 1 "$(orph_count "$ORPH1")"

# D4. A kind's newest observed terminal is where its history is settled, and
# nothing at or before it is read again. The start below that line is older
# than the bound and stays open; the one above it is reconciled.
ORPH2="$TMP/orphan-bound"; orph_fixture "$ORPH2"
orph_start "$ORPH2" 2026-08-14T01:00:00Z build o/r#7 "$ORPH_DEAD.$ORPH_BOOT"
orph_end   "$ORPH2" 2026-08-14T02:00:00Z build o/r#8
orph_start "$ORPH2" 2026-08-14T03:00:00Z build o/r#9 "$ORPH_DEAD.$ORPH_BOOT"
orph_pass "$ORPH2"
t orphan-bounded-read-back-reconciles-one 1 "$(orph_count "$ORPH2")"
t orphan-bounded-read-back-stops-at-the-newest-observed-end o/r#9 \
  "$(orph_kv "$(orph_lines "$ORPH2")" key)"

# The boot qualifier does the work the pid cannot. This holder's pid is THIS
# process — as live as a pid gets — and the session is still correctly read as
# gone, because it was dispatched on a boot that has ended.
ORPH3="$TMP/orphan-reboot"; orph_fixture "$ORPH3"
orph_start "$ORPH3" 2026-08-14T04:00:00Z build o/r#3 "$$.0000dead"
orph_pass "$ORPH3"
t orphan-previous-boot-is-gone-though-the-pid-lives 1 "$(orph_count "$ORPH3")"

# A start carrying no holder cannot be asked the question, and D1 requires both
# halves — so it is left open rather than answered on a guess. That covers both
# an engine older than this reconciler and the floor's own `operator` sessions,
# which fleet-floor/server/floor/actions.py writes into duty.log by hand.
ORPH4="$TMP/orphan-holderless"; orph_fixture "$ORPH4"
orph_start "$ORPH4" 2026-08-14T05:00:00Z operator floor ''
orph_pass "$ORPH4"
t orphan-holderless-start-is-never-answered 0 "$(orph_count "$ORPH4")"
# ...and it is the emptiness check that spares it, not something downstream of
# a guard that never fired. The record used to be tab-separated, and tab is IFS
# *whitespace*: `IFS=$'\t' read` collapsed the run of separators, so `log=` bound
# to `holder`, `holder` was never empty, and what actually spared the line was
# _session_holder_live's non-numeric-pid fallback (claude-bot, round 1). The
# outcome was right for a reason the comment did not claim. Assert the FIELD
# BINDING, so the guard has a case that dies with it.
ORPH4_REC="$(_session_orphan_scan "$ORPH4/duty.log")"
IFS=$'\037' read -r o4_kind o4_key o4_holder o4_log o4_started <<<"$ORPH4_REC"
t orphan-holderless-record-keeps-its-empty-field \
  "operator|floor||$ORPH4/logs/operator.log|2026-08-14T05:00:00Z" \
  "$o4_kind|$o4_key|$o4_holder|$o4_log|$o4_started"

# AC4/D3. Three box-kills on one lane over three ticks trip that lane's
# breaker, through the counter an observed TERMINAL already feeds and no second
# mechanism. Driven as three passes rather than one log carrying three orphans,
# because that is the shape the incident has: a box that kills itself, comes
# back, and does it again.
ORPH5="$TMP/orphan-breaker"; orph_fixture "$ORPH5"
for i in 1 2 3; do
  orph_start "$ORPH5" "2026-08-14T0$i:00:00Z" build "o/r#$i" "$ORPH_DEAD.$ORPH_BOOT"
  orph_pass "$ORPH5"
done
t orphan-breaker-counts-three 3 "$(orph_count "$ORPH5")"
t orphan-breaker-trips-the-kind tripped \
  "$(cut -f2 <"$ORPH5/.session-terminal.build" 2>/dev/null || echo NONE)"
t orphan-breaker-alerts-once 1 "$([ -e "$ORPH5/alerts" ] && wc -l <"$ORPH5/alerts" || echo 0)"
# ...and only that kind. A box that dies under review must not silence build.
t orphan-breaker-spares-other-kinds absent \
  "$([ -e "$ORPH5/.session-terminal.review" ] && echo PRESENT || echo absent)"
# A fourth tick with nothing new neither reconstructs nor counts, so the
# threshold measures box-kills and not reconciler passes.
orph_pass "$ORPH5"
t orphan-idle-pass-does-not-count 3 "$(cut -f1 <"$ORPH5/.session-terminal.build")"
# ...and the trip it produced is marked as one the vendor did not cause (#551),
# which is this file's half of that issue: D3's COUNT is unchanged and the
# CLEAR is not. A box-kill falsifies nothing about the vendor, so the state
# this caller writes must be the kind a succeeding `bot_cli_probe` cannot
# clear — and this assertion is what makes that a property of the reconciler's
# call rather than of the breaker's default.
t orphan-breaker-trip-is-marked-non-vendor yes \
  "$(cut -f4 <"$ORPH5/.session-terminal.build" 2>/dev/null || echo NONE)"
orph5_probe_holds="$(
  (
    DUTY_DIR="$ORPH5"; DUTY_TICK_ID="orphan-probe-tick"
    bot_cli_probe() { return 0; }
    if _session_terminal_gate build o/r#9 >/dev/null 2>&1; then
      printf CLEARED
    else
      printf held
    fi
  )
)"
t orphan-breaker-trip-survives-a-succeeding-probe held "$orph5_probe_holds"

# ...and that holds for callers who do NOT redirect stdout into duty.log, which
# is the qualification the case above used to carry silently (claude-bot, round
# 1). The reconciler reads the log by path and its side effect — the breaker's
# counter — is written by path too, so the answering line must land by path as
# well or the two disagree. duty.sh is a supported hand-run target: its own
# flock and 199 sentinel at duty.sh:24-40 exist for exactly that path, and on
# it stdout is a terminal. Answering to stdout there would count a single
# box-kill again on every run and discard D2's evidence line to a tty.
ORPH_STDOUT=/dev/null
ORPHU="$TMP/orphan-unredirected"; orph_fixture "$ORPHU"
orph_start "$ORPHU" 2026-08-14T10:00:00Z build o/r#10 "$ORPH_DEAD.$ORPH_BOOT"
orph_pass "$ORPHU"
orph_pass "$ORPHU"
ORPH_STDOUT=
t orphan-answers-the-log-not-the-callers-stdout 1 "$(orph_count "$ORPHU")"
t orphan-unredirected-counts-one-box-kill 1 \
  "$(cut -f1 <"$ORPHU/.session-terminal.build" 2>/dev/null || echo NONE)"

# --- the three must-fail cases, each run against its own mutation ------------
#
# A case that cannot red under the defect it names proves nothing, so each of
# the test plan's three is re-driven here with the module mutated to reintroduce
# exactly that defect, and the case must come out the other way.

# Must fail: reconciling a live session.
# shellcheck disable=SC2016  # the sed matches the module's literal $pid
orph_mutant live 's/^  kill -0 "\$pid" 2>\/dev\/null$/  return 1/'
ORPH_M1="$TMP/ledger-mutant-live.sh"
ORPH6="$TMP/orphan-mut-live"; orph_fixture "$ORPH6"
orph_start "$ORPH6" 2026-08-14T06:00:00Z review o/r#2 "$$.$ORPH_BOOT"
orph_pass "$ORPH6" "$ORPH_M1"
t orphan-mutation-live-reconciles-a-running-session 1 "$(orph_count "$ORPH6")"

# Must fail: a reconstructed line carrying a fabricated dur.
orph_mutant dur 's/rc=- dur=-/rc=0 dur=0s/'
ORPH_M2="$TMP/ledger-mutant-dur.sh"
ORPH7="$TMP/orphan-mut-dur"; orph_fixture "$ORPH7"
orph_start "$ORPH7" 2026-08-14T07:00:00Z build o/r#4 "$ORPH_DEAD.$ORPH_BOOT"
orph_pass "$ORPH7" "$ORPH_M2"
t orphan-mutation-dur-fabricates-a-measurement 0s "$(orph_kv "$(orph_lines "$ORPH7")" dur)"

# Must fail: double reconciliation on a second tick. The defect is a scanner
# that does not accept its OWN reconstructed terminal as the start's answer.
orph_mutant double \
  's/if (depth\[q\] > 0) { delete open/if (f["outcome"] != ORPHAN \&\& depth[q] > 0) { delete open/'
ORPH_M3="$TMP/ledger-mutant-double.sh"
ORPH8="$TMP/orphan-mut-double"; orph_fixture "$ORPH8"
orph_start "$ORPH8" 2026-08-14T08:00:00Z build o/r#5 "$ORPH_DEAD.$ORPH_BOOT"
orph_pass "$ORPH8" "$ORPH_M3"
orph_pass "$ORPH8" "$ORPH_M3"
t orphan-mutation-double-reconciles-twice 2 "$(orph_count "$ORPH8")"

# Must fail: the answer written to the caller's stdout instead of to the log
# the scan read. Round 1's blocking finding, given the same treatment as the
# other three — the case that pins it is worth nothing unless it reds under the
# defect it names. Stdout goes to /dev/null, as it effectively does on a hand
# run of duty.sh, and the two passes below are two separate box-kill counts of
# one box-kill.
# shellcheck disable=SC2016  # the sed matches the module's literal $logfile
orph_mutant stdout 's/" >>"\$logfile"$/"/'
ORPH_M4="$TMP/ledger-mutant-stdout.sh"
ORPH10="$TMP/orphan-mut-stdout"; orph_fixture "$ORPH10"
orph_start "$ORPH10" 2026-08-14T11:00:00Z build o/r#11 "$ORPH_DEAD.$ORPH_BOOT"
ORPH_STDOUT=/dev/null
orph_pass "$ORPH10" "$ORPH_M4"
orph_pass "$ORPH10" "$ORPH_M4"
ORPH_STDOUT=
t orphan-mutation-stdout-loses-the-answer 0 "$(orph_count "$ORPH10")"
t orphan-mutation-stdout-recounts-one-box-kill 2 \
  "$(cut -f1 <"$ORPH10/.session-terminal.build" 2>/dev/null || echo NONE)"

# Must fail: the record separator back to a tab, which is IFS whitespace. Both
# `037`s go — the scan's OFS and the reader's IFS — because the defect is the
# two of them agreeing on a separator that collapses. Read the holderless
# record the way the mutant's own reader would, and watch `log=` bind to
# `holder`: that is the shift that made the emptiness guard unreachable.
orph_mutant tab 's/037/t/g'
ORPH_M5="$TMP/ledger-mutant-tab.sh"
# shellcheck disable=SC1090
ORPH4_TAB="$(source "$ORPH_M5" >/dev/null 2>&1; _session_orphan_scan "$ORPH4/duty.log")"
# shellcheck disable=SC2034  # m4_rest is the tail the shift produced, not read
IFS=$'\t' read -r m4_kind m4_key m4_holder m4_rest <<<"$ORPH4_TAB"
t orphan-mutation-tab-shifts-log-into-holder \
  "operator|floor|$ORPH4/logs/operator.log" "$m4_kind|$m4_key|$m4_holder"

# Must fail: an observed field added without its reconstructed peer. Mutating
# session.sh proves the observed token set is read from source, not hard-coded.
#
# It inserts after `tier=` rather than at the end of the line, and that is not
# cosmetic: #473 appended `peak_rss=` past the tier, so an expression anchored
# on the closing quote went INERT the moment the field it was written to
# anticipate actually arrived — a probe that matches nothing asserts nothing,
# and this pair only says what it claims while both mutations still apply.
# shellcheck disable=SC2016  # the sed matches the source's literal variable
orph_mutant observed-field \
  's/ tier=$_SESSION_TIER/ tier=$_SESSION_TIER future=known/' \
  "$SHARED/lib/common/session.sh"
ORPH_M6="$TMP/ledger-mutant-observed-field.sh"
t orphan-parity-reads-observed-source future \
  "$(session_end_missing "$ORPH_M6" "$SHARED/lib/common/ledger.sh")"

# The observed emitter appends pool through `$pool_suffix`, not as literal text
# on its SESSION END line. Mutating that helper proves the guard follows the
# interpolation rather than certifying only fields a grep sees directly.
orph_mutant indirect-field \
  "s/printf ' pool=%s'/printf ' indirect=known pool=%s'/" \
  "$SHARED/lib/common/session.sh"
ORPH_M11="$TMP/ledger-mutant-indirect-field.sh"
t orphan-parity-resolves-indirect-observed-source indirect \
  "$(session_end_missing "$ORPH_M11" "$SHARED/lib/common/ledger.sh")"

# D7's two indirectly appended fields must stay visible to the same guard.
# Dropping both reconstructed peers proves neither model token is copied into
# the comparison as a list maintained beside the emitters.
orph_mutant model-fields-missing \
  's/ model=unknown models=- why=- pool=unknown/ why=- pool=unknown/'
ORPH_M13="$TMP/ledger-mutant-model-fields-missing.sh"
t orphan-parity-reads-indirect-model-fields $'model\nmodels' \
  "$(session_end_missing "$SHARED/lib/common/session.sh" "$ORPH_M13")"

# Must fail: dropping tier from the reconstructed source. This is the inverse
# mutation, proving that side is derived too rather than copied from a list in
# the guard.
orph_mutant tier-missing 's/ tier=unknown peak_rss=-/ peak_rss=-/'
ORPH_M7="$TMP/ledger-mutant-tier-missing.sh"
t orphan-parity-reads-reconstructed-source tier \
  "$(session_end_missing "$SHARED/lib/common/session.sh" "$ORPH_M7")"
ORPH11="$TMP/orphan-mut-tier-missing"; orph_fixture "$ORPH11"
orph_start "$ORPH11" 2026-08-14T12:00:00Z build o/r#12 "$ORPH_DEAD.$ORPH_BOOT"
orph_pass "$ORPH11" "$ORPH_M7"
t orphan-mutation-tier-missing-has-no-value '' \
  "$(orph_kv "$(orph_lines "$ORPH11")" tier)"

# The same pair for #473's field, which is the first one to arrive since this
# guard was written and so the first evidence that it does what it was minted
# for. `-` and not an absent token: the observed emitter OMITS peak_rss where
# it got no reading, because there the absence carries information; here every
# line is unmeasured by construction, so an absence would say nothing and the
# numeric convention this file already uses for rc and dur says the right
# thing — owed, and lost with the box.
t orphan-peak-rss-is-owed-not-absent '-' "$(orph_kv "$ORPH1_LINE" peak_rss)"
orph_mutant peak-missing 's/ peak_rss=- oom=- input_tokens=-/ oom=- input_tokens=-/'
ORPH_M9="$TMP/ledger-mutant-peak-missing.sh"
t orphan-parity-reads-peak-rss peak_rss \
  "$(session_end_missing "$SHARED/lib/common/session.sh" "$ORPH_M9")"
ORPH13="$TMP/orphan-mut-peak-missing"; orph_fixture "$ORPH13"
orph_start "$ORPH13" 2026-08-14T14:00:00Z build o/r#14 "$ORPH_DEAD.$ORPH_BOOT"
orph_pass "$ORPH13" "$ORPH_M9"
t orphan-mutation-peak-missing-has-no-value '' \
  "$(orph_kv "$(orph_lines "$ORPH13")" peak_rss)"

# #600's numeric OOM delta is equally unknowable after the box dies. Keep its
# unknown marker immediately after peak_rss, and prove deleting it trips both
# source-derived guards rather than only the membership half.
t orphan-oom-is-owed-not-zero '-' "$(orph_kv "$ORPH1_LINE" oom)"
orph_mutant oom-missing 's/ peak_rss=- oom=- input_tokens=-/ peak_rss=- input_tokens=-/'
ORPH_M14="$TMP/ledger-mutant-oom-missing.sh"
t orphan-parity-reads-oom oom \
  "$(session_end_missing "$SHARED/lib/common/session.sh" "$ORPH_M14")"
t orphan-order-reads-oom-removal oom \
  "$(session_end_order_mismatch "$SHARED/lib/common/session.sh" "$ORPH_M14" | head -1)"
ORPH15="$TMP/orphan-mut-oom-missing"; orph_fixture "$ORPH15"
orph_start "$ORPH15" 2026-08-14T16:00:00Z build o/r#16 "$ORPH_DEAD.$ORPH_BOOT"
orph_pass "$ORPH15" "$ORPH_M14"
t orphan-mutation-oom-missing-has-no-value '' \
  "$(orph_kv "$(orph_lines "$ORPH15")" oom)"

# D1 is order as well as membership. Swap two reconstructed accounting fields
# and require the source-derived comparison to name both displaced tokens.
orph_mutant usage-order \
  's/input_tokens=- output_tokens=-/output_tokens=- input_tokens=-/'
ORPH_M12="$TMP/ledger-mutant-usage-order.sh"
t orphan-parity-preserves-observed-order $'input_tokens\noutput_tokens' \
  "$(session_end_order_mismatch "$SHARED/lib/common/session.sh" "$ORPH_M12")"

# Must fail: `0` claims a measurement the dead session never reported — the
# same fabrication as tier=default, in the units the floor renders.
orph_mutant peak-zero 's/peak_rss=-/peak_rss=0/'
ORPH_M10="$TMP/ledger-mutant-peak-zero.sh"
ORPH14="$TMP/orphan-mut-peak-zero"; orph_fixture "$ORPH14"
orph_start "$ORPH14" 2026-08-14T15:00:00Z build o/r#15 "$ORPH_DEAD.$ORPH_BOOT"
orph_pass "$ORPH14" "$ORPH_M10"
t orphan-mutation-peak-zero-fabricates-a-measurement 0 \
  "$(orph_kv "$(orph_lines "$ORPH14")" peak_rss)"

# Must fail: `default` claims a measurement the dead session never reported.
orph_mutant tier-default 's/tier=unknown/tier=default/'
ORPH_M8="$TMP/ledger-mutant-tier-default.sh"
ORPH12="$TMP/orphan-mut-tier-default"; orph_fixture "$ORPH12"
orph_start "$ORPH12" 2026-08-14T13:00:00Z build o/r#13 "$ORPH_DEAD.$ORPH_BOOT"
orph_pass "$ORPH12" "$ORPH_M8"
t orphan-mutation-tier-default-fabricates-a-measurement default \
  "$(orph_kv "$(orph_lines "$ORPH12")" tier)"

# --- the wiring, which no fixture above can reach ---------------------------
# The reconciler is worth nothing unless a tick calls it, and it must be called
# before any dispatch: that ordering is what makes an unanswered start mean
# "left by a previous run" rather than "started a moment ago by this one".
if grep -q '^session_reconcile_orphans$' "$SHARED/bin/duty.sh"; then r1=called; else r1=UNWIRED; fi
t orphan-reconciler-runs-at-tick-time called "$r1"
# Ordered against the duty module invocations themselves — the only things in
# this file that dispatch — and not against the string `run_session`, which
# duty.sh mentions in a comment above the call site and would score a pass on
# any placement at all.
t orphan-reconciler-runs-before-any-dispatch before \
  "$(awk '/^[[:space:]]*#/ { next }
          /^session_reconcile_orphans$/ { rec = NR }
          /(^|[^[:alnum:]_])duty_[a-z]+/ { if (!disp) disp = NR }
          END { print (rec && disp && rec < disp) ? "before" : "AFTER" }' \
      "$SHARED/bin/duty.sh")"
# duty.sh runs under `set -euo pipefail`, and this is called before the boot
# gate, so a non-zero return anywhere in it does not degrade the tick — it ENDS
# the tick, and a box whose duty.log has nothing to reconcile is the common
# case. Driven under the caller's own flags, in each state it can meet.
# shellcheck disable=SC2317  # alert is reached from inside the library
orph_strict() (  # orph_strict <dir>
  set -euo pipefail
  DUTY_DIR="$1"; LOG_DIR="$1/logs"; DUTY_TICK_ID='tick-strict'
  # Stubbed even though nothing here reaches the threshold that alerts: the
  # suite exports the box's real HOME, and the real `alert` reads a Telegram
  # token out of it. A case must not be one edit away from paging the operator.
  alert() { :; }
  session_reconcile_orphans >/dev/null 2>&1
  printf survived
)
ORPH9="$TMP/orphan-strict"; orph_fixture "$ORPH9"
t orphan-strict-empty-log survived "$(orph_strict "$ORPH9" || printf 'ABORTED(%s)' "$?")"
printf '2026-08-14T09:00:00Z duty run start\n' >>"$ORPH9/duty.log"
t orphan-strict-nothing-owed survived "$(orph_strict "$ORPH9" || printf 'ABORTED(%s)' "$?")"
orph_start "$ORPH9" 2026-08-14T09:00:01Z build o/r#6 "$ORPH_DEAD.$ORPH_BOOT"
t orphan-strict-with-an-orphan survived "$(orph_strict "$ORPH9" || printf 'ABORTED(%s)' "$?")"
t orphan-strict-missing-log survived \
  "$(orph_strict "$TMP/orphan-no-such-dir" || printf 'ABORTED(%s)' "$?")"

# ...and the start it reads has to carry the holder it asks about.
# shellcheck disable=SC2016  # match the module's literal $(_session_holder)
if grep -q 'SESSION START .*holder=\$(_session_holder)' "$SHARED/lib/common/session.sh"; then
  r1=stamped
else
  r1=UNSTAMPED
fi
t orphan-session-start-carries-its-holder stamped "$r1"

suite_finish
