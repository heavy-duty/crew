#!/usr/bin/env bash
# install-payload.sh — #365's payload rule, asserted on an INSTALLED tree, for
# drill/install-drill.sh. The caller supplies pass() and fail(); keeping the
# predicate here makes every one of its failure paths fixture-testable without
# a box host, the way install-survival.sh does for step 9.
#
# Section A installs, upgrades and packs real trees on a real host, and until
# now never looked at what any of them held. #365 shrank an installed tree from
# 32M — 29M of it fleet-floor/dev — to under the bound below, and a regression
# there is silent in a way the offline suites cannot catch for the channels
# only a host runs end to end: the tree installs, every assertion passes, and
# the fleet carries 30M again per box per `crew upgrade`.
#
# NOTHING HERE SPELLS THE RULE ITSELF. Both halves are read from the tree under
# drill, which install-drill.sh already requires to carry all three files:
#   * the excluded roots, from install.sh's PAYLOAD_EXCLUDED_PATHS — the one
#     list install.sh derives both its tar excludes and prune_payload() from,
#     and the one an installed tree ships, so the drill and the installer can
#     never disagree about what "excluded" means;
#   * the size bound, from the two offline guards that already enforce it.
# A second copy under drill/ would drift, which is the rule this repo already
# applies to the panel roster (#356) and to the queue-label set.

# The bound, in KiB, read from the guards that own it. BOTH spell it today, so
# reading both and requiring agreement costs nothing and turns that existing
# duplication into a checked invariant: two different numbers is a defect in
# the guards, and a drill that picked one of them arbitrarily would hide it.
install_payload_budget_kb() {  # <source tree>
  local tree="$1" guard found="" bound count
  for guard in shared/test/install-lifecycle.sh shared/test/artifact.sh; do
    if [ ! -f "$tree/$guard" ]; then
      echo "install-payload: $guard is missing from '$tree'" >&2
      return 1
    fi
    # shellcheck disable=SC2016  # `$kb` is the guard's own text, matched literally
    found="$found$(sed -n 's/.*"\$kb"[[:space:]]*-lt[[:space:]]*\([0-9]\{1,\}\).*/\1/p' "$tree/$guard")
"
  done
  bound="$(printf '%s' "$found" | sed '/^$/d' | sort -u)"
  count="$(printf '%s\n' "$bound" | grep -c . || true)"
  if [ "$count" -eq 0 ]; then
    echo "install-payload: no installed-tree size bound found in the offline guards" >&2
    return 1
  fi
  if [ "$count" -ne 1 ]; then
    echo "install-payload: the offline guards disagree on the size bound ($(printf '%s' "$bound" | tr '\n' ' '))" >&2
    return 1
  fi
  printf '%s\n' "$bound"
}

# The one root #365 was minted on — 29M of that tree's 32M. It is spelled here,
# and it is the only path that is, for a reason the parse cannot cover on its
# own: THE MUTATION THIS LEG EXISTS TO CATCH REMOVES IT FROM THE LIST BEING
# PARSED. An assertion that only ever walks what install.sh still names would
# go green on exactly the regression it was written for — the root stops being
# excluded, so it stops being checked, so the fat tree walks past. So this one
# is asserted by path whether or not the installer still names it, and the
# installer no longer naming it is its own separate finding below. A path is
# not the rule: the bound and the other seventeen roots are still read.
INSTALL_PAYLOAD_SENTINEL_ROOT=fleet-floor/dev

# PAYLOAD_EXCLUDED_PATHS exactly as install.sh declares it — the list the
# installer derives both its tar excludes and prune_payload() from.
install_payload_declared_roots() {  # <source tree>
  sed -n '/^PAYLOAD_EXCLUDED_PATHS=(/,/^)/p' "$1/install.sh" 2>/dev/null |
    sed -e '1d' -e '$d' -e 's/#.*$//' -e 's/[[:space:]]//g' -e '/^$/d'
}

# Whether the installer still names the sentinel. Asserted once by the caller,
# against the source tree: it is a property of install.sh and not of any one
# installed tree, so it earns one line in the record rather than three.
install_payload_installer_names_sentinel() {  # <source tree>
  install_payload_declared_roots "$1" | grep -qx "$INSTALL_PAYLOAD_SENTINEL_ROOT"
}

# What every installed tree is walked against: the declared list, unioned with
# the sentinel so removing it from the declaration cannot remove it from here.
install_payload_excluded_roots() {  # <source tree>
  local tree="$1" roots
  if [ ! -f "$tree/install.sh" ]; then
    echo "install-payload: install.sh is missing from '$tree'" >&2
    return 1
  fi
  roots="$(install_payload_declared_roots "$tree")"
  if [ -z "$roots" ]; then
    echo "install-payload: install.sh's PAYLOAD_EXCLUDED_PATHS did not parse" >&2
    return 1
  fi
  printf '%s\n%s\n' "$roots" "$INSTALL_PAYLOAD_SENTINEL_ROOT" | sort -u
}

# install_payload_assert <case prefix> <source tree> <installed tree>
#
# Two assertions, kept separate on purpose. A size check alone passes a tree
# that swapped 29M of dev/ for 29M of something else; a name check alone says
# nothing about the next fat directory somebody adds. Neither subsumes the
# other, and #365's own guards split them the same way.
install_payload_assert() {
  local prefix="$1" src="$2" tree="$3"
  local roots bound root shipped="" count kb rc=0

  if ! roots="$(install_payload_excluded_roots "$src" 2>&1)"; then
    fail "$prefix: excluded roots read from the installer" "$roots"
    return 1
  fi
  if ! bound="$(install_payload_budget_kb "$src" 2>&1)"; then
    fail "$prefix: size bound read from the offline guards" "$bound"
    return 1
  fi
  if [ ! -d "$tree" ]; then
    fail "$prefix: installed tree is a directory" "nothing at '$tree'"
    return 1
  fi

  count="$(printf '%s\n' "$roots" | grep -c . || true)"
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    if [ -e "$tree/$root" ]; then shipped="$shipped $root"; fi
  done <<<"$roots"
  if [ -z "$shipped" ]; then
    pass "$prefix: installed tree carries none of the installer's $count excluded roots"
  else
    fail "$prefix: installed tree carries none of the installer's excluded roots" \
      "still shipped:$shipped"
    rc=1
  fi

  # Measured with -L, so a `current` symlink is measured as the tree it
  # resolves to: a bare `du -sk` there reports the link and would pass on a
  # tree of any size (#365). The number goes in the PASS line either way, so
  # the drill record carries it and the next window can read the trend.
  kb="$(du -skL "$tree" | cut -f1)"
  if [ "$kb" -lt "$bound" ]; then
    pass "$prefix: installed tree is $kb KiB, within the $bound KiB bound"
  else
    fail "$prefix: installed tree within the $bound KiB bound" "measured $kb KiB"
    rc=1
  fi
  return "$rc"
}
