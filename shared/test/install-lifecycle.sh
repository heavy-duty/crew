#!/usr/bin/env bash
# shared/test/install-lifecycle.sh — real, OFFLINE installs of the crew CLI
# against the tree under test (no network, no root). Runs in CI (ci-shell.yml)
# and by hand. Asserts the versioned layout, root-resolution through the
# `current` symlink, coexistence/flip, the converging re-run, and — the
# regression codex-bot and grok-bot required on #95 — that an interrupted
# `CREW_REINSTALL` of the ACTIVE default never leaves `current` resolving to
# nothing.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"            # repo root: the crew tree to install
SRC="${CREW_LIFECYCLE_SOURCE:-$ROOT}"
INSTALL="$ROOT/install.sh"

PASS=0 FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
same()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$2' got '$3')"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Hosted runners may carry an ambient XDG_CONFIG_HOME. Keep one deliberately
# different from every synthetic caller below: caller-identity assertions must
# bind both HOME and its higher-precedence XDG config root, or the first init
# leaks state that makes the later examples-fallback case look configured.
export XDG_CONFIG_HOME="$WORK/ambient-xdg"

# #615's uid branch is pure path resolution, so drive the exact source block
# under a shim id instead of requiring root. Fail closed on the extraction:
# trusting output from the wrong if/else would make every path assertion noise.
if bash -n "$INSTALL"; then ok "installer-is-valid-bash"; else bad "installer-is-valid-bash"; fi
ID_SHIM="$WORK/id-shim"; mkdir -p "$ID_SHIM"
cat >"$ID_SHIM/id" <<'SHIM'
#!/usr/bin/env bash
case "${1:-}" in
  -u) printf '%s\n' "${FAKE_UID:-1000}" ;;
  *) exit 0 ;;
esac
SHIM
chmod +x "$ID_SHIM/id"
DEST_BLOCK="$WORK/dest-block.sh"
awk '/id -u.*-eq 0/{found=1} found{print} found&&/^fi$/{exit}' "$INSTALL" >"$DEST_BLOCK"
# Expand when the extracted block runs, not while this line writes it.
# shellcheck disable=SC2016
printf '\nprintf "DEST=%%s BINDIR=%%s\\n" "$DEST" "$BINDIR"\n' >>"$DEST_BLOCK"
if grep -qF /opt/crew "$DEST_BLOCK" && bash -n "$DEST_BLOCK"; then
  ok "dest-block-extracted"
else
  bad "dest-block-extracted"
fi
resolve_dest() { # <uid> [environment assignments]
  local uid="$1"; shift
  env FAKE_UID="$uid" HOME=/home/tester PATH="$ID_SHIM:$PATH" "$@" bash "$DEST_BLOCK"
}
same "root-resolves-system-layout" "DEST=/opt/crew BINDIR=/usr/local/bin" "$(resolve_dest 0)"
same "nonroot-resolves-user-layout" "DEST=/home/tester/.local/share/crew BINDIR=/home/tester/.local/bin" "$(resolve_dest 1000)"
same "root-CREW_HOME-wins" "DEST=/srv/crew BINDIR=/usr/local/bin" "$(resolve_dest 0 CREW_HOME=/srv/crew)"
same "root-CREW_BIN-wins" "DEST=/opt/crew BINDIR=/srv/bin" "$(resolve_dest 0 CREW_BIN=/srv/bin)"
same "nonroot-CREW_HOME-wins" "DEST=/srv/crew BINDIR=/home/tester/.local/bin" "$(resolve_dest 1000 CREW_HOME=/srv/crew)"
same "nonroot-CREW_BIN-wins" "DEST=/home/tester/.local/share/crew BINDIR=/srv/bin" "$(resolve_dest 1000 CREW_BIN=/srv/bin)"

# The root-only pieces cannot be exercised by this no-root lifecycle suite, so
# bind their placement structurally: the chmod must sit in its own uid guard,
# and root's checkout warning must use SUDO_USER's resolved home.
# The patterns name installer variables literally.
# shellcheck disable=SC2016
if grep -qF 'chmod -R a+rX "$DEST"' "$INSTALL" &&
   grep -B2 'chmod -R a+rX' "$INSTALL" | grep 'id -u.*-eq 0' >/dev/null; then
  ok "global-tree-chmod-is-root-guarded"
else
  bad "global-tree-chmod-is-root-guarded"
fi
# shellcheck disable=SC2016
if grep -qF 'checkout_home="$sudo_home"' "$INSTALL" &&
   grep -qF '$checkout_home/crew/cli/crew' "$INSTALL"; then
  ok "root-checkout-warning-uses-sudo-user-home"
else
  bad "root-checkout-warning-uses-sudo-user-home"
fi

# Hermetic: consent on, and HOME points into the scratch so the ~/crew
# checkout-naming probe never sees the runner's real home.
export CREW_YES=1 HOME="$WORK"
export CREW_HOME="$WORK/share" CREW_BIN="$WORK/bin"

VA=0.0.0-lifecycle-a VB=0.0.0-lifecycle-b
# The copy carries only tracked content (#536 D1): the files git tracks, as
# they stand in the working tree, so an uncommitted edit is still the thing
# under test; a new file is under test once it is `git add`ed. A plain filesystem copy also carried ignored paths — a real
# fleet-floor/server/floor/__pycache__/ or a node_modules/ — into every
# fixture, and the refusal case below, which disables pruning on purpose, then
# refused the developer's path instead of the one it planted. CI's fresh
# checkout never has one, so only a human running the suite ever saw that red.
# A source that is not a git work tree (an unpacked tarball) has no ignored
# paths to leak, and is copied whole.
mk_src() {  # <dir> <version> — the tree under test, with VERSION rewritten
  mkdir -p "$1"
  if git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Tracked files only (#536 D1), as they are on disk, uncommitted edits
    # included. --ignore-failed-read covers a tracked file deleted in the work
    # tree and nothing else: any other failure of the three stops the suite.
    git -C "$SRC" ls-files -z --cached \
      | tar -C "$SRC" --null --ignore-failed-read -T - -cf - \
      | tar -xf - -C "$1"
    local st="${PIPESTATUS[*]}"
    [ "$st" = "0 0 0" ] || { echo "mk_src: copying $SRC's tracked files into $1 failed (status $st)" >&2; exit 1; }
  else
    tar -C "$SRC" --exclude=.git -cf - . | tar -xf - -C "$1"
  fi
  printf '%s\n' "$2" > "$1/VERSION"
  # A stand-in for the VCS state a real checkout carries. Without it the
  # fixture is the one tree install.sh's oldest exclusion could never be
  # observed on — the source has no .git to leave behind, so the assertion
  # below would pass whether or not the installer still excludes it.
  mkdir -p "$1/.git" && : > "$1/.git/HEAD"
}
# #536's regression, in the suite and not only on a developer's checkout: a
# source tree carrying an ignored __pycache__/ and node_modules/ beside its
# tracked files. CI's clean checkout has neither, so without this case a
# reverted mk_src (a filesystem copy again) stays green everywhere.
MK536="$WORK/mk536-src"
mkdir -p "$MK536/lib/__pycache__" "$MK536/lib/node_modules/x"
printf '__pycache__/\nnode_modules/\n' >"$MK536/.gitignore"
printf 'tracked\n' >"$MK536/lib/kept.sh"
: >"$MK536/lib/__pycache__/m.cpython-311.pyc"; : >"$MK536/lib/node_modules/x/index.js"
printf 'stray\n' >"$MK536/lib/untracked.sh"
git -C "$MK536" init -q && git -C "$MK536" add .gitignore lib/kept.sh \
  && git -C "$MK536" -c user.name=t -c user.email=t@t commit -qm seed
MK536_KEEP="$SRC"; SRC="$MK536"; mk_src "$WORK/mk536-out" 0.0.0-mk536; SRC="$MK536_KEEP"
MK536_SEEN="$(cd "$WORK/mk536-out" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | paste -sd' ')"
same mk-src-copies-tracked-files-only "./.gitignore ./VERSION ./lib/kept.sh" "$MK536_SEEN"
rm -rf "$MK536" "$WORK/mk536-out"

SA="$WORK/src-a"; SB="$WORK/src-b"; SC="$WORK/src-clean"
mk_src "$SA" "$VA"
mk_src "$SB" "$VB"
mk_src "$SC" "$VA"

# Drive a complete install through the root arm without root privileges. The
# id/getent shims choose the arm and resolve SUDO_USER; CREW_HOME/CREW_BIN keep
# every write in scratch. The test process remains non-root when it traverses
# and executes the resulting tree, which is the boundary the global layout is
# for. Mode assertions inspect the OTHER-user bits rather than relying on this
# fixture's ownership.
GLOBAL_HOME="$WORK/global-share" GLOBAL_BIN="$WORK/global-bin"
ROOT_PERSONA="$WORK/root-persona" OPERATOR_HOME="$WORK/operator-home"
mkdir -p "$ROOT_PERSONA" "$OPERATOR_HOME/.local/share/crew/current/cli" \
  "$OPERATOR_HOME/crew/cli" "$OPERATOR_HOME/crew/.git"
: >"$OPERATOR_HOME/.local/share/crew/current/cli/crew"
: >"$OPERATOR_HOME/crew/cli/crew"
cat >"$ID_SHIM/getent" <<SHIM
#!/usr/bin/env bash
if [ "\${1:-}" = passwd ] && [ "\${2:-}" = operator ]; then
  printf 'operator:x:1000:1000:Operator:$OPERATOR_HOME:/bin/bash\\n'
fi
SHIM
chmod +x "$ID_SHIM/getent"
root_install() {
  FAKE_UID=0 HOME="$ROOT_PERSONA" SUDO_USER=operator PATH="$ID_SHIM:$PATH" \
    CREW_HOME="$GLOBAL_HOME" CREW_BIN="$GLOBAL_BIN" CREW_INSTALL_SOURCE="$1" \
    bash "$INSTALL"
}
root_install_out="$(root_install "$SA" 2>&1)"
case "$root_install_out" in
  *"PER-USER install"*"$OPERATOR_HOME/.local/share/crew"*"PATH order"*)
    ok "root-reports-per-user-coexistence" ;;
  *) bad "root-reports-per-user-coexistence (got '$root_install_out')" ;;
esac
case "$root_install_out" in
  *"crew git checkout"*"$OPERATOR_HOME/crew"*) ok "root-checkout-warning-names-sudo-user-home" ;;
  *) bad "root-checkout-warning-names-sudo-user-home (got '$root_install_out')" ;;
esac
world_bad="$(find "$GLOBAL_HOME" -type d ! -perm -0005 -print -quit; \
  find "$GLOBAL_HOME" -type f ! -perm -0004 -print -quit)"
if [ -z "$world_bad" ] && [ -x "$GLOBAL_HOME/current/cli/crew" ] &&
   HOME="$OPERATOR_HOME" "$GLOBAL_BIN/crew" --version >/dev/null 2>&1; then
  ok "nonroot-traverses-and-executes-global-tree"
else
  bad "nonroot-traverses-and-executes-global-tree (blocked at '${world_bad:-execution}')"
fi

# The caller's HOME, not the shared tree's installing HOME, selects and creates
# fleet configuration. Seed a conflicting root roster, initialize the operator
# normally, and make a read prove it selected the operator definition.
mkdir -p "$ROOT_PERSONA/.config"
cp -a "$GLOBAL_HOME/current/examples" "$ROOT_PERSONA/.config/crew"
printf 'root-only claude builder examples\n' >"$ROOT_PERSONA/.config/crew/fleet.roster"
if HOME="$OPERATOR_HOME" XDG_CONFIG_HOME="$OPERATOR_HOME/.config" \
   "$GLOBAL_BIN/crew" init >/dev/null 2>&1 &&
   [ -f "$OPERATOR_HOME/.config/crew/fleet.roster" ]; then
  printf 'operator-only claude builder examples\n' >"$OPERATOR_HOME/.config/crew/fleet.roster"
  if HOME="$OPERATOR_HOME" XDG_CONFIG_HOME="$OPERATOR_HOME/.config" \
     CREW_EXPECT_OPERATOR_CONFIG=1 \
     "$GLOBAL_BIN/crew" profiles >/dev/null 2>&1 &&
     grep -q '^operator-only ' "$OPERATOR_HOME/.config/crew/fleet.roster" &&
     grep -q '^root-only ' "$ROOT_PERSONA/.config/crew/fleet.roster"; then
    ok "global-tree-uses-caller-config"
  else
    bad "global-tree-uses-caller-config"
  fi
else
  bad "global-tree-uses-caller-config (crew init did not create caller config)"
fi

# Complete the second global version, then model a root-owned install by
# removing this non-root fixture owner's write bits. Both writer verbs must
# refuse at their explicit ownership guard, before mv/rm emits a bare error.
root_install "$SB" >/dev/null 2>&1
chmod -R a-w "$GLOBAL_HOME"
if global_use_out="$(HOME="$OPERATOR_HOME" "$GLOBAL_BIN/crew" use "$VA" 2>&1)"; then
  bad "nonroot-use-refuses-root-owned-tree"
elif [[ "$global_use_out" == *"system crew install is root-owned"*"run 'crew use' as root"* ]]; then
  ok "nonroot-use-refuses-root-owned-tree"
else
  bad "nonroot-use-refuses-root-owned-tree (got '$global_use_out')"
fi
if global_uninstall_out="$(HOME="$OPERATOR_HOME" "$GLOBAL_BIN/crew" uninstall "$VA" --force 2>&1)"; then
  bad "nonroot-uninstall-refuses-root-owned-tree"
elif [[ "$global_uninstall_out" == *"system crew install is root-owned"*"run 'crew uninstall' as root"* ]]; then
  ok "nonroot-uninstall-refuses-root-owned-tree"
else
  bad "nonroot-uninstall-refuses-root-owned-tree (got '$global_uninstall_out')"
fi
# Restore fixture ownership modes so the no-root trap can remove its contents.
chmod -R u+w "$GLOBAL_HOME"

# The other direction uses the real non-root arm. Rewrite only the hard-coded
# system probe in a copied source so the no-root suite can stand both tiers up
# in scratch, then require the warning from the actual installer flow.
NONROOT_SRC="$WORK/nonroot-src"; mk_src "$NONROOT_SRC" 0.0.0-lifecycle-user
sed -i "s|/opt/crew|$GLOBAL_HOME|g" "$NONROOT_SRC/install.sh"
NONROOT_HOME="$WORK/nonroot-home"
nonroot_install_out="$(HOME="$NONROOT_HOME" CREW_HOME="$NONROOT_HOME/share" \
  CREW_BIN="$NONROOT_HOME/bin" CREW_INSTALL_SOURCE="$NONROOT_SRC" \
  bash "$NONROOT_SRC/install.sh" 2>&1)"
case "$nonroot_install_out" in
  *"GLOBAL install"*"$GLOBAL_HOME"*"PATH order"*) ok "nonroot-reports-global-coexistence" ;;
  *) bad "nonroot-reports-global-coexistence (got '$nonroot_install_out')" ;;
esac

# No invocation other than init may create an operator definition. A mutating
# command on the shipped examples must still refuse and leave HOME untouched.
FALLBACK_HOME="$WORK/fallback-home" FALLBACK_BIN="$WORK/fallback-bin"
mkdir -p "$FALLBACK_HOME" "$FALLBACK_BIN"
cat >"$FALLBACK_BIN/box" <<'SHIM'
#!/usr/bin/env bash
[ "${1:-}" = list ] && printf '[]\n'
exit 0
SHIM
chmod +x "$FALLBACK_BIN/box"
if fallback_out="$(cd "$WORK" && HOME="$FALLBACK_HOME" \
  XDG_CONFIG_HOME="$FALLBACK_HOME/.config" PATH="$FALLBACK_BIN:$PATH" \
  "$GLOBAL_BIN/crew" up 2>&1)"; then
  bad "examples-fallback-mutating-verb-refuses"
elif [[ "$fallback_out" == *"crew init"* ]] && [ ! -e "$FALLBACK_HOME/.config/crew" ]; then
  ok "examples-fallback-mutating-verb-refuses"
else
  bad "examples-fallback-mutating-verb-refuses (got '$fallback_out')"
fi

# The builder checkout differs from the clean one only by ignored dependency
# trees. Both a root dependency and one below a shipped directory exercise the
# repository-wide rule rather than an anchored root-only tar exclusion.
mkdir -p "$SA/node_modules/root-dep" "$SA/shared/lib/node_modules/nested-dep"
printf 'root dependency\n' >"$SA/node_modules/root-dep/index.js"
printf 'nested dependency\n' >"$SA/shared/lib/node_modules/nested-dep/index.js"
install_from() { CREW_INSTALL_SOURCE="$1" bash "$INSTALL" >/dev/null 2>&1; }

# The checkout and the minimised product tree load the same exclusion set:
# the former derives it from .gitignore, while the latter uses the documented
# fallback because .gitignore is itself repository furniture.
# shellcheck disable=SC1091
source "$ROOT/shared/lib/install-payload.sh"
install_payload_load_ignore_patterns "$ROOT"
derived_patterns="$(printf '%s\n' "${INSTALL_PAYLOAD_IGNORE_PATTERNS[@]}")"
fallback_root="$WORK/fallback-root"; mkdir -p "$fallback_root"
install_payload_load_ignore_patterns "$fallback_root"
fallback_patterns="$(printf '%s\n' "${INSTALL_PAYLOAD_IGNORE_PATTERNS[@]}")"
same "checkout-and-installed-policy-agree" "$derived_patterns" "$fallback_patterns"

# Feed both installers one extra repository-wide ignore rule. The root
# installer must omit matching payload files, while the shared installer must
# refuse when its explicit copy surface selects one. This is behavioral parity:
# deleting either installer's enforcement makes one of these cases fail.
PARITY_SRC="$WORK/parity-src"
mkdir -p "$PARITY_SRC"
tar -C "$SC" -cf - . | tar -xf - -C "$PARITY_SRC"
printf '\n*.conf\n' >>"$PARITY_SRC/.gitignore"
VP=0.0.0-lifecycle-parity
printf '%s\n' "$VP" >"$PARITY_SRC/VERSION"
PARITY_HOME="$WORK/parity-home"
parity_installed=0 parity_conf=""
if HOME="$PARITY_HOME" CREW_HOME="$PARITY_HOME/share" CREW_BIN="$PARITY_HOME/bin" \
   CREW_INSTALL_SOURCE="$PARITY_SRC" bash "$INSTALL" >/dev/null 2>&1; then
  parity_installed=1
  parity_conf="$(find "$PARITY_HOME/share/versions/$VP" -name '*.conf' -print -quit)"
fi
if [ "$parity_installed" -eq 1 ] && [ -z "$parity_conf" ] &&
   [ -d "$PARITY_HOME/share/versions/$VP" ]; then
  ok "root-installer-applies-parity-fixture"
else
  bad "root-installer-applies-parity-fixture (still shipped: ${parity_conf:-<install failed>})"
fi
PARITY_DUTY="$WORK/parity-duty"
if parity_out="$(DUTY_DIR="$PARITY_DUTY" bash "$PARITY_SRC/shared/install.sh" \
    --agent claude --role reviewer 2>&1)"; then
  bad "shared-installer-refuses-parity-fixture"
elif grep -Fq \
     'refusing payload: known-excluded path selected for install: shared/conf/agents/claude.conf' \
     <<<"$parity_out" && [ ! -e "$PARITY_DUTY/conf/agents/claude.conf" ]; then
  ok "shared-installer-refuses-parity-fixture"
else
  bad "shared-installer-refuses-parity-fixture (got '$parity_out')"
fi

# THE PAYLOAD (#365) — the installed tree is the product, not the repository.
# Every assertion here reads the INSTALLED TREE, never install.sh's exclude
# list: a list with no assertion is re-broken by the next directory somebody
# adds, silently, because the install still works and is only fat again. Both
# directions, because either one alone passes on a catastrophe — an empty tree
# carries no excluded path, and the whole repository carries every kept one.
#
# Parameterised because install.sh acquires its tree TWO ways and the rule is a
# property of the tree, not of the branch that got it: filtering the tar left
# the tarball branch — the `gh` and `curl` channels — installing the whole
# repository (claude-bot and codex-bot, round 1). Both channels answer to this.
assert_payload() {  # <case-prefix> <installed tree, symlink or version dir>
  local prefix="$1" tree="$2" p shipped="" absent="" kb
  for p in .git .gitignore .github .box .ceremony AGENTS.md CONTRIBUTING.md changelog.d \
           dist drill drills postmortems protocols shared/test \
           fleet-floor/dev fleet-floor/src fleet-floor/build.sh fleet-floor/test; do
    [ -e "$tree/$p" ] && shipped="$shipped $p"
  done
  if [ -z "$shipped" ]; then
    ok "$prefix-excludes-repository-furniture"
  else
    bad "$prefix-excludes-repository-furniture (still shipped:$shipped)"
  fi
  # The console must not go out with the bathwater: these are what an installed
  # tree RUNS, and the minimisation is only correct while every one survives.
  # `shared/bin` is named by its FILES, not as a directory — it is the engine
  # `crew upgrade` pushes to every box, and an `--exclude=./shared/bin` would
  # otherwise pass every assertion here (claude-bot, round 1): the deny list
  # ignores it, the bound only shrinks, and no verb below reads it.
  for p in cli/crew VERSION install.sh examples/fleet.roster examples/fleet.conf \
           shared/install.sh shared/lib/common.sh shared/conf/roles \
           shared/conf/agents shared/prompts \
           shared/bin/engine-manifest.sh shared/bin/tick.sh shared/bin/duty.sh \
           fleet-floor/index.html fleet-floor/server/floor.py \
           fleet-floor/server/floor/server.py; do
    [ -e "$tree/$p" ] || absent="$absent $p"
  done
  if [ -z "$absent" ]; then
    ok "$prefix-keeps-what-the-tree-runs"
  else
    bad "$prefix-keeps-what-the-tree-runs (missing:$absent)"
  fi
  # The bound, not a target: a regression is a red test rather than a judgement
  # call. Measured with -L, so passing `current` measures the tree it resolves
  # to — a bare `du -sk` on a symlink reports the link, which would pass on a
  # tree of any size (#365). This is also the only assertion here that catches
  # the OTHER direction of the same defect: the deny list reds when an entry is
  # dropped, and says nothing about the next fat directory somebody adds, which
  # lands here instead.
  kb="$(du -skL "$tree" | cut -f1)"
  if [ "$kb" -lt 3072 ]; then
    ok "$prefix-under-3M ($kb KiB)"
  else
    bad "$prefix-under-3M (installed tree is $kb KiB)"
  fi
}

# 1. fresh install → PATH link resolves under versions/, and the installed crew
#    runs THROUGH the current symlink (which is what proves $CREW_ROOT resolved
#    into the versioned tree, not $BINDIR).
install_from "$SA"
link="$(readlink -f "$CREW_BIN/crew" 2>/dev/null || true)"
case "$link" in
  */versions/"$VA"/cli/crew) ok "fresh-install-under-versions" ;;
  *) bad "fresh-install-under-versions (got '$link')" ;;
esac
if ( cd "$WORK" && "$CREW_BIN/crew" help >/dev/null 2>&1 ); then
  ok "installed-crew-runs-through-symlink"
else
  bad "installed-crew-runs-through-symlink"
fi

# 1b. THE PAYLOAD (#365), through the DIRECTORY channel — measured on
#     `current`, the path an operator's `crew` actually resolves.
VTREE="$CREW_HOME/versions/$VA"
assert_payload payload "$CREW_HOME/current"
node_modules_path="$(find "$VTREE" -name node_modules -print -quit)"
if [ -z "$node_modules_path" ]; then
  ok "payload-excludes-node-modules-at-every-depth"
else
  bad "payload-excludes-node-modules-at-every-depth (still shipped: ${node_modules_path#"$VTREE"/})"
fi

# The ignored dependency trees are the only source difference, so the product
# trees must be byte-identical (provenance is source-dependent by contract).
CLEAN_HOME="$WORK/clean-home"
HOME="$CLEAN_HOME" CREW_HOME="$CLEAN_HOME/share" CREW_BIN="$CLEAN_HOME/bin" \
  CREW_INSTALL_SOURCE="$SC" bash "$INSTALL" >/dev/null 2>&1
if diff -r --exclude=INSTALLED_FROM "$VTREE" "$CLEAN_HOME/share/versions/$VA" >/dev/null 2>&1; then
  ok "builder-and-clean-checkouts-install-byte-identically"
else
  bad "builder-and-clean-checkouts-install-byte-identically"
fi

# Pruning is not the trust boundary. Disable only the copied installer's prune
# invocation, feed it a tarball carrying node_modules, and require the
# independent validator to refuse before installation with the path named.
REFUSE_SRC="$WORK/refuse-src"
mkdir -p "$REFUSE_SRC"
tar -C "$SC" -cf - . | tar -xf - -C "$REFUSE_SRC"
mkdir -p "$REFUSE_SRC/shared/lib/node_modules/survivor"
printf 'must be refused\n' >"$REFUSE_SRC/shared/lib/node_modules/survivor/index.js"
# shellcheck disable=SC2016  # mutate the copied invocation, not this fixture's variable
sed -i 's/^prune_payload "\$EXTRACTED"$/# fixture: leave the payload unpruned/' "$REFUSE_SRC/install.sh"
REFUSE_TARBALL="$WORK/refuse.tgz"
tar -C "$WORK" -czf "$REFUSE_TARBALL" "${REFUSE_SRC##*/}"
REFUSE_HOME="$WORK/refuse-home"
if refuse_out="$(HOME="$REFUSE_HOME" CREW_HOME="$REFUSE_HOME/share" CREW_BIN="$REFUSE_HOME/bin" \
  CREW_INSTALL_SOURCE="$REFUSE_TARBALL" bash "$REFUSE_SRC/install.sh" 2>&1)"; then
  bad "surviving-known-exclusion-is-refused"
elif grep -Fq \
     'known-excluded path survived construction: shared/lib/node_modules' \
     <<<"$refuse_out" &&
     [ ! -e "$REFUSE_HOME/share/versions/$VA" ]; then
  ok "surviving-known-exclusion-is-refused"
else
  bad "surviving-known-exclusion-is-refused (got '$refuse_out')"
fi

# The read-only verbs still answer from the minimised tree — `--version` off
# VERSION, `profiles` off shared/conf/{roles,agents}.
same "installed-crew-reports-version" "crew $VA ($VTREE)" \
  "$("$CREW_BIN/crew" --version 2>/dev/null)"
if profiles_out="$("$CREW_BIN/crew" profiles 2>/dev/null)" && [ -n "$profiles_out" ]; then
  ok "installed-crew-reads-shipped-profiles"
else
  bad "installed-crew-reads-shipped-profiles (got '$profiles_out')"
fi

# …and the console still SERVES from it. This is the assertion that stops the
# minimisation quietly taking fleet-floor with it: `crew floor` resolves
# index.html and server/floor.py out of $CREW_ROOT, and it only gets that far
# through an operator config `crew init` scaffolds from the shipped examples/
# — so one HTTP 200 exercises three kept paths at once. A `box` stub satisfies
# `need_box` for this one invocation only; the console polls it and finds no
# fleet, which changes nothing about whether the page is served.
floorbox="$WORK/floorbox"; mkdir -p "$floorbox"
cat >"$floorbox/box" <<'SHIM'
#!/usr/bin/env bash
[ "${1:-}" = list ] && printf '[]\n'
exit 0
SHIM
chmod +x "$floorbox/box"
CFG="$WORK/opcfg"
"$CREW_BIN/crew" init "$CFG" >/dev/null 2>&1
# Each precondition names its OWN cause. The port probe is python3's, and so is
# `crew floor` itself (cli/crew dies with "python3 is required"), so a box
# without it must not be reported as a console that failed to serve — that red
# would send a reader to fleet-floor for a missing interpreter (claude-bot,
# round 1). CI has python3, so this is the bare-box case only.
port=0
if ! command -v python3 >/dev/null 2>&1; then
  bad "installed-tree-serves-the-console (python3 is required, and this host has none — 'crew floor' would die the same way)"
elif ! [ -f "$CFG/fleet.roster" ]; then
  bad "installed-tree-serves-the-console ('crew init' wrote no roster to $CFG — the console never gets as far as the page)"
else
  port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null || echo 0)"
  [ "$port" -gt 0 ] || bad "installed-tree-serves-the-console (no free loopback port to bind)"
fi
if [ "$port" -gt 0 ]; then
  PATH="$floorbox:$PATH" CREW_CONFIG_DIR="$CFG" CREW_FLOOR_PASS=lifecycle \
    "$CREW_BIN/crew" floor --local --port "$port" >"$WORK/floor.log" 2>&1 &
  floor_srv=$!
  served=0
  for _ in $(seq 1 60); do
    kill -0 "$floor_srv" 2>/dev/null || break
    if python3 - "$port" <<'PY' >/dev/null 2>&1
import base64, sys, urllib.request
req = urllib.request.Request("http://127.0.0.1:%s/" % sys.argv[1])
req.add_header("Authorization", "Basic " + base64.b64encode(b"operator:lifecycle").decode())
body = urllib.request.urlopen(req, timeout=3).read().decode("utf-8", "replace")
sys.exit(0 if "<title>Fleet Floor</title>" in body else 1)
PY
    then served=1; break; fi
    sleep 0.5
  done
  kill "$floor_srv" 2>/dev/null || true
  wait "$floor_srv" 2>/dev/null || true
  if [ "$served" -eq 1 ]; then
    ok "installed-tree-serves-the-console"
  else
    bad "installed-tree-serves-the-console ($(tail -3 "$WORK/floor.log" 2>/dev/null | tr '\n' ' '))"
  fi
fi
rm -rf "$CFG"

# 2. re-run the same version → no-op, current unchanged
before="$(readlink "$CREW_HOME/current")"
install_from "$SA"
same "reinstall-same-version-is-noop" "$before" "$(readlink "$CREW_HOME/current")"

# 3. install a second version → both coexist, current flips to it
install_from "$SB"
if [ -d "$CREW_HOME/versions/$VA" ] && [ -d "$CREW_HOME/versions/$VB" ]; then
  ok "two-versions-coexist"
else
  bad "two-versions-coexist"
fi
same "new-version-becomes-current" "versions/$VB" "$(readlink "$CREW_HOME/current")"

# 4. re-run the OLDER version → current must NOT move
install_from "$SA"
same "reinstall-older-does-not-flip" "versions/$VB" "$(readlink "$CREW_HOME/current")"

# 5. CREW_REINSTALL of a NON-default version → replaces its tree, current stays
CREW_REINSTALL=1 install_from "$SA"
same "reinstall-nondefault-current-stays" "versions/$VB" "$(readlink "$CREW_HOME/current")"

# 6. THE REGRESSION (#95 test plan; codex-bot + grok-bot): CREW_REINSTALL of the
#    ACTIVE default, KILLED the instant the live version dir is renamed aside —
#    the between-the-two-renames point — must leave `current` still resolving to
#    a crew tree, never dangling. A `mv` shim on PATH performs the aside-rename
#    (dest …/versions/<v>.old.<pid>) and then SIGKILLs the installer at that
#    exact point.
shim="$WORK/shim"; mkdir -p "$shim"
real_mv="$(command -v mv)"
cat > "$shim/mv" <<SHIM
#!/usr/bin/env bash
last="\${@: -1}"
"$real_mv" "\$@"; rc=\$?
case "\$last" in */versions/*.old.*) kill -KILL "\$PPID" 2>/dev/null ;; esac
exit \$rc
SHIM
chmod +x "$shim/mv"
# current is on $VB (the active default); reinstall $VB under the killer shim.
# Backgrounded and waited so the shell's own "Killed" job notice stays quiet —
# the SIGKILL is the point of the test, not an error.
PATH="$shim:$PATH" CREW_REINSTALL=1 CREW_INSTALL_SOURCE="$SB" bash "$INSTALL" >/dev/null 2>&1 &
wait "$!" 2>/dev/null || true
if [ -e "$CREW_HOME/current/cli/crew" ]; then
  ok "interrupted-reinstall-keeps-current-resolvable"
else
  bad "interrupted-reinstall-keeps-current-resolvable (current -> '$(readlink "$CREW_HOME/current" 2>/dev/null || echo '<none>')' dangles)"
fi

# 7. recovery: a normal install after the interrupted reinstall heals `current`
#    back onto the canonical version and reaps the orphaned old-tree scratch.
install_from "$SB"
same "post-interrupt-heals-to-canonical" "versions/$VB" "$(readlink "$CREW_HOME/current")"
if ( cd "$WORK" && "$CREW_BIN/crew" help >/dev/null 2>&1 ); then
  ok "post-interrupt-crew-runs"
else
  bad "post-interrupt-crew-runs"
fi

# 8. A legitimate version whose name RESEMBLES swap scratch (valid_version
#    accepts dots + digits, so `1.0.new.999` is a sane version name) must
#    survive a later normal install — the scratch reaper keys on identity
#    (VERSION == basename), not on the name shape (codex-bot, #95).
#    The reaper reads `current` at entry, so it also spares whatever `current`
#    resolves to; to prove guard 2 (VERSION==basename) and not merely guard 1
#    (is-current), `current` must have moved OFF the lookalike before the
#    reaping install: install it, flip past it with a fresh version, then let a
#    no-op re-run's reaper fire while `current` points elsewhere.
VS=1.0.new.999 VC=0.0.0-lifecycle-c
SS="$WORK/src-scratchlike"; SC="$WORK/src-c"
mk_src "$SS" "$VS"; mk_src "$SC" "$VC"
install_from "$SS"                       # current -> VS
sentinel="$CREW_HOME/versions/$VS/SENTINEL"
: > "$sentinel"
install_from "$SC"                       # fresh install flips current -> VC
same "flip-off-scratch-lookalike" "versions/$VC" "$(readlink "$CREW_HOME/current")"
install_from "$SA"                       # no-op re-run; its reaper fires, current=VC
if [ -d "$CREW_HOME/versions/$VS" ] && [ -e "$sentinel" ]; then
  ok "scratch-lookalike-version-survives-reaper"
else
  bad "scratch-lookalike-version-survives-reaper (tree/sentinel reaped)"
fi

# 9. #96's three operator verbs, still fully offline. A stub box CLI makes
# hired engines drivable without a fleet; `exec` prints the requested box's
# stamp from a fixture file, while `list --json` supplies the names.
vshim="$WORK/version-shim"; mkdir -p "$vshim"
BOX_ENGINES="$WORK/box-engines"; export BOX_ENGINES
cat >"$vshim/box" <<'SHIM'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    if [ "${2:-}" = --json ]; then
      awk '{printf "%s{\"name\":\"%s\"}", sep, $1; sep=","} BEGIN{printf "["} END{print "]"}' "$BOX_ENGINES"
    fi
    ;;
  exec)
    name="${2:-}"
    awk -v name="$name" '$1 == name {$1=""; sub(/^ /, ""); print; exit}' "$BOX_ENGINES"
    ;;
esac
SHIM
chmod +x "$vshim/box"
export PATH="$vshim:$CREW_BIN:$PATH"
: >"$BOX_ENGINES"

versions_out="$("$CREW_HOME/versions/$VA/cli/crew" versions 2>&1)"
case "$versions_out" in
  *"$VA"*"(running)"*"$VC"*"(current)"*) ok "versions-marks-running-and-current" ;;
  *) bad "versions-marks-running-and-current (got '$versions_out')" ;;
esac
case "$versions_out" in
  *"crew use <version>"*"re-run install.sh"*) ok "versions-names-switch-and-install-hints" ;;
  *) bad "versions-names-switch-and-install-hints" ;;
esac

# Existing hired boxes MUST NOT block a host switch. They are independent
# engines; the switch succeeds and reports exactly who was left behind.
printf 'claude-builder crew@%s (aaa)\nkimi-reviewer crew@%s (bbb)\n' "$VB" "$VC" >"$BOX_ENGINES"
if use_out="$("$CREW_BIN/crew" use "$VA" 2>&1)"; then
  ok "use-under-hired-boxes-flips"
else
  bad "use-under-hired-boxes-flips (got '$use_out')"
fi
case "$use_out" in
  *"switched to $VA"*claude-builder*"$VB"*kimi-reviewer*"$VC"*"crew upgrade --all"*)
    ok "use-names-skewed-boxes-and-remedy" ;;
  *) bad "use-names-skewed-boxes-and-remedy (got '$use_out')" ;;
esac
same "use-effective-same-shell" "crew $VA ($CREW_HOME/versions/$VA)" \
  "$("$CREW_BIN/crew" --version)"
same "use-effective-new-shell" "crew $VA ($CREW_HOME/versions/$VA)" \
  "$(HOME="$HOME" PATH="$PATH" bash -c 'crew --version')"

if current_out="$("$CREW_BIN/crew" uninstall "$VA" --force 2>&1)"; then
  bad "uninstall-current-refuses"
else
  case "$current_out" in *CURRENT*) ok "uninstall-current-refuses" ;; *) bad "uninstall-current-refuses (got '$current_out')" ;; esac
fi

# A process whose argv holds this version's floor path is a live-console
# interlock. The test process does not open a socket; only the held tree path
# matters to the uninstall guard.
floor_path="$CREW_HOME/versions/$VB/fleet-floor/server/floor.py"
bash -c 'exec -a "$1" sleep 60' _ "$floor_path" &
floor_pid=$!
if floor_out="$("$CREW_BIN/crew" uninstall "$VB" --force 2>&1)"; then
  bad "uninstall-live-floor-refuses"
else
  case "$floor_out" in *"live crew floor"*"$floor_pid"*) ok "uninstall-live-floor-refuses" ;; *) bad "uninstall-live-floor-refuses (got '$floor_out')" ;; esac
fi
kill "$floor_pid" 2>/dev/null || true
wait "$floor_pid" 2>/dev/null || true

# rm's rc is never the verdict. Make versions/ non-writable so rm can empty
# the target but cannot remove its name; the explicit absence re-check must
# say INCOMPLETE and return 1.
chmod 555 "$CREW_HOME/versions"
if incomplete_out="$("$CREW_BIN/crew" uninstall "$VB" --force 2>&1)"; then
  bad "uninstall-survivor-is-incomplete"
else
  case "$incomplete_out" in *INCOMPLETE*"$VB"*) ok "uninstall-survivor-is-incomplete" ;; *) bad "uninstall-survivor-is-incomplete (got '$incomplete_out')" ;; esac
fi
chmod 755 "$CREW_HOME/versions"
CREW_REINSTALL=1 install_from "$SB"
"$CREW_BIN/crew" use "$VA" >/dev/null 2>&1
if "$CREW_BIN/crew" uninstall "$VB" --force >/dev/null 2>&1 &&
   [ ! -e "$CREW_HOME/versions/$VB" ]; then
  ok "uninstall-other-removes-and-proves"
else
  bad "uninstall-other-removes-and-proves"
fi

ln -sfn versions/gone "$CREW_HOME/current"
if dangling_out="$("$CREW_HOME/versions/$VA/cli/crew" uninstall "$VC" --force 2>&1)"; then
  bad "uninstall-dangling-current-refuses"
else
  case "$dangling_out" in *"current is dangling"*) ok "uninstall-dangling-current-refuses" ;; *) bad "uninstall-dangling-current-refuses (got '$dangling_out')" ;; esac
fi
"$CREW_HOME/versions/$VA/cli/crew" use "$VA" >/dev/null 2>&1

# The installer suite exports CREW_YES=1 globally; clear it here because this
# assertion drives the default refusal, then prove the explicit force path.
if all_out="$(CREW_YES='' "$CREW_BIN/crew" uninstall --all 2>&1)"; then
  bad "uninstall-all-hired-refuses"
else
  case "$all_out" in
    *claude-builder*kimi-reviewer*"keeps running autonomously"*unattended*"crew down"*--force*CREW_YES*"console only"*"'crew status'"*)
      ok "uninstall-all-hired-refuses-and-explains" ;;
    *) bad "uninstall-all-hired-refuses-and-explains (got '$all_out')" ;;
  esac
fi
: >"$BOX_ENGINES"
if "$CREW_BIN/crew" uninstall --all --force >/dev/null 2>&1 &&
   [ ! -e "$CREW_HOME" ] && [ ! -L "$CREW_BIN/crew" ]; then
  ok "uninstall-all-removes-console-and-path-link"
else
  bad "uninstall-all-removes-console-and-path-link"
fi

# All three verbs distinguish a checkout from disposable install data.
for verb in versions use uninstall; do
  args=()
  [ "$verb" = use ] && args=("$VA")
  [ "$verb" = uninstall ] && args=(--all --force)
  if worktree_out="$("$ROOT/cli/crew" "$verb" "${args[@]}" 2>&1)"; then
    bad "$verb-working-tree-refuses"
  else
    case "$worktree_out" in *"working tree"*"$ROOT"*) ok "$verb-working-tree-refuses" ;; *) bad "$verb-working-tree-refuses (got '$worktree_out')" ;; esac
  fi
done

# THE OTHER ACQUISITION BRANCH (#365, round 1). install.sh takes a DIRECTORY or
# a TARBALL, and until this round only the directory branch was minimised — so
# `dist/fetch.sh` and `dist/curl-install.sh`, which both hand it a file,
# installed the whole repository while install.sh's own header said they did
# not. The regression assertion belongs where the branch is, so: the same three
# assertions against a tarball source.
#
# Packed the way GitHub's archive endpoint packs a tag — ONE top-level
# directory, which is what install.sh's `find -maxdepth 1 -type d` picks up —
# but carrying a `.git`, as a tarball rolled by hand from a checkout does. That
# shape is the only one on which the oldest exclusion is observable at all.
# Its own $CREW_HOME: the suite above has just uninstalled --all, and this
# channel's business is the payload, not the layout that is already asserted.
VT=0.0.0-lifecycle-tgz
TGZH="$WORK/tgz-home"
PACK="$WORK/tgz-pack"; mkdir -p "$PACK/crew-tgzsha"
tar -C "$SA" -cf - . | tar -xf - -C "$PACK/crew-tgzsha"
printf '%s\n' "$VT" > "$PACK/crew-tgzsha/VERSION"
tar -C "$PACK" -czf "$WORK/crew-src.tgz" crew-tgzsha
if HOME="$TGZH" CREW_HOME="$TGZH/share" CREW_BIN="$TGZH/bin" \
   CREW_INSTALL_SOURCE="$WORK/crew-src.tgz" bash "$INSTALL" >/dev/null 2>&1 &&
   [ -d "$TGZH/share/versions/$VT" ]; then
  ok "tarball-source-installs"
else
  bad "tarball-source-installs"
fi
assert_payload tarball-payload "$TGZH/share/current"
# …and the tree it laid down still runs, which is what says the prune took the
# furniture and nothing else.
same "tarball-installed-crew-reports-version" "crew $VT ($TGZH/share/versions/$VT)" \
  "$("$TGZH/bin/crew" --version 2>/dev/null)"

# THE PRUNE CANNOT LEAVE THE TREE IT WAS HANDED (#365, round 2). Minimising a
# tree that already exists means removing BY PATH, and `rm -rf -- "$root/…"`
# resolves every component but the last — so a source whose `shared` is a
# symlink had the install delete a directory outside the extracted tree and
# still exit 0 (codex-bot). This is that source, and what it asserts is what
# survives it: a sentinel OUTSIDE the tree, a refusal rather than a silent
# half-minimisation, and nothing laid down. The escape came in with the prune,
# so the assertion belongs beside the branch that introduced it.
#
# Its own $CREW_HOME, so "installed nothing" is a fact about this case and not
# a leftover from the ones above.
VS=0.0.0-lifecycle-sym
SYMH="$WORK/sym-home"
OUTSIDE="$WORK/sym-outside"; mkdir -p "$OUTSIDE/test"; : > "$OUTSIDE/test/sentinel"
SYMPACK="$WORK/sym-pack"; mkdir -p "$SYMPACK/crew-sym/cli"
# A real cli/crew and VERSION: install.sh checks for the first before pruning,
# so a fixture without it would be refused for the wrong reason entirely.
cp "$SRC/cli/crew" "$SYMPACK/crew-sym/cli/crew"
printf '%s\n' "$VS" > "$SYMPACK/crew-sym/VERSION"
ln -s "$OUTSIDE" "$SYMPACK/crew-sym/shared"
tar -C "$SYMPACK" -czf "$WORK/crew-sym.tgz" crew-sym
sym_out="$(HOME="$SYMH" CREW_HOME="$SYMH/share" CREW_BIN="$SYMH/bin" \
  CREW_INSTALL_SOURCE="$WORK/crew-sym.tgz" bash "$INSTALL" 2>&1)"
sym_rc=$?
# The one that matters: a file the installer was never pointed at is still there.
if [ -f "$OUTSIDE/test/sentinel" ]; then
  ok "symlinked-source-prune-stays-inside-the-tree"
else
  bad "symlinked-source-prune-stays-inside-the-tree (removed a path outside the source tree)"
fi
# Refused, and saying so. Skipping the prune instead would install the whole
# repository — the defect #365 exists to close — so silence is not the pass.
if [ "$sym_rc" -ne 0 ]; then
  case "$sym_out" in
    *"lies under a symlink"*) ok "symlinked-source-refused" ;;
    *) bad "symlinked-source-refused (exited $sym_rc, but not for this reason: '$sym_out')" ;;
  esac
else
  bad "symlinked-source-refused (installed it and exited 0)"
fi
if [ ! -e "$SYMH/share/versions" ]; then
  ok "symlinked-source-installs-nothing"
else
  bad "symlinked-source-installs-nothing (laid down: $(ls "$SYMH/share/versions"))"
fi

echo
echo "install-lifecycle: passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
