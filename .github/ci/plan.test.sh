#!/usr/bin/env bash
# Contract tests for .github/ci/plan.sh — offline, no network (#756). The
# property under test is the one the map's comment states: it can narrow only
# by naming a path, so every unknown shape runs everything.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLAN="$HERE/plan.sh"
PASS=0; FAIL=0
t() {  # t <name> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fi
}
plan() { printf '%s\n' "$@" | "$PLAN" --paths-from - 2>/dev/null; }
full_of() { grep '^full=' <<<"$1" | cut -d= -f2; }
suites_of() { grep '^suites=' <<<"$1" | cut -d= -f2- | jq -r '.[]' | paste -sd, -; }
ALL_N="$("$PLAN" --all | grep '^suites=' | cut -d= -f2- | jq length)"

out="$(plan shared/lib/common/ledger.sh)"
t plan-one-module-names-its-suites "builder,common,common/ledger,review,triage" "$(suites_of "$out")"
t plan-one-module-is-not-full 0 "$(full_of "$out")"
out="$(plan shared/test/common/breaker.sh)"
t plan-a-test-file-maps-by-name "common/breaker" "$(suites_of "$out")"
out="$(plan shared/test/drill.sh)"
t plan-a-standalone-test-file-maps-by-name "drill" "$(suites_of "$out")"
out="$(plan shared/test/claim.test.sh)"
t plan-a-test-file-with-no-suite-id-runs-everything 1 "$(full_of "$out")"
out="$(plan shared/docs/host-maintenance.md)"
t plan-docs-need-no-suite "" "$(suites_of "$out")"
t plan-docs-are-not-full 0 "$(full_of "$out")"
out="$(plan README.md)"
t plan-an-unmapped-path-runs-everything 1 "$(full_of "$out")"
t plan-everything-is-every-suite "$ALL_N" "$(grep '^suites=' <<<"$out" | cut -d= -f2- | jq length)"
out="$(plan shared/lib/common/ledger.sh shared/test/lib.sh)"
t plan-full-wins-the-union 1 "$(full_of "$out")"
out="$(plan shared/lib/duty-review.sh shared/lib/duty-reaper.sh)"
t plan-two-paths-union-their-suites "reaper,review" "$(suites_of "$out")"
out="$(plan .github/ci/suites.map)"
t plan-the-map-itself-runs-everything 1 "$(full_of "$out")"
out="$(plan fleet-floor/src/app.js)"
t plan-the-floor-runs-its-no-browser-suite "floor-no-browser" "$(suites_of "$out")"
out="$(plan)"
t plan-no-paths-runs-everything 1 "$(full_of "$out")"
# A specific rule sits above its catch-all and decides.
out="$(plan shared/lib/common/session.sh)"
t plan-first-match-decides-not-the-catch-all 0 "$(full_of "$out")"
out="$(plan shared/lib/common/something-new.sh)"
t plan-the-catch-all-runs-everything 1 "$(full_of "$out")"
# Every id the map names is a suite run-suite.sh can run.
bad=""
while IFS= read -r id; do
  [ "$id" = floor-no-browser ] && continue
  [ -f "$HERE/../../shared/test/$id.sh" ] || bad="$bad $id"
done < <(grep -v '^#' "$HERE/suites.map" | cut -f2 | tr ',' '\n' | grep -v -E '^(full|none)$' | sort -u)
t plan-every-mapped-id-is-a-suite "" "$bad"
# --all and a PR read that fails both run everything.
t plan-all-is-full 1 "$("$PLAN" --all | grep '^full=' | cut -d= -f2)"
stub="$(mktemp -d)"; printf '#!/usr/bin/env bash\nexit 1\n' >"$stub/gh"; chmod +x "$stub/gh"
out="$(PATH="$stub:$PATH" "$PLAN" --pr owner/repo 1 2>/dev/null)"; rm -rf "$stub"
t plan-unreadable-pr-runs-everything 1 "$(full_of "$out")"
# The files are read EVERY PAGE (the API caps one at 100): a PR of 300+ files
# runs everything, and a renamed file is planned by its old name too.
stub="$(mktemp -d)"
cat >"$stub/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *--paginate*files*) i=0; while [ "$i" -lt "${STUB_FILES:-1}" ]; do echo "shared/docs/f$i.md"; i=$((i+1)); done; [ -z "${STUB_RENAMED_FROM:-}" ] || { echo "docs/moved.md"; echo "$STUB_RENAMED_FROM"; } ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$stub/gh"
out="$(STUB_FILES=300 PATH="$stub:$PATH" "$PLAN" --pr owner/repo 1 2>/dev/null)"
t plan-a-pr-of-300-files-runs-everything 1 "$(full_of "$out")"
out="$(STUB_FILES=150 PATH="$stub:$PATH" "$PLAN" --pr owner/repo 1 2>/dev/null)"
t plan-a-pr-past-one-page-is-still-planned-by-path 0 "$(full_of "$out")"
t plan-reads-the-files-paginated 1 "$(STUB_FILES=1 PATH="$stub:$PATH" bash -c '"$0" --pr owner/repo 1 >/dev/null 2>&1; gh api --paginate x/files 2>/dev/null | wc -l' "$PLAN")"
out="$(STUB_FILES=1 STUB_RENAMED_FROM=shared/lib/common/ledger.sh PATH="$stub:$PATH" "$PLAN" --pr owner/repo 1 2>/dev/null)"
t plan-a-rename-is-planned-by-its-old-name-too 1 "$(suites_of "$out" | tr ',' '\n' | grep -cx 'common/ledger')"
rm -rf "$stub"
# $GITHUB_OUTPUT receives the same two lines.
tmp="$(mktemp)"; GITHUB_OUTPUT="$tmp" "$PLAN" --all >/dev/null; t plan-writes-github-output 2 "$(grep -c -E '^(full|suites)=' "$tmp")"; rm -f "$tmp"
# run-suite.sh refuses an id it does not know and names it.
t run-suite-refuses-an-unknown-id 2 "$("$HERE/run-suite.sh" no-such-suite >/dev/null 2>&1; echo $?)"
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
