#!/usr/bin/env bash
# test/lib.sh — shared harness for the duty engine fixture suites. No gh, no
# network: the suites run on bash+jq alone, in CI and on any box.
#
# These exist because three of five bots' self-assessments asked for exactly
# this ("fixture tests for detection predicates", "contract tests for the
# duty scripts", "plumbing one-liners deserve tests") and because the
# corpus-shaped blocker fixtures encode postmortem lesson 9: the parser must
# tolerate real issue-body prose, not parser-shaped strings.
set -uo pipefail

# Derived from this file rather than from "$0": a suite under shared/test/
# and a module suite under shared/test/common/ must resolve the same HERE, or
# the mirrored tree would put SHARED one directory too deep.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED="$(dirname "$HERE")"
ROOT="$(dirname "$SHARED")"
# The module suites mirror shared/lib/common/ one-for-one and are named at
# that relative path, which is the invariant, not this list's contents: a
# module added to shared/lib/common/ brings its suite here in the same change.
# shellcheck disable=SC2034  # consumed by run.sh and suite-level roster guards
SUITES=(common common/logging common/operating-limits common/conf common/checkout common/session
        common/detached-run common/breaker common/ledger common/identity common/tick-health
        triage builder review hygiene reaper release model-prices conf cli-lifecycle cli-reset cli-store drill vitals boot-gate host-tick)
PASS=0 FAIL=0

t() {  # t <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
  fi
}

suite_finish() {
  echo
  echo "passed $PASS, failed $FAIL"
  [ "$FAIL" -eq 0 ]
}

n() { awk 'NF{c++} END{print c+0}'; }

# A predicate must consume a completed producer. These two helpers preserve the
# match modes used by the two awk-range assertions while ensuring awk is reaped
# before grep can exit early.
awk_range_grep_q() {  # <range> <file> <pattern>
  local output
  output="$(awk "$1" "$2")"
  grep -q -- "$3" <<<"$output"
}

awk_range_grep_Fq() {  # <range> <file> <pattern>
  local output
  output="$(awk "$1" "$2")"
  grep -Fq -- "$3" <<<"$output"
}

# The engine's shell source, derived recursively rather than globbed. A guard
# spelled "$SHARED"/lib/*.sh stops above shared/lib/common/, so #507's split
# took seven engine modules out of two guard populations at once without a
# single assertion going red — the failure mode a glob has and a walk does not.
# Every guard whose population is "the engine's library source" derives it
# here, so the next shared/lib/<dir>/ costs nothing. Sorted for a stable
# report across boxes; callers add their own bin/ half.
engine_lib_sources() {
  find "$SHARED/lib" -type f -name '*.sh' -print | sort
}

# #443: derive the guarded population from both file-scope pipefail settings
# and source edges. The candidate surfaces are the issue's declared scope;
# #447 extended the same derivation to shared/lib without duplicating it, and
# #449 adds the live pipefail-setting entrypoints. Over-inclusion is the
# deliberate error direction: a candidate that runs under no pipefail costs one
# scanned file, a missing one costs a silent pass. shared/lib/version-skew.sh
# is the reason the entrypoints belong here — it sets nothing itself and enters
# only through the source edges in cli/crew and install.sh.
pipefail_grep_q_candidates() {
  find "$HERE" "$ROOT/drill" "$ROOT/fleet-floor/test" -type f -name '*.sh' -print
  find "$SHARED/bin" "$SHARED/lib" -type f -name '*.sh' -print
  find "$ROOT/dist" -type f -name '*.sh' -print
  find "$ROOT/cli" -type f -name 'crew' -print
  find "$ROOT" "$SHARED" -maxdepth 1 -type f -name 'install.sh' -print
}

pipefail_grep_q_population() {
  local file parent leaf changed
  local -a candidates=()
  local -A included=()
  mapfile -t candidates < <(pipefail_grep_q_candidates | sort -u)
  for file in "${candidates[@]}"; do
    if grep -Eq '^[[:space:]]*set[[:space:]]+[^#]*pipefail' "$file"; then
      included["$file"]=1
    fi
  done
  changed=1
  while [ "$changed" -eq 1 ]; do
    changed=0
    for file in "${candidates[@]}"; do
      [ -z "${included[$file]+x}" ] || continue
      leaf="${file##*/}"
      for parent in "${!included[@]}"; do
        # Source edges are matched by basename, so duplicate leaves can only
        # over-include candidates. Every duplicate today is already seeded by
        # its own pipefail setting; keep the conservative failure direction.
        if awk -v leaf="$leaf" '
          /^[[:space:]]*(source|\.)[[:space:]]/ && index($0, "/" leaf) { found=1 }
          END { exit !found }
        ' "$parent"; then
          included["$file"]=1
          changed=1
          break
        fi
      done
    done
  done
  printf '%s\n' "${!included[@]}" | sort
}

# A pipeline inside a quoted payload handed to a remote shell — bxn, or box
# exec … bash -lc — runs where this file's pipefail is not in effect, so grep's
# status is the pipeline's status and the shape is outside the class. #449 keys
# that exemption to the shape rather than to a filename: cli/crew is a
# candidate now, and its payload site is exempt for the reason the
# rehearsal-app.sh ones are, not for where it lives.
#
# The exemption is bounded twice, and both bounds are load-bearing.
#
# It ends where the payload does. Rather than asking whether a line carrying a
# payload has a pipe somewhere after it, blank the payload bodies out and read
# what is left: that residue is what this file's own shell runs, and this
# file's pipefail is the one the guard is about. A local pipeline sharing a
# line with a payload — before it, after its closing quote, or wrapped around
# it — therefore stays in the class.
#
# It begins only at a real invocation. The residue is built by one left-to-
# right scan that tracks quote state, so the only quotes ever tested as payload
# openers are the ones at an unquoted position, and a quote can open a payload
# only when the text scanned before it ends in bash -lc or bxn <arg>. Matching
# opener-shaped text anywhere on the line would read the " in
# `echo 'bash -lc "'` as an opener, find no mate, and swallow that line's
# actual pipeline as an unterminated payload — the silent pass this guard
# exists to prevent (#451 rounds 1 and 2).
pipefail_grep_q_sites() {  # [files...]
  local files=("$@")
  [ "${#files[@]}" -gt 0 ] || mapfile -t files < <(pipefail_grep_q_population)
  awk -v Q="\"'" '
    function qgrep(s) {
      return s ~ /grep[[:space:]]+(-[^[:space:]]+[[:space:]]+)*-[[:alnum:]-]*q[[:alnum:]-]*([[:space:]]|$)/
    }
    # Whether the text scanned so far puts the next quote in an invocation
    # context — i.e. that quote opens a command string handed to a remote
    # shell. Both spellings, anchored at the end of the prefix rather than
    # searched for anywhere in the line. The prefix is the line as written, so
    # the bxn argument may itself be a quoted word.
    function payload_opener_prefix(pre) {
      return pre ~ /(^|[^[:alnum:]_-])bash[[:space:]]+-lc[[:space:]]*$/ ||
             pre ~ /(^|[^[:alnum:]_-])bxn[[:space:]]+[^[:space:]]+[[:space:]]+$/
    }
    # The line with every payload body removed and its quotes kept. One pass,
    # left to right: quotes are only significant outside an open string, so a
    # quote character inside one is data and is copied through. An ordinary
    # quoted string is kept verbatim — a local pipeline is still a local
    # pipeline when it shares a line with one. A payload whose quote does not
    # close on this line takes the remainder with it: the payload really does
    # continue, and the lines it continues onto are then read as local, which
    # is the over-flagging direction this guard prefers.
    function strip_payloads(s,   out, seen, i, n, c, e) {
      out = ""; seen = ""; n = length(s)
      for (i = 1; i <= n; ) {
        c = substr(s, i, 1)
        if (!index(Q, c)) { out = out c; seen = seen c; i++; continue }
        e = index(substr(s, i + 1), c)   # offset of the mate, or 0
        if (payload_opener_prefix(seen)) {
          out = out c
          if (!e) return out
          out = out c
        } else {
          if (!e) return out substr(s, i)
          out = out substr(s, i, e + 1)
        }
        seen = seen substr(s, i, e + 1)
        i += e + 1
      }
      return out
    }
    FNR == 1 { pipe_line = 0 }
    /^[[:space:]]*#/ { pipe_line = 0; next }
    { local_line = strip_payloads($0) }
    local_line ~ /(^|[^|])[|][[:space:]]*grep[[:space:]]/ && qgrep(local_line) {
      printf "%s:%d:%s\n", FILENAME, FNR, $0
    }
    pipe_line && qgrep(local_line) {
      printf "%s:%d:%s\n", FILENAME, FNR, $0
    }
    { pipe_line = (local_line ~ /(^|[^|])[|][[:space:]\\]*$/) }
  ' "${files[@]}"
}

assert_doctrine_quote() {  # <prompt-file> <substring> <name> [doctrine-heading]
  local prompt_file="$1" substring="$2" name="$3" doctrine_heading="${4-}"
  local prompt_text doctrine_text result
  prompt_text="$(tr -s '[:space:]' ' ' <"$prompt_file")"
  doctrine_text="$(tr -s '[:space:]' ' ' <"$ROOT/.ceremony/BUILDER.md")"
  result=DIVERGED
  if grep -Fq -- "$substring" <<<"$prompt_text"; then
    if [ -n "$doctrine_heading" ]; then
      # A cited section must be an exact Markdown heading. This deliberate
      # line-based exception distinguishes a heading from matching prose.
      grep -Fxq -- "$doctrine_heading" "$ROOT/.ceremony/BUILDER.md" \
        && result=agreed
    elif grep -Fq -- "$substring" <<<"$doctrine_text"; then
      result=agreed
    fi
  fi
  t "$name" agreed "$result"
}

# List prompt slots omitted by engine render sites. Calls are folded to one
# logical line first; advancing past only the opening "$(`` also finds nested
# render_prompt calls such as review.txt's ONESHOT_RULES argument.
render_site_missing_slots() {  # render_site_missing_slots PROMPTS SOURCE...
  local prompts="$1" source site call rest prompt slot supplied
  shift
  for source in "$@"; do
    while IFS='|' read -r site call; do
      [ -n "$call" ] || continue
      rest="${call#*render_prompt }"
      prompt="${rest%%[[:space:]]*}"
      [ -f "$prompts/$prompt" ] || continue
      supplied="$(printf '%s\n' "$call" | grep -oE '[A-Z_][A-Z_]*=' | tr -d '=' | sort -u)"
      while read -r slot; do
        [ -n "$slot" ] || continue
        case "$slot" in
          DOCTRINE_ENTRYPOINT|DOCTRINE_TRIAGE|DOCTRINE_BUILDER|DOCTRINE_REVIEWER|DOCTRINE_OUTCOME) continue ;;
        esac
        if ! grep -qx "$slot" <<<"$supplied"; then
          printf '%s:%s: %s missing %s\n' "$source" "$site" "$prompt" "$slot"
        fi
      done < <(grep -oE '\{\{[A-Z_][A-Z_]*\}\}' "$prompts/$prompt" \
        | tr -d '{}' | sort -u)
    done < <(awk '
      function calls(text, line, rest, tail, endpos, call) {
        rest = text
        while (match(rest, /\$\(render_prompt[[:space:]]+/)) {
          tail = substr(rest, RSTART)
          endpos = index(tail, ")")
          call = endpos ? substr(tail, 1, endpos) : tail
          print line "|" call
          rest = substr(rest, RSTART + 2)
        }
      }
      {
        if (buf == "") start = NR
        buf = buf $0
        if (sub(/\\[[:space:]]*$/, "", buf)) next
        calls(buf, start)
        buf = ""
      }
      END { if (buf != "") calls(buf, start) }
    ' "$source")
  done
}

# Phase 0 stages the whole tracked tree except fleet-floor/dev, then verifies
# the repository roots this suite names before running it. Keep that explicit
# verifier and archive selection from falling behind new literal root paths.
phase0_suite_paths() {  # phase0_suite_paths <suite>...
  # shellcheck disable=SC2016  # match literal root expressions in the suite
  grep -hoE '\$(ROOT|\{ROOT\})/[.[:alnum:]_/-]+' "$@" \
    | sed -E 's#^\$(ROOT|\{ROOT\})/##' \
    | sort -u || true
}

phase0_suite_roots() {  # phase0_suite_roots <suite>...
  phase0_suite_paths "$@" | cut -d/ -f1 | sort -u
}

phase0_split_coverage_result() {  # phase0_split_coverage_result <rehearsal>
  local rehearsal="$1" merged rc suite
  merged="$(mktemp)"
  for suite in "${SUITES[@]}"; do
    sed -n '1,$p' "$HERE/$suite.sh" >>"$merged"
  done
  phase0_coverage_result "$merged" "$rehearsal"
  rc=$?
  rm -f "$merged"
  return "$rc"
}

phase0_verified_roots() {  # phase0_verified_roots <rehearsal>
  # shellcheck disable=SC2016  # match the literal stage expression in rehearsal
  sed -n '/BEGIN phase-0 suite roots/,/END phase-0 suite roots/p' "$1" \
    | grep -oE '\$stage/[.[:alnum:]_-]+' \
    | sed 's|^\$stage/||' \
    | sort -u || true
}

phase0_archive_result() {  # phase0_archive_result <rehearsal>
  local selection archive_commands exclusions
  selection="$(sed -n '/BEGIN phase-0 archive selection/,/END phase-0 archive selection/p' "$1")"
  [ -n "$selection" ] || { printf '%s\n' empty-archive-selection; return; }
  # shellcheck disable=SC2016  # match literal phase-0 variable references
  archive_commands="$(printf '%s\n' "$selection" \
    | grep -cF 'git -C "$SOURCE_TREE" archive --format=tar "$SOURCE_SHA"' || true)"
  exclusions="$(printf '%s\n' "$selection" | grep -oF ':(exclude)' | wc -l)"
  if [ "$archive_commands" -ne 1 ] \
    || ! grep -Fq -- "-- . ':(exclude)fleet-floor/dev'" <<<"$selection" \
    || [ "$exclusions" -ne 1 ]; then
    printf '%s\n' archive-selection-mismatch
  else
    printf '%s\n' covered
  fi
}

phase0_coverage_result() {  # phase0_coverage_result <suite> <rehearsal>
  local paths roots verified missing archive_result
  paths="$(phase0_suite_paths "$1")"
  [ -n "$paths" ] || { printf '%s\n' empty-suite-roots; return; }
  roots="$(phase0_suite_roots "$1")"
  verified="$(phase0_verified_roots "$2")"
  [ -n "$verified" ] || { printf '%s\n' empty-verified-roots; return; }
  missing="$(comm -23 \
    <(printf '%s\n' "$roots") \
    <(printf '%s\n' "$verified"))"
  if [ -n "$missing" ]; then
    printf 'missing:%s\n' "$(printf '%s\n' "$missing" | paste -sd, -)"
  elif grep -Eq '^fleet-floor/dev(/|$)' <<<"$paths"; then
    printf '%s\n' excluded:fleet-floor/dev
  else
    archive_result="$(phase0_archive_result "$2")"
    [ "$archive_result" = covered ] \
      && printf '%s\n' covered \
      || printf 'archive:%s\n' "$archive_result"
  fi
}
