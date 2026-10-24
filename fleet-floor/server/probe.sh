#!/usr/bin/env bash
# probe.sh — read one box's duty evidence, from the HOST, over `box exec`.
#
#   box exec <name> -- bash -lc "$(cat probe.sh)" < shared/conf/agents/<a>.conf
#
# Nothing is installed in the box and nothing is written except the throwaway
# agent-profile copy vendor probing already used (crew's vendor_probe). The
# box stays a read target: the operator host holds the control, exactly as it
# does for `crew status`. This is the whole box-side half of #38/#39 — there
# is no daemon, no collector client, no outbound call from the box.
#
# Output is a line-oriented record, NOT JSON: building JSON in bash across
# duty.log lines that contain quotes, braces and backslashes is how you ship a
# parser bug. Every line is `::<key> <value>`; the log section is delimited so
# its content is never parsed as keys.
#
# set -u only, never -e: a missing file or a vendor CLI that exits non-zero is
# a fact to report, not a reason to return nothing (the same reasoning as
# tick.sh's rc dispatch).
set -u

# Exported, not merely set: the integrity read below runs engine-manifest.sh,
# which resolves the same variable, and it must measure the tree this file is
# reporting on rather than the default.
export DUTY_DIR="${DUTY_DIR:-$HOME/duty}"

emit() { printf '::%s %s\n' "$1" "${2-}"; }

# The agent profile arrives on stdin so this works on unhired boxes too.
conf=/tmp/.crew-floor-probe.conf
if [ ! -t 0 ]; then cat >"$conf" 2>/dev/null; fi

emit engine "$(head -1 "$DUTY_DIR/VERSION" 2>/dev/null | tr -d '\r')"

# --- engine integrity: whether the box is running the engine it just named ---
#
# ~/duty/VERSION is a CLAIM (#159): install.sh writes it once and nothing since
# looks at the files, so a hand-edited box reports its shipped stamp forever and
# the line above carries that claim to an operator with nothing qualifying it.
# engine-manifest.sh hashes the shipped tree and answers in one word; the floor
# renders that word beside the version, which is the same question — and the
# same script, and therefore the same answer — `crew status` puts in its
# INTEGRITY column. Two readers holding private sources of truth is the defect
# this console exists to end, so neither of them computes this itself.
#
# LOCAL and cheap, unlike the credential probes removed above: 43 files and
# ~400 KB of sha256 on a current tree, ~25 ms, against a 60s poll whose
# cheapest step is a `box exec` round trip. Nothing here touches the network.
#
# The fallback mirrors cli/crew's engine_report exactly, and the reason is
# engine-manifest.sh's own: an engine installed before content stamping ships
# no tool and recorded no manifest, and that is UNVERIFIED, never modified — a
# fleet that reads modified everywhere on the day this lands has learned that
# the word means nothing. One upgrade cures it.
if [ -x "$DUTY_DIR/bin/engine-manifest.sh" ]; then
  # An empty value is deliberate on failure: the script dies rather than guess
  # when it cannot hash (no sha256sum), and a box that could not answer must
  # render nothing, never `current`.
  #
  # EXPORTED above, not inherited by luck: DUTY_DIR is a shell variable in this
  # file, so a probe pointed at a non-default tree would read that tree's
  # VERSION and hash `$HOME/duty` — two answers about two boxes on one record.
  emit integrity "$("$DUTY_DIR/bin/engine-manifest.sh" --state 2>/dev/null | head -1 | tr -d '\r')"
elif [ -s "$DUTY_DIR/VERSION" ]; then
  emit integrity unverified
else
  emit integrity absent
fi

# The agent the box was ACTUALLY installed as, from the instance.conf
# install.sh wrote — not what a roster claims about it.
#
# Nothing used to read this, and that is what made a whole class of bug silent:
# both readers (the floor here, and `crew status`) take the roster's agent
# column on faith and hand it straight to the vendor probe, so a roster that
# misdeclares an agent produces a permanently red vendor column with nothing
# saying the ROSTER is what is wrong. Reported so a declaration can be checked
# against ground truth instead of assumed.
#
# Parsed, not sourced: this file is read on every poll of every box, and
# sourcing a config to learn one string is a much bigger blast radius than
# reading it.
emit agent "$(sed -n 's/^BOT_AGENT=//p' "$DUTY_DIR/conf/instance.conf" 2>/dev/null \
  | head -1 | tr -d '"'\''\r')"
emit uptime "$(cut -d. -f1 /proc/uptime 2>/dev/null)"
emit now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# --- box vitals: the newest record, carried VERBATIM (#483 D1) --------------
#
# tick.sh writes one `VITALS …` line into duty.log per tick. This does not
# re-measure anything and does not interpret the line — it selects the newest
# one and hands it over unchanged, which is the same split every other read in
# this file observes: the box side of an exec is the half no offline test can
# reach, so anything that decides a meaning lives on the collector's side of
# it (floor.units.parse_vitals) or in `crew status`, where a test can drive it.
#
# CARRIED rather than left to the log section below, and that is the whole
# reason this line exists. `crew status` greps the box's WHOLE duty.log for
# this record; the log section here is the newest 600 lines, which is a
# transport budget, not a selection rule. A box that logged 600 lines inside
# one tick — an ordinary long session — would leave the floor with no record
# while the CLI had one, and "the two readers render the same record" would be
# true of the parse and false on screen. Same selection rule on both sides,
# stated once each.
#
# Whole-file and not `tail -n N | grep`: the window that would make this cheap
# is exactly the window that just went wrong above. duty.log is capped at 5 MB
# by tick.sh's own rotation, so the scan is bounded by construction.
#
# Empty on every box whose engine predates the probe, which is every box for
# the first tick after it lands. The collector renders that as no section.
emit vitals "$(grep -a '^VITALS ' "$DUTY_DIR/duty.log" 2>/dev/null | tail -1)"

# The derivation is computed by the installed shared module, not independently
# by the floor. Its delimited report is carried verbatim to the collector.
echo "::tickhealthstart"
if [ -r "$DUTY_DIR/lib/common.sh" ]; then
  # shellcheck disable=SC2016  # these paths expand inside the child shell
  env DUTY_DIR="$DUTY_DIR" bash -c \
    '. "$DUTY_DIR/lib/common.sh"; tick_health_report "$DUTY_DIR/duty.log"' 2>/dev/null
fi
echo "::tickhealthend"

# --- credentials: read, never tested ---------------------------------------
#
# This probe used to run `gh auth status` and the agent profile's
# bot_cli_probe on every poll. Both touch the network — `gh auth status` is a
# real api.github.com round-trip (~450ms, and the single slowest thing in this
# file; everything else is a local read) — to re-answer a question whose
# answer changes when a token expires, i.e. about monthly. At a 60s poll that
# was ~7,000 GitHub requests a day per fleet to re-learn a constant.
#
# Both are now REPORTED BY THE FLOW instead of polled. The duty engine already
# talks to GitHub every tick (duty_attention runs first, for every role), so
# it is the thing that finds out first and for free:
#
#   .auth-fail.<svc>  — written at the moment a credential is rejected or found
#                       expired, cleared on the next success.
#                       `<iso8601> <what failed>`.
#
# One boolean per service, and no expiry date: providers express expiry four
# different ways and two of the four agent CLIs cannot answer locally at all,
# so the countdown was the flaky half. What survives is the stable half, and
# it is a stronger claim than the probe it replaces — a rejection means the
# credential could not do the WORK, not merely that it authenticates against
# `GET /`, which a token with the wrong scopes does happily.
#
# The wire keys stay `gh` and `vendor`, but `ok` is gone: absence of a failure
# is not proof of a credential, and a value that cannot tell those apart is how
# a logged-out box renders green.
#
# FOUR values, because three were one short. `flowing` claims the engine has
# been talking to this service and has not been rejected — but the first cut
# derived it from `VERSION` existing, and VERSION is written once by
# install.sh and never touched again. It records that the engine was
# INSTALLED, not that it has RUN. So a box hired last month with its cron
# since disarmed and its token expired last week records no rejection (nothing
# runs to be rejected), has a VERSION, and rendered `flowing` — exactly the
# "a logged-out box renders green" failure this value exists to prevent, with
# a comment above it reassuring the reader otherwise.
#
# `flowing` therefore requires a RECENT TICK as well. But the BOX does not
# decide that: it emits `nofail` — "an engine is installed and nothing has
# recorded a rejection" — alongside `::tickage`, and the host turns the pair
# into flowing-or-stale.
#
# That split is deliberate. The threshold is two tick boundaries, which
# floor.py already derives from TICK_S as SILENT_AFTER_S. Baking `600` in here
# made a THIRD copy of that rule, in a second language, inside the box — so
# changing TICK_S would leave the floor calling a box SILENT while the
# credential readers still called it flowing. This PR exists because a CLI and
# a floor holding private sources of truth disagree in front of an operator; a
# private *threshold* is the same defect wearing a smaller hat.
#
#   unknown  no engine: nothing has ever run, so nothing is known
#   nofail   engine installed, no rejection recorded — the host ages this
#            into `flowing` (ticking), `stale` (it ticked once and stopped) or
#            `waiting` (::tickage is absent, so it has never ticked at all)
#   missing  a rejection was recorded
#
# One marker file PER SERVICE. The first cut used a single .auth-fail and
# decided which service was broken by substring-matching the reason text — so a
# gh error mentioning the word "vendor" condemned the agent CLI too, and sent
# the operator to re-login the wrong thing.

# Age of the newest timestamped duty.log line, in seconds; empty if there is
# none. Computed here rather than left to the collector because the credential
# values are emitted here and must not disagree with themselves.
tick_age=""
if [ -r "$DUTY_DIR/duty.log" ]; then
  last_ts="$(grep -a -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' \
    "$DUTY_DIR/duty.log" 2>/dev/null | tail -1)"
  if [ -n "$last_ts" ]; then
    last_epoch="$(date -u -d "$last_ts" +%s 2>/dev/null || echo)"
    case "$last_epoch" in
      ''|*[!0-9]*) : ;;
      *) tick_age=$(( $(date -u +%s) - last_epoch )) ;;
    esac
  fi
fi
emit tickage "$tick_age"

for svc in gh vendor; do
  fail=""
  [ -f "$DUTY_DIR/.auth-fail.$svc" ] \
    && fail="$(head -1 "$DUTY_DIR/.auth-fail.$svc" 2>/dev/null | tr -d '\r')"
  if [ -n "$fail" ]; then
    emit "$svc" missing
    emit "authfail-$svc" "$fail"
  elif [ ! -s "$DUTY_DIR/VERSION" ]; then
    emit "$svc" unknown
  else
    # No verdict here — see above. ::tickage carries what the host needs.
    emit "$svc" nofail
  fi
done

# How long the current duty run has held the lock, in seconds — duty.sh writes
# .duty.lock.since on entry and clears it on EXIT, so a value here means a run
# is in flight RIGHT NOW, and its age is that run's age.
#
# This is the wedge the SILENT rule cannot see. A duty session hung on a vendor
# CLI network call keeps ticking (tick.sh logs "tick skipped: previous run
# still holds the lock"), so duty.log stays fresh, cron reads healthy, and the
# floor renders a green box that has done nothing for 40 minutes — until the
# 1800s session timeout fires. tick.sh already computes this age for its log
# line; nothing had ever surfaced it to an operator.
if [ -f "$DUTY_DIR/.duty.lock.since" ]; then
  since="$(cat "$DUTY_DIR/.duty.lock.since" 2>/dev/null || echo)"
  case "$since" in
    ''|*[!0-9]*) : ;;   # absent or truncated mid-write — report nothing, not a bogus age
    *) emit lockheld "$(( $(date +%s) - since ))" ;;
  esac
fi

# The oldest active zero-action resume-breaker episode. Each lane owns one
# marker so a quiet repository cannot erase another repository's suppression;
# the marker carries `<trip-epoch> <lane> <repo#pr@head>`. Report its age from
# the box clock, where the trip was recorded, and carry the reason unchanged.
supp_when=0; supp_kind=""; supp_key=""
for supp_file in "$DUTY_DIR"/.builder-suppressed.*; do
  [ -f "$supp_file" ] || continue
  IFS=$'\t' read -r when kind key <"$supp_file" 2>/dev/null || continue
  case "$when" in ''|*[!0-9]*) continue ;; esac
  if [ -z "$kind" ] || [ -z "$key" ]; then
    continue
  fi
  if [ "$supp_when" -eq 0 ] || [ "$when" -lt "$supp_when" ]; then
    supp_when="$when"; supp_kind="$kind"; supp_key="$key"
  fi
done
if [ "$supp_when" -gt 0 ]; then
  emit suppression "$(( $(date +%s) - supp_when )) $supp_kind $supp_key"
else
emit suppression ""
fi

# Durable engine limit events cross as one uninterpreted section. The probe
# reports the cumulative loss counter, reads the spool verbatim, and writes
# nothing; parsing and delivery stay on the host floor (#482 D6.4).
limit_dropped="$(cat "$DUTY_DIR/.limit-events.dropped" 2>/dev/null || echo 0)"
case "$limit_dropped" in ''|*[!0-9]*) limit_dropped=0 ;; esac
emit limitdropped "$limit_dropped"
echo "::limitstart"
cat "$DUTY_DIR/.limit-events" 2>/dev/null || :
echo "::limitend"

# Cron is the liveness contract: tick.sh guarantees one duty.log line per
# 5-minute boundary, so silence means cron itself is dead (#38's death rule).
emit cron "$(crontab -l 2>/dev/null | grep -cE '^[^#].*tick\.sh')"
emit paused "$(crontab -l 2>/dev/null | grep -cE '^#[[:space:]]*CREW-FLOOR-PAUSED')"

# repos.txt is the box's real work scope — the floor shows it instead of
# inventing one.
if [ -f "$DUTY_DIR/repos.txt" ]; then
  emit repos "$(grep -vE '^[[:space:]]*(#|$)' "$DUTY_DIR/repos.txt" 2>/dev/null | tr '\n' ' ')"
fi

# run_session names these itself, from a UTC stamp and a sanitized key
# (`${key//[\/#]/_}`), so there is nothing here to mangle and the lexical
# order IS the chronological one.
#
# `*.log` and not everything in the directory: LOG_DIR is not session logs
# alone while a session is RUNNING. run_session holds a `<slog>.peak` scratch
# file beside the log it is measuring (#473) and removes it before SESSION
# END, so a poll landing mid-session used to put a `…-key.log.peak` into this
# list and spend one of the forty slots on it. Nothing renders `logs`, so the
# symptom was invisible — which is the reason to fix the selection rather
# than the symptom. The glob is also the general answer: any file a later
# change parks in LOG_DIR costs a slot here otherwise.
#
# A glob and not `ls`: bash sorts it lexically itself, which is the order the
# pipe was already relying on, and it costs no fork on a path that runs every
# poll. `-e` because an unmatched glob comes back as the pattern itself.
#
# The last forty by an explicit offset and not `${a[*]: -40}`: a negative
# offset larger than the array is not a clamp in bash, it is EMPTY — measured
# — so the slice that reads like `tail -40` would have reported no logs at all
# on every box with fewer than forty.
sesslogs=()
for sesslog in "$DUTY_DIR"/logs/*.log; do
  [ -e "$sesslog" ] || continue
  sesslogs+=("${sesslog##*/}")
done
sessfrom=0
[ "${#sesslogs[@]}" -gt 40 ] && sessfrom=$(( ${#sesslogs[@]} - 40 ))
emit sessionlogs "${sesslogs[*]:sessfrom}"

# 600 lines ≈ several hours of ticks at one run per 5 minutes — enough for the
# session history and 24h metrics the console shows, small enough to move over
# `box exec` every poll.
echo "::logstart"
tail -n 600 "$DUTY_DIR/duty.log" 2>/dev/null | tr -d '\r'
echo "::logend"

# --- full mode: the state files and the whole (or partial) duty.log (#758) ---
#
# OPT-IN, by `PROBE_FULL=1` in the environment the script runs under, and
# everything above this line is byte-identical whether or not it is set: the
# cadence record the floor has always read is unchanged, and this block only
# APPENDS sections after it. The host's store (fleet-floor/server/floor/store.py)
# is the only reader; it asks for full mode on every collector poll and on
# `crew drain`, so a box stopped between polls loses nothing it had written.
#
# One delimited `::filestart <name>` … `::fileend` section per state file the
# engine keeps under $DUTY_DIR — the seen/suppressed ledgers, the resume and
# terminal breakers, the budget counters, the decline markers, the limit-event
# spool, the auth-fail markers, the hygiene/reaper/review stamps and the lock
# stamp — carried VERBATIM, the way the limit spool already crosses: the host
# decides what each means, the box reports what it has. `::statefiles` names
# every file found first, so a file the box no longer has (a breaker that
# cleared) is a fact the host can act on rather than an absence it cannot see.
#
# duty.log crosses in its own section, from line `PROBE_LOG_FROM` (default 1,
# the whole file) so a cadence pull ships only what is new since the last one.
# `::logfrom` and `::logtotal` say which slice this is, and a `from` past the
# file's end — the file was rotated (tick.sh moves it aside at 5 MB) and is
# shorter than the host last saw — restarts from line 1, which the host reads
# as "re-ingest from the top". The `::logstart` tail above is NOT replaced by
# this: the floor's live record still reads the newest 600 lines exactly as
# before, and the store reads this section.
#
# A file whose last line has no newline gets one, so `::fileend` never lands
# on the same line as the file's last byte.
if [ "${PROBE_FULL:-0}" = 1 ]; then
  probe_file() { # NAME PATH
    echo "::filestart $1"
    tr -d '\r' <"$2" 2>/dev/null || :
    if [ -s "$2" ] && [ "$(tail -c1 "$2" 2>/dev/null | wc -l)" -eq 0 ]; then echo; fi
    echo "::fileend"
  }
  statefiles=""
  for sf in "$DUTY_DIR"/.seen-* "$DUTY_DIR"/.suppressed-* \
            "$DUTY_DIR"/.builder-suppressed.* "$DUTY_DIR"/.declined-build.* \
            "$DUTY_DIR"/.session-terminal.* "$DUTY_DIR"/.session-budget.* \
            "$DUTY_DIR"/.resume-* "$DUTY_DIR"/.limit-events \
            "$DUTY_DIR"/.limit-events.dropped "$DUTY_DIR"/.auth-fail.* \
            "$DUTY_DIR"/.hygiene-last "$DUTY_DIR"/.reaper-last \
            "$DUTY_DIR"/.review-owed "$DUTY_DIR"/.duty.lock.since \
            "$DUTY_DIR"/.identity "$DUTY_DIR"/.idle-ticks \
            "$DUTY_DIR"/.handoff-* "$DUTY_DIR"/.wait-* "$DUTY_DIR"/.session-continue.* \
            "$DUTY_DIR"/.release-* "$DUTY_DIR"/.panel-sized-*; do
    [ -f "$sf" ] || continue
    statefiles="$statefiles ${sf##*/}"
  done
  emit statefiles "${statefiles# }"
  for name in $statefiles; do
    probe_file "$name" "$DUTY_DIR/$name"
  done
  log_from="${PROBE_LOG_FROM:-1}"
  case "$log_from" in ''|*[!0-9]*|0) log_from=1 ;; esac
  log_total="$(awk 'END { print NR }' "$DUTY_DIR/duty.log" 2>/dev/null || echo 0)"
  case "$log_total" in ''|*[!0-9]*) log_total=0 ;; esac
  [ "$log_from" -le $((log_total + 1)) ] || log_from=1
  emit logfrom "$log_from"
  emit logtotal "$log_total"
  echo "::filestart duty.log"
  if [ -r "$DUTY_DIR/duty.log" ]; then
    tail -n +"$log_from" "$DUTY_DIR/duty.log" | tr -d '\r'
    if [ -s "$DUTY_DIR/duty.log" ] && [ "$log_from" -le "$log_total" ] \
       && [ "$(tail -c1 "$DUTY_DIR/duty.log" 2>/dev/null | wc -l)" -eq 0 ]; then echo; fi
  fi
  echo "::fileend"
  # The rotated log, whole, ONCE per rotation: the lines written between the
  # last pull and the rotation live there, SESSION END rows included. Its
  # size+mtime is the mark; the host says which mark it already holds
  # (PROBE_LOG1_SEEN) and the file crosses again only when the mark moved —
  # never up to 5 MB on every poll until the next rotation.
  if [ -r "$DUTY_DIR/duty.log.1" ]; then
    log1_mark="$(stat -c '%s.%Y' "$DUTY_DIR/duty.log.1" 2>/dev/null || echo 0.0)"
    emit log1mark "$log1_mark"
    [ "$log1_mark" = "${PROBE_LOG1_SEEN:-}" ] || probe_file duty.log.1 "$DUTY_DIR/duty.log.1"
  fi
fi
