#!/usr/bin/env bash
# Classify the fleet-lifecycle verbs' PER-BOX output for rehearsal-fleet.sh and
# its fixture suite (#656).
#
# EVERY FUNCTION HERE READS OUTPUT AND NEVER AN EXIT CODE, and that is the
# whole design rather than a stylistic preference. `crew restart --all` returns
# one number for a roster: 0 for a clean sweep, 3 when some box was skipped
# busy, 1 when some box failed. Three boxes cycled and three boxes skipped are
# distinguishable in the text and NOT in the rc, and "cycled or skipped-busy,
# per box" is exactly what #642 and #652 each asked for in their own words. A
# leg that graded itself on the rc would print a per-box table it had not
# actually read, which is the shape the test plan's last case forbids.
#
# The same property is what makes these testable without a drill host: the
# fixtures feed the classifier the verbs' real line shapes and read its
# verdict, the way fleet-floor/test/floor/units.sh executes drill/agreement.sh
# rather than pinning rehearsal-app.sh's source text.
#
# Box lines are matched with the box's own name and a literal `: ` so that a
# roster carrying both `crew-drill-builder` and a longer name with that prefix
# cannot fold into one row.

# fleet_restart_outcome NAME — `crew restart` output on stdin.
#   cycled · skipped-busy · failed · unknown
#
# Precedence is worst-first and it is load-bearing: a box that announces
# `already stopped; starting` and then fails inside cycle_box has two lines,
# and the round reading must be the failure. `unknown` is a real verdict and
# not a fallback for tidiness — a box the verb never mentioned was not proved
# to have done anything, and the leg records that rather than an `ok`.
fleet_restart_outcome() { # NAME
  local name="$1" line outcome=unknown
  while IFS= read -r line; do
    case "$line" in
      "  restart FAILED on $name "*|"  restart FAILED on $name") printf 'failed\n'; return 0 ;;
      "  $name: "*) ;;
      *) continue ;;
    esac
    case "$line" in
      *": not present — restart FAILED") printf 'failed\n'; return 0 ;;
      *": SKIPPED busy — "*) [ "$outcome" = failed ] || outcome=skipped-busy ;;
      # Both cycle_box successes: a box that was running and one that was
      # already stopped. The second carries no pre-stop reading and is still a
      # cycle — recording it as `unknown` would red a round for the one state
      # `crew restart` is documented to handle.
      *": restarted; "*|*": started from stopped; "*)
        [ "$outcome" = unknown ] && outcome=cycled ;;
    esac
  done
  printf '%s\n' "$outcome"
}

# fleet_down_outcome NAME — `crew down` output on stdin.
#   waited · stopped · absent · failed · unknown
#
# `waited` outranks `stopped` deliberately. A box that was waited for and then
# stopped is the half of drain_probe()'s contract this leg exists to exercise,
# and folding it into `stopped` would make the busy case indistinguishable from
# an idle box that stopped immediately — the assertion would then pass on a
# round where nothing was ever busy.
fleet_down_outcome() { # NAME
  local name="$1" line outcome=unknown
  while IFS= read -r line; do
    case "$line" in
      "  down FAILED on $name "*|"  down FAILED on $name") printf 'failed\n'; return 0 ;;
      "  $name: "*) ;;
      *) continue ;;
    esac
    case "$line" in
      *": waiting for duty lock held "*|*": waiting because duty lock state is unreadable"*)
        outcome=waited ;;
      *": not present, skipping")
        [ "$outcome" = unknown ] && outcome=absent ;;
      *": already stopped"|*": stopped"|*": stopped while waiting")
        [ "$outcome" = unknown ] && outcome=stopped ;;
    esac
  done
  printf '%s\n' "$outcome"
}

# fleet_cut_outcome NAME — `crew reset --cut` output on stdin.
#   cut · skipped-busy · refused · failed · unknown
#
# A refusal outranks a skip for the same reason a failure outranks both: the
# cut path reaches its refusals only after the drain probe passed, so the two
# cannot both describe one box, and worst-first keeps a future line shape from
# being silently downgraded.
fleet_cut_outcome() { # NAME
  local name="$1" line outcome=unknown
  while IFS= read -r line; do
    case "$line" in
      "  $name: "*) ;;
      *) continue ;;
    esac
    case "$line" in
      *": FAILED — "*) printf 'failed\n'; return 0 ;;
      *": REFUSED — "*) [ "$outcome" = failed ] || outcome=refused ;;
      *": SKIPPED busy — "*)
        case "$outcome" in failed|refused) ;; *) outcome=skipped-busy ;; esac ;;
      # `<label> cut at crew@<ver>; root filesystem N% used`. The label is the
      # fleet's RESET_LABEL and is not spelled here: a fleet that renames it
      # must not silently start reading every cut as `unknown`.
      *": "*" cut at crew@"*)
        [ "$outcome" = unknown ] && outcome='cut' ;;
    esac
  done
  printf '%s\n' "$outcome"
}

# fleet_refusal_answer NAME — `crew reset --cut` output on stdin.
#   composed · unanswered · no-refusal
#
# #652's test plan in its own words: a refusal that reports only a percentage
# fails. The disk-ceiling refusal is the one that can do that — every other
# refusal names its cause in words — and cli/crew answers it on a continuation
# line rather than on the refusal line itself, so the composition is read from
# the block and not from the sentence.
#
# `largest: unavailable (…)` is graded `unanswered` ON PURPOSE. It is an honest
# report that the composition could not be taken, and it is still not the
# reading #652 asked for: the operator is told what to clear, or they are not.
# Grading it `composed` would let a drill host with no passwordless sudo in its
# boxes tick this criterion forever without ever producing the figure.
fleet_refusal_answer() { # NAME
  local name="$1" line detail residue in_block=0 answer=no-refusal
  while IFS= read -r line; do
    case "$line" in
      "  $name: REFUSED — "*)
        detail="${line#"  $name: REFUSED — "}"
        case "$detail" in
          # The percentage refusal, identified by what it says rather than by
          # the numbers in it: the ceiling figure is a fleet setting.
          "root filesystem "*"% used after reclaiming, over the "*"% ceiling")
            answer=unanswered; in_block=1; continue ;;
        esac
        # Every other refusal carries its cause in the sentence. This is the
        # BACKSTOP for that class rather than the main reading — the ceiling
        # refusal above is the one that can actually be percentage-only, and it
        # is matched by what it says. Here: keep the letters and require that
        # something is left, so a payload that was only ever a figure grades
        # `unanswered` rather than passing on having been printed at all.
        residue="$(printf '%s' "$detail" | tr -dc '[:alpha:]')"
        if [ -n "$residue" ]; then answer=composed; else answer=unanswered; fi
        in_block=0
        continue ;;
      # A continuation line: six spaces, and only meaningful while a percentage
      # refusal is open. Any other box line closes the block.
      "      largest: "*)
        if [ "$in_block" -eq 1 ]; then
          detail="${line#"      largest: "}"
          case "$detail" in
            ""|unavailable|"unavailable "*) ;;
            *) answer=composed ;;
          esac
        fi
        continue ;;
      "      "*) continue ;;
      "  "*) in_block=0 ;;
    esac
  done
  printf '%s\n' "$answer"
}

# fleet_restore_landing NAME LABEL — `crew reset` (restore) output on stdin.
#   restored · wrong-label · refused · failed · unknown
#
# #589 D4: a restore that silently fell back to `bootstrapped` or `pristine`
# FAILS. It is graded off the label the verb named itself, so the fixture case
# is a real line shape with a different label in it rather than a hypothetical.
fleet_restore_landing() { # NAME LABEL
  local name="$1" label="$2" line landed outcome=unknown
  while IFS= read -r line; do
    case "$line" in
      "  $name: "*) ;;
      *) continue ;;
    esac
    case "$line" in
      *": FAILED — "*) printf 'failed\n'; return 0 ;;
      *": REFUSED — "*) [ "$outcome" = failed ] || outcome=refused ;;
      *": restored to "*" and started")
        landed="${line#"  $name: restored to "}"
        landed="${landed%% *}"
        if [ "$landed" = "$label" ]; then
          [ "$outcome" = unknown ] && outcome=restored
        else
          outcome=wrong-label
        fi ;;
    esac
  done
  printf '%s\n' "$outcome"
}

# fleet_boot_gate_reading — a restored box's own first-tick evidence.
#   passing · failing · unreadable
#
# Two files, because neither alone answers it. duty.log carries the gate's
# verdict (`boot gate: auth probe failed …` is the failure, and it is the only
# place the degraded path is stated), and boot-check.log carries the probe the
# verdict was taken from. A boot-check.log with no `== boot check` header means
# the gate never ran on this boot at all, which is `unreadable` and not a pass:
# a restored box that never reached its gate has proved nothing, and #589 D4
# asks for the reading on the FIRST tick.
fleet_boot_gate_reading() { # DUTY_LOG_TEXT BOOT_CHECK_TEXT
  local duty_log="$1" boot_check="$2"
  case "$boot_check" in
    *"== boot check "*) ;;
    *) printf 'unreadable\n'; return 0 ;;
  esac
  case "$duty_log" in
    *"boot gate: auth probe failed"*) printf 'failing\n'; return 0 ;;
  esac
  case "$boot_check" in
    *"cli probe: FAILED"*) printf 'failing\n'; return 0 ;;
  esac
  case "$duty_log" in
    *"boot gate: new boot id "*|*"boot gate: first tick on this box "*) ;;
    *) printf 'unreadable\n'; return 0 ;;
  esac
  case "$boot_check" in
    *"cli probe: ok"*) printf 'passing\n' ;;
    *) printf 'unreadable\n' ;;
  esac
}

# fleet_counts_agree VERB SUMMARY — the per-box table on stdin, one
# `<name> <outcome>` row per line.
#   agree · disagree:<field>=<table>/<summary> · unreadable-summary
#
# The criterion #642 and #652 share: a fleet-level summary line ALONE does not
# satisfy them. This is what makes the table the evidence rather than a
# decoration beside the real reading — a row the leg dropped, or a row it
# invented, disagrees with the verb's own count and reds the round.
#
# An empty table against a non-zero summary therefore fails, which is the
# degenerate case of exactly that: a leg that printed the summary and no rows.
fleet_counts_agree() { # VERB SUMMARY
  local verb="$1" summary="$2" line name outcome
  local -A table=() want=()
  local -a fields=()
  case "$verb" in
    restart)
      fields=(cycled skipped-busy failed)
      [[ "$summary" =~ ^restart:\ ([0-9]+)\ restarted,\ ([0-9]+)\ skipped-busy,\ ([0-9]+)\ failed$ ]] \
        || { printf 'unreadable-summary\n'; return 0; }
      want[cycled]="${BASH_REMATCH[1]}"
      want[skipped-busy]="${BASH_REMATCH[2]}"
      want[failed]="${BASH_REMATCH[3]}" ;;
    down)
      fields=(stopped waited absent failed)
      [[ "$summary" =~ ^down:\ ([0-9]+)\ stopped,\ ([0-9]+)\ waited,\ ([0-9]+)\ absent,\ ([0-9]+)\ failed$ ]] \
        || { printf 'unreadable-summary\n'; return 0; }
      # `waited` is counted by the verb as an ANNOUNCEMENT and by the table as
      # a box outcome, and a box it waited for is also one it then stopped —
      # so the stopped count includes it. Reconciled here rather than by
      # loosening the assertion: both numbers stay checked.
      want[stopped]="${BASH_REMATCH[1]}"
      want[waited]="${BASH_REMATCH[2]}"
      want[absent]="${BASH_REMATCH[3]}"
      want[failed]="${BASH_REMATCH[4]}" ;;
    cut)
      fields=(cut skipped-busy failed)
      [[ "$summary" =~ ^reset\ --cut:\ ([0-9]+)\ cut,\ ([0-9]+)\ skipped-busy,\ ([0-9]+)\ failed$ ]] \
        || { printf 'unreadable-summary\n'; return 0; }
      want[cut]="${BASH_REMATCH[1]}"
      want[skipped-busy]="${BASH_REMATCH[2]}"
      # A refusal is counted by `crew reset` in its `failed` column and named
      # separately per box. Keep both readings: the table's refused rows and
      # its failed rows together are the verb's failed count.
      want[failed]="${BASH_REMATCH[3]}" ;;
    restore)
      fields=(restored skipped-busy failed)
      [[ "$summary" =~ ^reset:\ ([0-9]+)\ restored,\ ([0-9]+)\ skipped-busy,\ ([0-9]+)\ failed$ ]] \
        || { printf 'unreadable-summary\n'; return 0; }
      want[restored]="${BASH_REMATCH[1]}"
      want[skipped-busy]="${BASH_REMATCH[2]}"
      want[failed]="${BASH_REMATCH[3]}" ;;
    *) printf 'unreadable-summary\n'; return 0 ;;
  esac
  for outcome in "${fields[@]}"; do table["$outcome"]=0; done
  while read -r name outcome; do
    [ -n "$name" ] || continue
    case "$verb:$outcome" in
      # The verb's `failed` column is every box it could not complete, and for
      # a cut that includes every refusal.
      cut:refused|restore:refused) outcome=failed ;;
      # A restore that landed on the wrong label is counted by the verb in its
      # `restored` column — the verb believes it restored — so it is counted
      # here the same way. The judgement that it FAILS is
      # fleet_restore_landing's, and keeping it there is what stops one
      # predicate from quietly answering two questions: this one is the
      # table-to-summary arithmetic, and a disagreement here must mean a
      # dropped or invented row and nothing else.
      restore:wrong-label) outcome=restored ;;
      # A box the verb waited for is also one it stopped.
      down:waited) table[stopped]=$(( table[stopped] + 1 )) ;;
    esac
    [ -n "${table[$outcome]+x}" ] || { printf 'disagree:unknown-row=%s/%s\n' "$name" "$outcome"; return 0; }
    table["$outcome"]=$(( ${table[$outcome]} + 1 ))
  done
  for outcome in "${fields[@]}"; do
    if [ "${table[$outcome]}" -ne "${want[$outcome]}" ]; then
      printf 'disagree:%s=%s/%s\n' "$outcome" "${table[$outcome]}" "${want[$outcome]}"
      return 0
    fi
  done
  printf 'agree\n'
}

# fleet_worst_verdict — fold the leg's own per-case verdicts, newline separated,
# `<verdict> <why>` per line. Same partition and same precedence as every other
# leg's fold: FAIL beats skip beats ok, and nothing beats an empty input, which
# stays empty so the caller can say "the leg never reached a case" rather than
# reporting a pass over zero assertions.
fleet_worst_verdict() { # LINES
  local lines="$1" line verdict best="" best_line=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    verdict="${line%% *}"
    case "$verdict" in
      FAIL) printf '%s\n' "$line"; return 0 ;;
      skip) [ "$best" = skip ] || { best=skip; best_line="$line"; } ;;
      ok) [ -n "$best" ] || { best=ok; best_line="$line"; } ;;
    esac
  done <<<"$lines"
  printf '%s\n' "$best_line"
}
