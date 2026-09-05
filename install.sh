#!/usr/bin/env bash
set -euo pipefail

# crew installer — puts the `crew` CLI on PATH in a VERSIONED layout under
# $DEST:
#
#   $DEST/versions/<version>/    one full tree per installed version
#   $DEST/current -> versions/<version>        the default version
#   $BINDIR/crew  -> $DEST/current/cli/crew     the PATH entry
#
# Versions install side by side: a NEW version installs beside the old one and
# becomes the default; re-running with an already-installed version is a
# converging no-op (CREW_REINSTALL=1 replaces that version's tree). `crew
# versions` / `crew use` / `crew uninstall` (heavy-duty/crew#96) manage them
# once they land; this installer lays the ground they stand on.
#
# PORTED FROM box's install.sh (heavy-duty/box#79; rig#35 is the proof the port
# works), with three crew-specific rules — each a deliberate divergence:
#
#   * INSTALL LOCATION DOES NOT CHOOSE THE OPERATOR. Root installs one shared,
#     read-only tree; non-root remains per-user. crew still acts as whoever
#     executes it: box resolves the restricted tier from the caller's uid and
#     groups, while crew keeps fleet configuration under that caller's HOME.
#     A global tree therefore changes where the CLI lives, not whose boxes or
#     roster it can reach.
#
#   * FLIP, then REPORT the skew — never refuse it. box refuses to move the
#     default while boxes exist (box#66), because there one version owns the
#     boxes. Here the axes are independent (heavy-duty/crew#93, finding 2): the
#     host CLI version and each box's engine version are different things, and
#     flipping the CLI touches no box. So a new version becomes the default and
#     the installer reports the boxes still to be converged, rather than
#     blocking a switch for a reason that does not apply here.
#
#   * The entrypoint is `cli/crew`, not `bin/crew` — crew's command lives in
#     cli/. The PATH link points there; cli/crew resolves its own real path
#     (readlink -f) so $CREW_ROOT lands in the versioned tree, not $BINDIR.
#
# THE INSTALL SOURCE IS A LOCAL TREE (heavy-duty/crew#98) — CREW_INSTALL_SOURCE, defaulting
# to the tree this script lives in — so a checkout installs itself, CI installs
# the code under review, and heavy-duty/crew#98's self-contained scp-able
# artifact installs by unpacking and pointing CREW_INSTALL_SOURCE at the
# result. Network distribution is #98's job, not this file's.

# Root installs globally so every operator can execute one system tree;
# non-root installs per-user exactly as before. CREW_HOME/CREW_BIN remain the
# explicit scripting overrides on both arms.
if [ "$(id -u)" -eq 0 ]; then
  DEST="${CREW_HOME:-/opt/crew}"
  BINDIR="${CREW_BIN:-/usr/local/bin}"
else
  DEST="${CREW_HOME:-$HOME/.local/share/crew}"
  BINDIR="${CREW_BIN:-$HOME/.local/bin}"
fi

log() { printf 'crew-install: %s\n' "$*"; }
warn() { printf 'crew-install: WARNING: %s\n' "$*" >&2; }
die() { printf 'crew-install: ERROR: %s\n' "$*" >&2; exit 1; }
# shellcheck disable=SC1091
source "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/shared/lib/version-skew.sh"
# The platform declaration and its reporter (#679 D12) — the same file cli/crew
# sources, so the two surfaces cannot disagree about the floor or the wording.
# shellcheck disable=SC1091
source "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/shared/lib/platform.sh"
# shellcheck disable=SC1091
source "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/shared/lib/install-payload.sh"

# Ask a yes/no question. Under a piped invocation THIS SCRIPT may be stdin, so
# prompts read /dev/tty directly. No terminal (CI, a pipe with no tty) → there
# is nobody to ask: CREW_YES=1 is the non-interactive consent contract; without
# it we refuse rather than silently assume consent.
confirm() {  # $1 = question
  [ -n "${CREW_YES:-}" ] && return 0
  if ! { true >/dev/tty; } 2>/dev/null; then
    die "no terminal to confirm on. Re-run with CREW_YES=1 to proceed non-interactively (assumes yes to all prompts)."
  fi
  local reply
  printf 'crew-install: %s [y/N] ' "$1" >/dev/tty
  read -r reply </dev/tty || reply=""
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# A version is a DIRECTORY NAME under versions/ — nothing else. One strict gate
# for every caller that builds a path from one: only [A-Za-z0-9._+-], no
# leading '.' or '-'. That forbids '/', '..'-escapes, spaces and
# option-lookalikes by construction — a crafted version dies HERE, never in an
# rm -rf or an ln. cli/crew carries a byte-identical copy; shared/test/run.sh
# diffs the two so the gates cannot drift.
valid_version() {
  case "$1" in
    ''|.*|-*) return 1 ;;
    *[!A-Za-z0-9._+-]*) return 1 ;;
  esac
  return 0
}

# Which boxes exist on this host? Prints their names (both tag generations) and
# succeeds when at least one exists. Bounded with `timeout` so a wedged daemon
# cannot hang the install (heavy-duty/crew#79 is exactly this hazard). Used
# ONLY to decide whether to report skew after a flip — never to refuse one.
existing_boxes() {
  command -v incus >/dev/null 2>&1 || return 1
  { timeout 10 incus list user.box=1 --format csv --columns n </dev/null
    timeout 10 incus list user.claudebox=1 --format csv --columns n </dev/null
  } 2>/dev/null | awk -F, 'NF && !seen[$1]++ { print $1 }' | grep .
}

# Flip $DEST/current to versions/<v> atomically: build the new link beside it,
# rename over. Plain `ln -sfn` is unlink+create — a window where current names
# nothing and a concurrent `crew` invocation dies mid-chain. cli/crew's
# `crew use` (heavy-duty/crew#96) flips with the same pattern.
flip_current() {
  ln -sfn "versions/$1" "$DEST/current.new.$$"
  mv -Tf "$DEST/current.new.$$" "$DEST/current"
}

# --- the source tree -------------------------------------------------------
# A LOCAL tree (see the header): CREW_INSTALL_SOURCE, or the tree this script
# lives in. install.sh sits at the repo root, so its own directory IS a crew
# tree — running `bash install.sh` from a checkout installs that checkout.
self="$(readlink -f "${BASH_SOURCE[0]}")"
SRC="${CREW_INSTALL_SOURCE:-$(cd "$(dirname "$self")" && pwd)}"
command -v tar >/dev/null 2>&1 || die "tar is required but was not found. Please install tar and re-run."

# --- the payload -----------------------------------------------------------
# THE INSTALLED TREE IS THE PRODUCT, NOT THE REPOSITORY (heavy-duty/crew#365).
# One rule decides every line below: a path ships only if something an
# installed tree RUNS reads it — `cli/crew`, the `shared/` engine it pushes to
# boxes, or `fleet-floor/server/` serving the console. Everything else is
# repository furniture: it is read in a checkout, by CI, by the release
# ceremony or by a contributor, and on a host it is bytes every `crew upgrade`
# moves for nothing.
#
# What that leaves, so the next person adding a directory can tell which side
# it falls on: `cli/`, `shared/` (bar its suite), `examples/` (cli/crew's
# config fallback), `VERSION`, `install.sh`, `README.md`, `CHANGELOG.md`, and
# `fleet-floor/`'s pre-built `index.html` plus `server/`.
#
# ONE list, TWO enforcements. The paths are named once, each with its reason;
# what follows derives both the `tar --exclude` array and prune_payload(). The
# script acquires its tree two ways — a DIRECTORY (a checkout, the scp-able
# artifact's unpacked temp dir, `dist/curl-install.sh`'s extracted tree) or a
# TARBALL (`dist/fetch.sh` hands over the file `gh` streamed, and the README's
# own `CREW_INSTALL_SOURCE=<a crew tree or tarball>` form) — and the rule has
# to be a property of the TREE, not of the branch that got it: filtering only
# the tar left the tarball branch installing 52M while this comment claimed
# otherwise (claude-bot and codex-bot, round 1 on #365). So the prune runs on
# whatever was acquired, and a third acquisition shape inherits the rule by
# construction; the tar excludes stay as what they are — the optimisation that
# keeps the directory branch from copying 30M in order to delete it.
PAYLOAD_EXCLUDED_PATHS=(
  .git             # a working checkout's VCS state, never the product's
  .gitignore       # the same checkout's ignore rules — repository furniture by the rule above
  .github          # CI workflows and labels.conf — GitHub reads them in the repo
  .box             # the box bootstrap runbook, for an agent in a checkout
  .ceremony        # vendored governance doctrine; agents read it in the repo they work in
  AGENTS.md        # the same doctrine's router
  CONTRIBUTING.md  # contributor doctrine for the checkout
  changelog.d      # release-note fragments, assembled by the release PR
  dist             # the installer builders; an installed tree is their output, not their input
  drill            # the release rehearsal — it refuses a source with no git HEAD, so an install can never run it
  drills           # the per-version drill records, a release-guard input
  postmortems      # repo records
  protocols        # repo records
  shared/test      # the engine suite, run from a checkout — and `crew upgrade` pushes shared/ to every box
  fleet-floor/dev  # the design-time asset map: 163 webp, 27 gif, 25 png, shipped only in dev/whiteboard.html
  fleet-floor/src  # the page's sources; `crew floor` serves the committed index.html and CI asserts it fresh
  fleet-floor/build.sh  # the src/ concatenator, whose only inputs are excluded above
  fleet-floor/test # the collector + page suite, run from a checkout
)

# Anchored patterns (`./x`), so an exclusion names one path at the tree ROOT
# and can never match a like-named directory deeper in — a bare
# `--exclude=test` would take any `test` at any depth, silently. `--anchored`
# is GNU tar's, as are the `mv -Tf` and `readlink -f` this script already
# depends on, so it adds no portability the installer did not already require.
PAYLOAD_EXCLUDES=(--anchored)
for p in "${PAYLOAD_EXCLUDED_PATHS[@]}"; do PAYLOAD_EXCLUDES+=("--exclude=./$p"); done
unset p

# True when $2 — a path from the list above, relative to the tree root $1 — can
# be removed without the removal leaving that root: every DIRECTORY component
# of it is a real directory rather than a symlink. Stops early on a component
# that does not exist, since there is then nothing below it to remove and
# nothing to escape through. The FINAL component is deliberately not checked:
# `rm -rf` unlinks a trailing symlink instead of following it, which is the
# right treatment for an excluded path that is itself a link.
payload_path_is_contained() {  # $1 = tree root, $2 = path under it
  local at="$1" rest="$2" comp
  while [ "$rest" != "${rest#*/}" ]; do
    comp="${rest%%/*}"; rest="${rest#*/}"
    at="$at/$comp"
    [ ! -L "$at" ] || return 1
    [ -d "$at" ] || return 0
  done
  return 0
}

# The same list, applied to a tree that already exists. Rooted removals only —
# each path is joined to the root the caller names, never globbed — so this
# touches exactly the paths above inside exactly that tree. Two guards make
# that true, and both are load-bearing:
#
#   1. The root is required and must be a real directory. An empty $1 would
#      make every removal a bare relative path in $PWD.
#   2. Nothing is removed THROUGH a symlink. `rm -rf -- "$root/shared/test"`
#      resolves `shared` during pathname resolution — only the last component
#      of the path is safe from being followed — so a source whose `shared` is
#      a symlink had this delete a directory outside the tree entirely while
#      the install still exited 0 (codex-bot, round 2 on #365). The escape
#      arrived with the prune; the directory branch never had it, because tar
#      does not follow symlinks when archiving, so an exclude simply matches
#      nothing there. Every path is therefore checked BEFORE any is removed.
#
# A source with a symlinked ancestor is REFUSED, not skipped. `shared` and
# `fleet-floor` are plain directories in the repository, in GitHub's tarball
# and in what dist/make-installer.sh packs, so a tree where they are not is not
# one this installer can minimise — and installing it unpruned would ship the
# whole repository, which is the defect #365 exists to close. Checking every
# path before removing any also means a refusal leaves no half-pruned tree.
prune_payload() {  # $1 = tree root
  local root="$1" p
  if [ -z "$root" ] || [ ! -d "$root" ] || [ -L "$root" ]; then
    die "prune_payload: not a tree: '${root:-<empty>}'"
  fi
  for p in "${PAYLOAD_EXCLUDED_PATHS[@]}"; do
    payload_path_is_contained "$root" "$p" || die \
      "refusing to install $SRC: '$p' lies under a symlink in the source tree, so minimising the payload would remove files outside it. That is not a crew tree — nothing has been removed or installed."
  done
  for p in "${PAYLOAD_EXCLUDED_PATHS[@]}"; do
    rm -rf -- "${root:?}/${p:?}"
  done
  install_payload_prune_ignored "$root"
}

# Pruning is an optimisation, never the trust boundary. Refuse the constructed
# payload if any known exclusion survived, naming the first offending path so
# a future omission is diagnosed before a version tree is installed.
validate_payload() {  # $1 = payload tree
  local root="$1" p found
  found=""
  while IFS= read -r found; do break; done < <(install_payload_find_ignored "$root")
  [ -z "$found" ] || die \
    "refusing payload: known-excluded path survived construction: $found"
  for p in "${PAYLOAD_EXCLUDED_PATHS[@]}"; do
    if [ -e "$root/$p" ] || [ -L "$root/$p" ]; then
      die "refusing payload: known-excluded path survived construction: $p"
    fi
  done
}

confirm "Install crew from $SRC?" || die "cancelled — nothing was changed."

# --- temp workspace --------------------------------------------------------
TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# --- acquire the tree ------------------------------------------------------
# INSTALLED_FROM records provenance in the version dir so a caller can assert
# what it got. A local install names its source path; the scp-able artifact
# (heavy-duty/crew#98) unpacks to a throwaway temp dir, so it sets
# CREW_INSTALLED_FROM to name ITSELF instead — a dead temp path is useless
# provenance, and the artifact knows its own name and checksum.
INSTALLED_FROM="${CREW_INSTALLED_FROM:-local:$SRC}"
if [ -d "$SRC" ]; then
  log "copying local tree $SRC"
  install_payload_load_ignore_patterns "$SRC" || die \
    "could not derive repository-wide payload exclusions from $SRC/.gitignore"
  SOURCE_PAYLOAD_EXCLUDES=("${PAYLOAD_EXCLUDES[@]}")
  for p in "${INSTALL_PAYLOAD_IGNORE_PATTERNS[@]}"; do
    SOURCE_PAYLOAD_EXCLUDES+=("--exclude=$p")
  done
  mkdir -p "$TMPDIR/tree"
  # tar, not cp -a: the exclude list above, so a working checkout carries
  # neither its VCS state nor the repository furniture into the install tree.
  tar -C "$SRC" "${SOURCE_PAYLOAD_EXCLUDES[@]}" -cf - . | tar -xf - -C "$TMPDIR/tree"
  EXTRACTED="$TMPDIR/tree"
elif [ -f "$SRC" ]; then
  log "extracting local tarball $SRC"
  tar -xzf "$SRC" -C "$TMPDIR" || die "failed to extract $SRC"
  EXTRACTED="$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -type d | head -n1)"
else
  die "CREW_INSTALL_SOURCE is neither a directory nor a tarball: $SRC"
fi
[ -n "${EXTRACTED:-}" ] || die "could not find the source tree in $SRC"
[ -f "$EXTRACTED/cli/crew" ] || die "source does not contain cli/crew — is $SRC a crew tree?"
if [ -f "$SRC" ]; then
  install_payload_load_ignore_patterns "$EXTRACTED" || die \
    "could not derive repository-wide payload exclusions from $SRC"
fi

# The payload rule, on whatever was acquired. A no-op after the directory
# branch (tar already dropped those paths); the whole of the minimisation after
# the tarball branch, whose archive is packed elsewhere — by GitHub, by
# `dist/make-installer.sh` — and arrives whole.
prune_payload "$EXTRACTED"
validate_payload "$EXTRACTED"

# The tree's own VERSION file names the directory it lands in — the version IS
# the identity of what is being installed.
new_ver="$(cat "$EXTRACTED/VERSION" 2>/dev/null || true)"
[ -n "$new_ver" ] || die "source has no VERSION file — cannot install it as a version"
valid_version "$new_ver" || die "the source's VERSION is not a sane directory name: '$new_ver'"

# --- install into $DEST/versions/<version> ---------------------------------
# Reap swap scratch from an interrupted prior run before installing:
# versions/*.new.<pid> and versions/*.old.<pid> are only ever transient (this
# run makes its own below). A kill leaves them behind, and #96's `crew versions`
# would otherwise list them (kimi-bot, #95). Remove them — but with two guards,
# because valid_version() accepts dots and digits, so a legitimate version can
# be *named* `1.0.new.123` and match the scratch glob (codex-bot, #95):
#   1. never the tree `current` resolves to — an interrupted reinstall
#      legitimately left a `.new.*` as the live tree, and removing it would
#      dangle `current` (the next flip retires it);
#   2. never a real installed version that merely LOOKS like scratch. Identity,
#      not name: a version dir is `versions/<v>` iff its own VERSION file reads
#      `<v>` (that is the only way it got its name). Swap scratch instead
#      carries the BASE version's VERSION (`.new.<pid>` is the staged source,
#      `.old.<pid>` the retired tree), so its basename never equals its VERSION.
#      So spare any dir whose VERSION equals its basename; reap the rest
#      (missing/mismatched VERSION == genuine scratch).
cur_now="$(readlink -f "$DEST/current" 2>/dev/null || true)"
for d in "$DEST"/versions/*.new.[0-9]* "$DEST"/versions/*.old.[0-9]*; do
  [ -d "$d" ] || continue
  [ -n "$cur_now" ] && [ "$(readlink -f "$d")" = "$cur_now" ] && continue
  [ "$(cat "$d/VERSION" 2>/dev/null || true)" = "${d##*/}" ] && continue
  rm -rf "$d"
done

VDIR="$DEST/versions/$new_ver"
newly_installed=0
if [ -d "$VDIR" ]; then
  if [ -n "${CREW_REINSTALL:-}" ]; then
    # Replace THIS version's tree while keeping `current` resolvable at EVERY
    # interruption point. The naive swap — mv the live $VDIR aside, mv the
    # staged tree in — dangles `current` between the two renames when it points
    # at the version being replaced (the usual case: reinstalling the active
    # default). A kill in that window leaves `current` dangling until the next
    # install heals it (codex-bot and grok-bot both reproduced this on #95).
    #
    # The fix: when this version IS the active default, flip `current` onto the
    # fully-staged NEW tree FIRST — an atomic mv -Tf — so across both directory
    # renames `current` resolves to the new tree; flip it back to the canonical
    # path once that path holds the new tree. A non-default reinstall skips the
    # flips (nothing points here). Even a residual crash self-heals: the
    # default-version block below repoints a dangling `current` on the next run.
    log "CREW_REINSTALL=1 — replacing the installed $new_ver tree"
    stage="$VDIR.new.$$"; old="$VDIR.old.$$"
    rm -rf "$stage" "$old"
    chmod +x "$EXTRACTED/cli/crew"
    mv "$EXTRACTED" "$stage"
    active=0
    [ "$(readlink -f "$DEST/current" 2>/dev/null || true)" = "$(readlink -f "$VDIR" 2>/dev/null || true)" ] && active=1
    [ "$active" -eq 1 ] && flip_current "$new_ver.new.$$"   # current -> staged NEW tree
    # Swap by renames, delete LAST: rm-then-move leaves a hole the whole length
    # of the delete where a name resolves to nothing.
    mv "$VDIR" "$old"
    mv "$stage" "$VDIR"
    [ "$active" -eq 1 ] && flip_current "$new_ver"          # current -> canonical (now the NEW tree)
    rm -rf "$old"
    printf '%s\n' "$INSTALLED_FROM" > "$VDIR/INSTALLED_FROM"
    log "reinstalled $new_ver"
  else
    cur_from="$(cat "$VDIR/INSTALLED_FROM" 2>/dev/null || echo '<unknown source>')"
    log "crew $new_ver is already installed ($cur_from) — nothing to do."
    log "(CREW_REINSTALL=1 replaces this version's tree; 'crew versions' lists what is installed.)"
  fi
else
  log "installing $new_ver into $VDIR"
  mkdir -p "$DEST/versions"
  chmod +x "$EXTRACTED/cli/crew"
  mv "$EXTRACTED" "$VDIR"
  newly_installed=1
  # Record WHAT was installed, so a caller can assert it got what it asked for.
  printf '%s\n' "$INSTALLED_FROM" > "$VDIR/INSTALLED_FROM"
fi

# --- which version is the default? -----------------------------------------
# Flipping 'current' is the ONLY step that changes what an operator's `crew`
# runs. Unlike box (box#66), crew NEVER refuses the flip under existing boxes:
# the host CLI version and each box's engine version are independent axes
# (#93 finding 2). A fresh host (or a dangling current) is claimed; a re-run
# that installs no new default leaves the default alone; a genuinely new
# default flips, and then the skew it created is REPORTED.
cur="$(readlink -f "$DEST/current" 2>/dev/null || true)"
want="$(readlink -f "$VDIR")"
if [ -z "$cur" ] || [ ! -d "$cur" ]; then
  flip_current "$new_ver"
  log "default version: $new_ver"
elif [ "$cur" = "$want" ]; then
  : # already the default — nothing to flip
elif [ "$newly_installed" -eq 0 ]; then
  # A converge/no-op of a version that is NOT the default never moves the
  # default — a re-run must change nothing; switching is 'crew use', a
  # deliberate act.
  log "the default stays $(basename "$cur") — 'crew use $new_ver' switches."
else
  old_ver="$(basename "$cur")"
  flip_current "$new_ver"
  log "default version switched: $old_ver -> $new_ver ('crew use $old_ver' switches back)"
  # Report the skew the flip just created — never refuse it. The shared
  # reporter is also what `crew use` calls, so installation and a deliberate
  # switch cannot disagree about which hired engines were left behind.
  report_engine_skew "$new_ver"
fi

# --- put crew on PATH ------------------------------------------------------
# ln -sfn converges, and that includes HEALING: a stale or dangling
# $BINDIR/crew must never block or wedge an install — it gets repointed at the
# current chain, whatever it said before.
mkdir -p "$BINDIR"
ln -sfn "$DEST/current/cli/crew" "$BINDIR/crew"
log "linked $BINDIR/crew -> $DEST/current/cli/crew"

# A global install is executed by OTHER users. mv preserves root ownership and
# source archives do not promise world bits on every path, so without this a
# non-root operator may be unable to traverse the tree at all. Root owns and
# writes it; everybody reads and traverses it. Guarding this keeps the per-user
# install's modes byte-identical to before.
if [ "$(id -u)" -eq 0 ]; then
  chmod -R a+rX "$DEST"
fi

# Global and per-user installs coexist by PATH order alone. Name the other
# tier explicitly instead of letting two versions silently shadow each other.
sudo_home=""
if [ "$(id -u)" -ne 0 ]; then
  if [ -e /opt/crew/current/cli/crew ]; then
    warn "a GLOBAL install also exists at /opt/crew — PATH order decides which 'crew' you run (check: command -v crew)"
  fi
elif [ -n "${SUDO_USER:-}" ]; then
  sudo_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)" || sudo_home=""
  if [ -n "$sudo_home" ] && [ -e "$sudo_home/.local/share/crew/current/cli/crew" ]; then
    warn "a PER-USER install also exists at $sudo_home/.local/share/crew — PATH order decides which 'crew' $SUDO_USER runs"
  fi
fi

# --- name an existing ~/crew checkout --------------------------------------
# Do NOT migrate or delete it (#95): it is the operator's working tree and may
# hold uncommitted work. Since #99 the host ships shared/+VERSION to the boxes,
# so ~/crew is no longer what `crew upgrade` pulls into — but it still shadows
# this installed crew on PATH. Naming beats a clever migration: PATH order
# decides which `crew` runs, so say so.
checkout_home="$HOME"
if [ "$(id -u)" -eq 0 ] && [ -n "$sudo_home" ]; then checkout_home="$sudo_home"; fi
if [ -f "$checkout_home/crew/cli/crew" ] && [ -d "$checkout_home/crew/.git" ]; then
  warn "a crew git checkout also exists at $checkout_home/crew — its cli/crew and this installed one both answer to the name 'crew'."
  warn "  PATH order decides which runs (check: command -v crew). This installer left the checkout untouched."
fi

# --- PATH check ------------------------------------------------------------
case ":$PATH:" in
  *":$BINDIR:"*) : ;;
  *)
    log "note: $BINDIR is not on your PATH."
    log "  add this to your shell rc (e.g. ~/.bashrc or ~/.zshrc):"
    log "      export PATH=\"$BINDIR:\$PATH\""
    ;;
esac

# --- the platform check ----------------------------------------------------
# The other of D12's two earliest points that know the host (#679). Installing
# is the first moment crew is on this machine at all, and a floor an operator
# meets for the first time at `crew down --force` — a verb reached in an
# incident — is not a prerequisite, it is a surprise.
#
# It REPORTS and never refuses (#679 D14): a below-floor host still gets a
# working install, because every verb that cares keeps its own consequence and
# most of them do not care.
#
# ABOVE the `done` line and not after it. `done` is this installer's terminal
# statement, and shared/test/artifact.sh asserts it is the last line across all
# four install channels — a finding printed after it would contradict the word.
# Findings belong in the body of the run, which is where report_engine_skew's
# already are.
#
# Identical wording to `crew up`'s, because it is the identical call into the
# identical reporter — the same property report_engine_skew has across this
# file and `crew use`, and for the same reason.
#
# No roster argument, and that is the whole difference between the two callers:
# `crew up` has already resolved a fleet definition and hands its $ROSTER down,
# while the installer has none and lets platform_roster_names resolve from
# CREW_ROSTER / CREW_CONFIG_DIR / XDG — the operator-owned locations, never
# cli/crew's $PWD and examples/ conveniences. On one host those two resolutions
# are the same fleet, which is what makes D12's "identical" a real comparison;
# on a host with no fleet definition yet, which is most first installs, the rig
# half is silent, exactly as D15 already leaves a host with no boxes.
report_platform "$new_ver"

log "done ($INSTALLED_FROM, version $new_ver) — try: crew help"
