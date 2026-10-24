#!/usr/bin/env bash
# .github/ci/plan.sh — turn a change into the list of suites it needs (#756).
#
#   plan.sh --paths-from <file|->     one repository path per line
#   plan.sh --pr <owner/repo> <number> the PR's files, read through `gh`
#   plan.sh --all                     every suite (push to main, the schedule)
#
# Prints two lines, `full=<0|1>` and `suites=<json array of ids>`, and writes
# the same to $GITHUB_OUTPUT when set. Any doubt — the API failing, a PR with
# more files than one page carries, a path no rule names, a test file with no
# suite id — is the full matrix: the map can narrow only by naming a path.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MAP="${CI_SUITES_MAP:-$HERE/suites.map}"
LIB="${CI_SUITES_LIB:-$ROOT/shared/test/lib.sh}"
# The PR files API lists at most this many; more than one page and we do not
# know what we did not see.
API_FILE_LIMIT=300

# The engine suites are lib.sh's SUITES array, read as text so this script
# never executes the suite library; the standalone suites and the floor's
# no-browser run are named here, which is the one place they are.
engine_suites() {
  sed -n '/^SUITES=(/,/)/p' "$LIB" | tr -d '()' | sed 's/^SUITES=//' | tr -s ' \n' '\n' | sed '/^$/d'
}
STANDALONE=(install-lifecycle artifact install-drill drill-teardown floor-no-browser)
all_suites() { engine_suites; printf '%s\n' "${STANDALONE[@]}"; }

is_suite() {  # is_suite <id>
  local id="$1" s
  while IFS= read -r s; do [ "$s" = "$id" ] && return 0; done < <(all_suites)
  return 1
}

# suites_for <path> — the ids this path needs, one per line; `full` means all.
suites_for() {
  local path="$1" matched=0 pattern suites s
  case "$path" in
    shared/test/common/*.sh)
      s="common/$(basename "$path" .sh)"
      if is_suite "$s"; then printf '%s\n' "$s"; else echo full; fi
      return 0 ;;
    shared/test/*.sh)
      s="$(basename "$path" .sh)"
      if is_suite "$s"; then printf '%s\n' "$s"; else echo full; fi
      return 0 ;;
  esac
  # First match decides, so a specific rule can sit above a catch-all.
  while IFS=$'\t' read -r pattern suites; do
    [ -n "$pattern" ] || continue
    case "$pattern" in '#'*) continue ;; esac
    # shellcheck disable=SC2053  # the rule's text IS a pattern; matching it as one is the point
    [[ "$path" == $pattern ]] || continue
    matched=1
    case "$suites" in
      full) echo full ;;
      none) ;;
      *) tr ',' '\n' <<<"$suites" | sed '/^$/d' ;;
    esac
    break
  done <"$MAP"
  [ "$matched" -eq 1 ] || echo full
}

emit() {  # emit <full 0|1> <ids...>
  local full="$1"; shift
  local json
  json="$(printf '%s\n' "$@" | sed '/^$/d' | sort -u | jq -R . | jq -cs .)"
  printf 'full=%s\n' "$full"
  printf 'suites=%s\n' "$json"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { printf 'full=%s\n' "$full"; printf 'suites=%s\n' "$json"; } >>"$GITHUB_OUTPUT"
  fi
}

plan_paths() {  # stdin: paths
  local path ids=() s full=0 any=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    any=1
    while IFS= read -r s; do
      if [ "$s" = full ]; then full=1; else ids+=("$s"); fi
    done < <(suites_for "$path")
  done
  if [ "$full" -eq 1 ] || [ "$any" -eq 0 ]; then
    mapfile -t ids < <(all_suites)
    emit 1 "${ids[@]}"
  else
    emit 0 "${ids[@]}"
  fi
}

case "${1:-}" in
  --all)
    mapfile -t ids < <(all_suites); emit 1 "${ids[@]}" ;;
  --paths-from)
    src="${2:-}"; [ -n "$src" ] || { echo "plan.sh: --paths-from needs a file or -" >&2; exit 2; }
    if [ "$src" = - ]; then plan_paths; else plan_paths <"$src"; fi ;;
  --pr)
    repo="${2:-}"; num="${3:-}"
    if [ -z "$repo" ] || [ -z "$num" ]; then echo "plan.sh: --pr needs <owner/repo> <number>" >&2; exit 2; fi
    # Every page (the API caps one at 100), and a renamed file by BOTH its
    # names: the old path's suites still own what moved out of it.
    if ! files="$(gh api --paginate "repos/$repo/pulls/$num/files?per_page=100" --jq '.[] | .filename, (.previous_filename // empty)' 2>/dev/null)"; then
      echo "plan.sh: could not read the PR's files; running everything" >&2
      mapfile -t ids < <(all_suites); emit 1 "${ids[@]}"; exit 0
    fi
    if [ "$(printf '%s\n' "$files" | sed '/^$/d' | wc -l)" -ge "$API_FILE_LIMIT" ]; then
      echo "plan.sh: the PR has $API_FILE_LIMIT files or more; running everything" >&2
      mapfile -t ids < <(all_suites); emit 1 "${ids[@]}"; exit 0
    fi
    plan_paths <<<"$files" ;;
  *)
    echo "usage: plan.sh --all | --paths-from <file|-> | --pr <owner/repo> <number>" >&2; exit 2 ;;
esac
