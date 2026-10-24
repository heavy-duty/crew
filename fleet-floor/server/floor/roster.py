"""Where the fleet is DEFINED, and what boxes actually exist.

The definition half resolves the same directory the CLI does and refuses the
same fallbacks it refuses; the inventory half asks the host what is there.

Careful with prose here: `shared/test/run.sh`'s
floor-named-crew-verb-roster-is-complete greps `crew <word>` out of every
collector source, comments included, so the word after a literal "crew " in
this file mints a console verb that does not exist. Say "the CLI".
"""

import json
import os
import re
import sys
import threading
import time

from floor import AGENTS_DIR, CREW_ROOT

ROLES_DIR = os.path.join(CREW_ROOT, "shared", "conf", "roles")

# `from floor.ping import log, run` is NOT here: it sits below the resolution,
# at the seam between this module's two halves, and that position is asserted.
# See the note there.

def fleet_config_dir():
    """The same directory-atomic fleet selection cli/crew makes (#74/#75).

    One config dir serves both readers: the fleet the CLI drives and the
    fleet this console renders must be the same fleet, resolved the same
    way, or the two lie to the operator in different directions.
    CREW_CONFIG_DIR selects explicitly and an invalid or incomplete one is
    an error, exactly as the CLI refuses it; otherwise the first of the XDG
    config dir, the working directory and the shipped examples/ carrying
    fleet.roster wins. Returns (dir, is_operator) — examples/ is the
    compatibility fallback, not an operator definition.
    """
    examples = os.path.join(CREW_ROOT, "examples")

    def is_fleet(d):
        return os.path.isfile(os.path.join(d, "fleet.roster"))

    explicit = os.environ.get("CREW_CONFIG_DIR")
    if explicit is not None:
        if not explicit or not os.path.isdir(explicit) or not is_fleet(explicit):
            sys.exit("crew floor: CREW_CONFIG_DIR '%s' is not a fleet definition "
                     "(fleet.roster is required)" % explicit)
        chosen, operator = os.path.abspath(explicit), True
    else:
        xdg = os.environ.get("XDG_CONFIG_HOME")
        xdg_dir = (os.path.join(xdg, "crew") if xdg
                   else os.path.join(os.path.expanduser("~"), ".config", "crew"))
        chosen, operator = None, False
        for candidate in (xdg_dir, os.getcwd(), examples):
            if os.path.isdir(candidate) and is_fleet(candidate):
                chosen = os.path.abspath(candidate)
                operator = chosen != os.path.abspath(examples)
                break
        if chosen is None:
            sys.exit("crew floor: no fleet definition found (fleet.roster is required)")
    # Unconditional, because the property is that the check does not care who
    # wrote the directory: under `if operator:` the LEAST trusted definition
    # got the LEAST verification, and an incomplete fallback reported its
    # incompleteness in the CLI and not here. #216 item 4 made the CLI's
    # unconditional; this is the console's half (#244). It runs at resolution,
    # i.e. BEFORE the operator-config refusal in main(), so an incomplete
    # directory reports incomplete in both processes whoever owns it — the
    # same order the CLI has.
    missing = [f for f in ("fleet.conf", "repos.txt")
               if not os.path.isfile(os.path.join(chosen, f))]
    if missing:
        sys.exit("crew floor: fleet definition '%s' is incomplete; missing: %s"
                 % (chosen, " ".join(missing)))
    return chosen, operator


CONFIG_DIR, CONFIG_IS_OPERATOR = fleet_config_dir()


def require_operator_config():
    """The console refuses under the examples fallback, exactly as cli/crew's
    mutating verbs do (#216/#244).

    Both processes must refuse the same fleet the same way. `crew floor` is
    the door an operator uses, but floor.py is invoked directly too — by this
    repo's own suites and by anyone starting the server by hand — so a check
    only in cmd_floor is a door with a hinge side.

    Called from main() rather than at import: refusing at module level would
    also refuse in-process READERS that never bind a port (the CLI/console
    resolution-parity assertions, the box-side parser tests), and what this
    refuses is serving the console, not reading floor.py's answers. The words
    are the CLI's, so an operator who hits it from either direction gets one
    message and one instruction.
    """
    if CONFIG_IS_OPERATOR:
        return
    sys.exit("""crew floor: refuses under the shipped example fleet definition at %s.
  Nobody configured this host, so there is nothing here to create or arm: the
  examples are a scaffold to read, not a fleet to run. Scaffold your own —
    crew init
  then edit the generated files (repos.txt ships EMPTY: name your repos) and
  run again. 'crew status', 'crew profiles' and 'crew up --dry-run' keep
  working here, which is how you inspect a host in this state.""" % CONFIG_DIR)


def agent_conf_path(agent):
    """The resolved profile path — the same answer cli/crew's agent_conf
    gives: an operator agents/ file wins over the same-named shipped
    profile, the shipped set is the fallback (#75)."""
    if CONFIG_IS_OPERATOR:
        op = os.path.join(CONFIG_DIR, "agents", "%s.conf" % agent)
        if os.path.isfile(op):
            return op
    return os.path.join(AGENTS_DIR, "%s.conf" % agent)


def role_conf_path(role):
    """Resolve a role profile with the same operator-first rule as agents."""
    if CONFIG_IS_OPERATOR:
        op = os.path.join(CONFIG_DIR, "roles", "%s.conf" % role)
        if os.path.isfile(op):
            return op
    return os.path.join(ROLES_DIR, "%s.conf" % role)


# CREW_FLOOR_ROSTER stays the explicit override AHEAD of the config-dir
# search, so a test (or an operator running a floor over an alternate fleet)
# never has to mutate a tracked roster in place. The suite used to swap the
# file and restore it on exit, which meant any killed run left the shipped
# example roster clobbered in the working tree.
ROSTER = os.environ.get("CREW_FLOOR_ROSTER") or os.path.join(CONFIG_DIR, "fleet.roster")
# The launcher owns this string: it is the exact answer from `crew --version`,
# not a second attempt by the server to find and interpret VERSION.
FLOOR_VERSION = os.environ.get("CREW_FLOOR_VERSION", "version unavailable")


# --------------------------------------------------------------------------
# roster + box inventory
# --------------------------------------------------------------------------

# Imported HERE, not at the top of the file, and this position is load-bearing.
#
# floor.ping parses six CREW_FLOOR_* timeouts at ITS module level, and an
# int() of a bad one raises. Before the split those parses sat at floor.py:175
# and the resolution above sat at :116, so the fleet-definition refusal always
# won a race against them: every refusal came before every configuration
# parse. A top-of-file import here runs ping's whole body first and reverses
# that — `CREW_CONFIG_DIR=/missing CREW_FLOOR_PROBE_TIMEOUT=bad` answered with
# a ValueError traceback instead of the refusal. This line sits at exactly the
# seam floor.py had: definition half, then ping, then inventory half.
#
# floor.py imports this module before floor.server for the same reason and
# will not hold the order without this; both are asserted together by
# test/cli.sh's "floor refusal order" cases.
from floor.ping import log, run  # noqa: E402


def read_roster():
    """<name> <agent> <role> [<from>] — the same reader the CLI's bash uses.
    `from` is the fourth column (the gold box/snapshot a `crew new` mints
    from), carried so an edit from the console never drops it."""
    out = []
    try:
        with open(ROSTER) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split()
                if len(parts) >= 3:
                    out.append({"box": parts[0], "agent": parts[1], "room": parts[2],
                                "from": parts[3] if len(parts) > 3 else ""})
    except OSError as e:
        log("cannot read roster: %s" % e)
    return out


# --------------------------------------------------------------------------
# the roster as a layer the console can edit (#764)
# --------------------------------------------------------------------------
#
# fleet.roster IS the fleet, and it was the one piece of the definition the
# console showed and could not change: adding a reviewer, retiring a box or
# changing a role was a shell on the operator's machine. It is edited here
# the way the watch registries are (#488): the whole file, validated before
# anything moves, written atomically with its header comments kept, and
# journalled so a change to who is on the fleet is attributable after it.
#
# Saving writes the DEFINITION and nothing else. A new line becomes a box
# when the operator runs `crew up` (it creates, starts and hires every roster
# box; the login is the operator's, by hand), and a removed line's box is
# left alone — the console stops watching it, nothing is ever deleted. The
# collector reads the roster on every poll, so the edit is live at the next.

# incus's instance-name alphabet: letters, digits and hyphens, a letter first,
# 63 at most. A `from` is `<box>/<snapshot>` or a bare `<box>`.
RE_BOX = re.compile(r"^[a-z][a-z0-9-]{0,62}$")
RE_FROM = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}(/[A-Za-z0-9][A-Za-z0-9._-]{0,99})?$")
ROSTER_JOURNAL = os.path.join(CONFIG_DIR, ".roster-journal.log")
_ROSTER_LOCK = threading.Lock()


def profile_names(kind):
    """The `agents` or `roles` a roster line may name: the shipped profiles
    plus the operator's own (which win by name, as agent_conf_path says)."""
    dirs = [AGENTS_DIR if kind == "agents" else ROLES_DIR]
    if CONFIG_IS_OPERATOR:
        dirs.append(os.path.join(CONFIG_DIR, kind))
    names = set()
    for d in dirs:
        try:
            for f in os.listdir(d):
                if f.endswith(".conf"):
                    names.add(f[:-len(".conf")])
        except OSError:
            pass
    return sorted(names)


def roster_snapshot():
    """What the console's roster editor opens on: the file as it is on disk
    right now, the names a line may use, and where a save lands."""
    return {"path": ROSTER, "config_dir": CONFIG_DIR, "operator": CONFIG_IS_OPERATOR,
            "agents": profile_names("agents"), "roles": profile_names("roles"),
            "members": read_roster()}


def _roster_validate(members):
    """(clean, error) — every line checked before anything moves, each
    refusal naming the line and what is wrong with it."""
    if not isinstance(members, list):
        return None, "members must be a list"
    agents, roles = set(profile_names("agents")), set(profile_names("roles"))
    clean, seen = [], set()
    for i, m in enumerate(members):
        if not isinstance(m, dict):
            return None, "member %d is not an object" % (i + 1)
        box = str(m.get("box", "") or "").strip()
        agent = str(m.get("agent", "") or "").strip()
        rr = m.get("roles", m.get("room", ""))
        if isinstance(rr, str):
            rr = rr.split(",")
        rr = [str(r).strip() for r in (rr or []) if str(r).strip()]
        frm = str(m.get("from", "") or "").strip()
        if not RE_BOX.match(box):
            return None, ("box name %r is refused: lowercase letters, digits and hyphens, "
                          "a letter first, 63 at most (incus's own rule)" % box)
        if box in seen:
            return None, "box %s is named twice" % box
        seen.add(box)
        if agent not in agents:
            return None, "box %s: unknown agent %r (profiles: %s)" % (box, agent, ", ".join(sorted(agents)) or "none")
        if not rr:
            return None, "box %s names no role" % box
        for r in rr:
            if r not in roles:
                return None, "box %s: unknown role %r (profiles: %s)" % (box, r, ", ".join(sorted(roles)) or "none")
        if frm and not RE_FROM.match(frm):
            return None, "box %s: from %r is not <box>/<snapshot>" % (box, frm)
        clean.append({"box": box, "agent": agent, "room": ",".join(rr), "from": frm})
    if not clean:
        return None, ("a roster names at least one member — remove boxes one at a time; "
                      "an empty fleet is a definition to retire by hand")
    return clean, ""


def roster_set(members, actor=""):
    """Rewrite fleet.roster. Returns (result, error) with the registry writers'
    three outcomes: `(result, "")` landed and recorded; `(None, error)` refused
    with the file untouched; `(result, error)` landed but not recorded."""
    if not CONFIG_IS_OPERATOR:
        return None, ("the shipped example roster is not edited from the console: "
                      "scaffold your own fleet definition (crew init) and serve that")
    clean, err = _roster_validate(members)
    if err:
        return None, err
    with _ROSTER_LOCK:
        before = {u["box"]: u for u in read_roster()}
        # The file's own header — every comment and blank line ahead of the
        # first member — is kept word for word: it is the operator's prose
        # about their fleet, and the format's own explanation in a scaffold.
        header = []
        try:
            with open(ROSTER, encoding="utf-8") as f:
                for line in f:
                    s = line.strip()
                    if s and not s.startswith("#"):
                        break
                    header.append(line.rstrip("\n"))
        except OSError:
            header = []
        while header and not header[-1].strip():
            header.pop()
        wb = max([len(m["box"]) for m in clean] + [12])
        wa = max([len(m["agent"]) for m in clean] + [6])
        lines = ["%-*s %-*s %s%s" % (wb, m["box"], wa, m["agent"], m["room"],
                                     ("  " + m["from"]) if m["from"] else "")
                 for m in clean]
        body = "\n".join(header + lines) + "\n"
        # The record is a precondition of the write (#488 D5): a roster that
        # could change with nothing durable saying who changed it is refused.
        try:
            with open(ROSTER_JOURNAL, "a", encoding="utf-8"):
                pass
        except OSError as e:
            return None, ("the write was refused because it could not be recorded: the "
                          "roster journal %s cannot be appended to (%s). Nothing was written."
                          % (ROSTER_JOURNAL, e))
        tmp = ROSTER + ".tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(body)
            os.replace(tmp, ROSTER)
        except OSError as e:
            try:
                os.remove(tmp)
            except OSError:
                pass
            return None, ("the write was refused: %s could not be replaced (%s). Nothing was written."
                          % (ROSTER, e))
        after = {m["box"]: m for m in clean}
        added = [b for b in after if b not in before]
        removed = [b for b in before if b not in after]
        changed = [b for b in after if b in before
                   and (before[b]["agent"], before[b]["room"], before[b].get("from", ""))
                   != (after[b]["agent"], after[b]["room"], after[b]["from"])]
        line = "%s roster set actor=%s members=%s added=%s removed=%s changed=%s\n" % (
            time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            actor or "-",
            ",".join("%s:%s:%s%s" % (m["box"], m["agent"], m["room"], ("@" + m["from"]) if m["from"] else "")
                     for m in clean),
            ",".join(added) or "-", ",".join(removed) or "-", ",".join(changed) or "-")
        recorded, jerr = True, ""
        try:
            with open(ROSTER_JOURNAL, "a", encoding="utf-8") as f:
                f.write(line)
        except OSError as e:
            recorded, jerr = False, ("the edit LANDED and could not be recorded: the roster journal "
                                     "%s could not be appended to (%s). %s has changed on disk and no "
                                     "durable record of it exists — reconcile the journal by hand."
                                     % (ROSTER_JOURNAL, e, ROSTER))
        log(line.strip())
        return {"path": ROSTER, "members": clean, "added": added, "removed": removed,
                "changed": changed, "recorded": recorded}, jerr


def box_states(strict=False):
    """name -> incus state, in ONE call rather than one per box.

    With strict=True returns (states, ok). An empty dict is ambiguous — it
    means "this host has no boxes" AND "the question could not be asked" — and
    callers that act on absence need to tell those apart. The ping tier does:
    treating a failed `box list` as "no boxes are running" switches the fast
    tier off and wipes its miss counters, in the fail-open direction, on the
    one signal whose job is noticing that something stopped answering.
    """
    rc, out, _ = run(["box", "list", "--json"], 20)
    states = {}
    ok = rc == 0
    if rc == 0:
        try:
            for b in json.loads(out):
                n = b.get("name")
                s = (b.get("state") or b.get("status") or "?")
                if isinstance(s, dict):
                    s = s.get("status", "?")
                if n:
                    states[n] = str(s).lower()
        except (ValueError, AttributeError, TypeError):
            ok = False
    return (states, ok) if strict else states
