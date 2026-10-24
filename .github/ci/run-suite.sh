#!/usr/bin/env bash
# .github/ci/run-suite.sh <id> — run one suite by the id plan.sh emits (#756).
# Engine and installer suites are shared/test/<id>.sh; the floor's no-browser
# run is the one id that is not a file under shared/test/.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
id="${1:-}"
[ -n "$id" ] || { echo "usage: run-suite.sh <suite-id>" >&2; exit 2; }
case "$id" in
  floor-no-browser) exec "$ROOT/fleet-floor/test/run.sh" --no-browser ;;
  */*|*) 
    [ -f "$ROOT/shared/test/$id.sh" ] || { echo "run-suite.sh: no suite '$id' (shared/test/$id.sh)" >&2; exit 2; }
    exec bash "$ROOT/shared/test/$id.sh" ;;
esac
