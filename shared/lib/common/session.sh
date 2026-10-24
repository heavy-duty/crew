# common/session.sh — run_session, session_acted, session_reply_tail,
# session_peak_rss, session_mem_hit — the dispatch that launches the box CLI,
# what it reports about the session afterwards, the memory ceiling it is run
# under, and the session identity that makes its transcript addressable.
#
# A module of shared/lib/common.sh, which is the entry point: nothing sources
# this file directly.
#
# shellcheck shell=bash
# shellcheck disable=SC2034  # RUN_SESSION_RC/RUN_SESSION_LOG are run_session's
# out-of-band result, read by the caller (duty-triage.sh's ledger commits)

# _session_cli_cmd KIND — resolve THIS dispatch's CLI invocation and the tier
# name to record for it, into _SESSION_CLI_CMD and _SESSION_TIER (#469).
#
# Every duty in this fleet used to be bought at the same price: BOT_CLI_CMD is
# a property of the agent profile, so a 1.57-minute mention that reads a
# notification subject cost what an issue mint costs. Everything ELSE about a
# session's shape is already per-duty — the timeouts are, and they carry their
# calibration in the conf comments — and model tier was the one dimension with
# nowhere to live. It lives beside the timeout now (D2), because they are two
# statements about the same duty and splitting them across files is how they
# drift apart.
#
# The mechanism is deliberately the array run_session already expands (D1).
# There is NO new dispatch path: the override replaces `"${BOT_CLI_CMD[@]}"`
# and nothing else, so the timeout, the logging, the SESSION END line, the
# terminal breaker and #464's budget gate are untouched by construction rather
# than by a promise a later edit could quietly break.
#
# Resolved AFTER both gates in run_session, which is load-bearing in the small:
# a lane that is over budget or tripped terminal must produce its SESSION SKIP
# and nothing else. Resolving here would make a refused dispatch warn about a
# tier it was never going to buy.
#
# The variable is MODEL_<KIND>, the kind's non-alphanumerics folded to `_` and
# upper-cased — the same fold BUDGET_*_<KIND> uses, so `ci-red` reads
# MODEL_CI_RED in both places and an operator learns the rule once.
#
# It is read generically, so a kind whose MODEL_ variable no conf DECLARES is
# still tierable: an operator who sets it gets it honoured. The shipped
# declarations sit in conf/roles/, which is where #469 D7 fences them; a kind
# with no declaration there is not a kind the lever skips.
_session_cli_cmd() {
  local kind="$1" suffix var tier
  suffix="${kind//[^[:alnum:]]/_}"
  suffix="${suffix^^}"
  var="MODEL_${suffix}"
  tier="${!var:-}"
  # The default, and it is the whole of D4: with nothing configured anywhere
  # this function copies the profile's array and names the tier `default`, so
  # an engine that is upgraded and not configured INVOKES exactly what it
  # invoked before — the invocation and the session's behaviour are unchanged.
  # The log is not: _SESSION_TIER is set unconditionally, so SESSION END gains
  # `tier=default` on every line, including unconfigured ones. That is D5's
  # deliberate choice, not a leak — an aggregate cannot tell a duty that got
  # cheaper from one that got rarer off a field that vanishes whenever the
  # answer is boring. See the SESSION END comment below for why it is appended
  # past reply_tail rather than inserted.
  _SESSION_CLI_CMD=("${BOT_CLI_CMD[@]}")
  _SESSION_TIER=default
  [ -n "$tier" ] || return 0
  # A tier may be named by ROLE — `cheap` or `expensive` — and translated by
  # the agent profile's BOT_CLI_TIER_CHEAP / BOT_CLI_TIER_EXPENSIVE (#759): a
  # role conf cannot know what a vendor calls its small model, and the profile
  # already owns that vocabulary. An alias the profile does not define leaves
  # the duty on the default, loudly, exactly as an untranslatable tier does.
  case "$tier" in
    cheap|expensive)
      local alias_var="BOT_CLI_TIER_${tier^^}" alias_value
      alias_value="${!alias_var:-}"
      if [ -z "$alias_value" ]; then
        warn "session model: kind=$kind asked for the $tier tier but agent profile ${BOT_AGENT:-unknown} names no $alias_var — staying on the default"
        return 0
      fi
      tier="$alias_value" ;;
  esac
  # D3, and the failure mode it exists to stop: silently ignoring a configured
  # override is what makes an operator think they saved something. Both ways a
  # profile can fail to honour a tier — no translation at all, and a
  # translation that refuses this particular tier — leave the duty on the
  # default and SAY SO, naming the profile and the kind. Never silently.
  if ! declare -F bot_cli_model_cmd >/dev/null 2>&1; then
    warn "session model: kind=$kind asked for tier=$tier but agent profile ${BOT_AGENT:-unknown} expresses no model translation — staying on the default invocation"
    return 0
  fi
  # The hook answers in an array, because a tier is not always one token: the
  # profile owns the whole translation from "this duty wants a cheaper tier"
  # to its own flags, exactly as it already owns bot_cli_probe and
  # bot_session_acted. Cleared first so a hook that returns 0 without writing
  # cannot hand us the PREVIOUS kind's invocation.
  BOT_CLI_MODEL_CMD=()
  if ! bot_cli_model_cmd "$tier" || [ "${#BOT_CLI_MODEL_CMD[@]}" -eq 0 ]; then
    warn "session model: kind=$kind asked for tier=$tier but agent profile ${BOT_AGENT:-unknown} cannot express it — staying on the default invocation"
    return 0
  fi
  _SESSION_CLI_CMD=("${BOT_CLI_MODEL_CMD[@]}")
  _SESSION_TIER="$tier"
}

# _session_structured_cmd — opt this dispatch into its profile's structured
# output without assuming a vendor flag. The hook receives the invocation
# after model-tier resolution, so accounting cannot silently put a tiered
# session back onto the default model. A missing/refusing hook is the exact
# legacy path.
_session_structured_cmd() {
  _SESSION_STRUCTURED=no
  declare -F bot_cli_structured_cmd >/dev/null 2>&1 || return 0
  BOT_CLI_STRUCTURED_CMD=()
  if bot_cli_structured_cmd "${_SESSION_CLI_CMD[@]}" \
      && [ "${#BOT_CLI_STRUCTURED_CMD[@]}" -gt 0 ] \
      && declare -F bot_cli_structured_prose >/dev/null 2>&1; then
    _SESSION_CLI_CMD=("${BOT_CLI_STRUCTURED_CMD[@]}")
    _SESSION_STRUCTURED=yes
  fi
}

# _session_usage_suffix STRUCTURED_LOG SESSION_DIR PROSE_LOG — the usage
# fields for the SESSION END line, or nothing.
#
# The hook is handed FOUR things and owns which of them it needs: a profile
# that reports on stdout reads the structured log, and one that reports in a
# session artifact gets the session dir, the advertised prose log, and this
# dispatch's session id beside them (#475 D8).
#
# The id is the fourth argument and is the newest of them (#571 D4). It is
# passed rather than left to the profile to mirror for one reason: it is the
# same value `_session_sid_suffix` puts in `sid=` on the very line these
# figures land on, so the figures and the transcript named beside them cannot
# disagree about which session they describe. A profile keeping its own copy
# could — the copy would go stale exactly when the pin failed, which is the
# case where the record must be absent rather than approximate. `unknown` is
# passed through unchanged and means no transcript is addressable; the profile
# refuses it, because only the profile knows whether it needed one.
#
# Nothing kimi-specific reaches this function, and nothing should: the path
# template, the record shape and the JSONL read all live in the profile.
_session_usage_suffix() {
  local structured dir slog normalized
  structured="$1"
  dir="$2"
  slog="$3"
  declare -F bot_cli_usage >/dev/null 2>&1 || return 0
  normalized="$(bot_cli_usage "$structured" "$dir" "$slog" "$_SESSION_SID")" || return 0
  jq -er '
    " input_tokens=\(.input_tokens)" +
    " output_tokens=\(.output_tokens)" +
    (if has("cache_creation_input_tokens")
      then " cache_creation_input_tokens=\(.cache_creation_input_tokens)" else "" end) +
    (if has("cache_read_input_tokens")
      then " cache_read_input_tokens=\(.cache_read_input_tokens)" else "" end) +
    (if has("cost_usd") then " cost_usd=\(.cost_usd)" else "" end) +
    " session_id=\(.session_id | @uri)" +
    " model=\(.model | @uri)" +
    (if (.models // 0) > 1 then " models=\(.models)" else "" end)
  ' <<<"$normalized" 2>/dev/null || true
}

# _session_sid_suffix — ` sid=<id>` for the SESSION END line.
#
# A one-field helper looks like ceremony until you read #553's parity guard,
# which is what requires it. That guard derives each emitter's field ORDER from
# its source, and it reads every literal token on the `log "SESSION END` line
# before any token reached through an interpolated suffix. That model is
# faithful to the wire only while every suffix sits at the tail of the line —
# true for `$usage_suffix$pool_suffix`, and false the moment a literal ` sid=`
# is appended PAST them, which is where D3 requires this field to go.
#
# Written literally, `sid` therefore sorts beside `peak_rss` in the derived
# order while sitting last on the wire, and the only way to satisfy the guard
# would be to emit `sid=` mid-line in the reconstructed terminal — encoding a
# divergence between the two emitters to satisfy an artifact of how their
# parity is measured. Reached through a helper instead, the derived order and
# the wire order are the same list on both sides, and `sid=` stays last on both
# without the guard being weakened to allow it.
_session_sid_suffix() {
  printf ' sid=%s' "$_SESSION_SID"
}

# _session_why_suffix — ` why=<reason>` for the SESSION END line (#759): the
# wake's reason, as the host wrote it to $DUTY_DIR/.wake-reason before this
# tick (duty.sh reads it into WAKE_REASON) or `cron` when the box's own cron
# fired with nothing written. Sanitised to one token: a reason is a list of
# `kind#item` words joined by commas, never free text. Sits past the pool
# usage suffix and ahead of the pool suffix and of `sid=`, which #538 keeps
# last.
_session_why_suffix() {
  local why="${WAKE_REASON:-cron}"
  why="${why//[^A-Za-z0-9._:#,\/-]/_}"
  [ -n "$why" ] || why=cron
  printf ' why=%s' "$why"
}

_session_pool_suffix() {
  local pool="${SESSION_CREDENTIAL_POOL:-}"
  [ -n "$pool" ] || return 0
  case "$pool" in
    *[!A-Za-z0-9._:-]*)
      # warn() writes to stdout, but this helper is captured as line data.
      # Keep the diagnostic out of the SESSION END suffix.
      warn "session accounting: SESSION_CREDENTIAL_POOL must be a safe token — omitting pool identity" >&2
      return 0
      ;;
  esac
  printf ' pool=%s' "$pool"
}

# _session_left STAMP — count processes that survived this session by the
# identity exported only into its dispatch environment (#529). Command lines
# are deliberately irrelevant: an exact NUL-delimited environment entry
# cannot match this reader or another session by accident. An unreadable
# procfs means the measurement is unknown, never that nothing survived.
_session_left() {
  local stamp="$1" proc_root="${SESSION_PROC_ROOT:-/proc}"
  local environ rc count=0 scanned=0
  [ -d "$proc_root" ] || { printf unknown; return 0; }
  for environ in "$proc_root"/[0-9]*/environ; do
    [ -f "$environ" ] || continue
    if grep -Fzxq -- "DUTY_SESSION_STAMP=$stamp" "$environ" 2>/dev/null; then
      rc=0
    else
      rc=$?
    fi
    case "$rc" in
      0) count=$((count + 1)); scanned=$((scanned + 1)) ;;
      1) scanned=$((scanned + 1)) ;;
    esac
  done
  [ "$scanned" -gt 0 ] || { printf unknown; return 0; }
  printf '%s' "$count"
}

# _session_log_bytes FILE — the final advertised session log size. SESSION
# START's log= is a path; SESSION END's log= is a byte count. The record kind
# gives the shared token its type, and keeping the ruled name avoids a second
# alias for the same log (#529).
_session_log_bytes() {
  local bytes
  bytes="$(stat -c %s -- "$1" 2>/dev/null)" || bytes=unknown
  case "$bytes" in
    '' | *[!0-9]*) printf unknown ;;
    *) printf '%s' "$bytes" ;;
  esac
}

# --- session identity, and the one resume it buys (#538) --------------------
#
# What the engine could not say. `run_session` captures the CLI's stdout and
# nothing else, while the vendor mints its own session id and keeps the whole
# transcript under it. So a session killed at its wall leaves its entire
# context complete and intact on disk, and no record this fleet keeps can name
# the file. The measured case: an operator session killed at `rc=124 dur=1800s`
# left a 548 KB, 242-entry transcript whose last write was 69 ms before the
# kill, and the next tick started from zero. On 2026-08-25 the fleet re-derived
# the same failing idiom three times in a row on one pull request.
#
# D1 — THE ENGINE MINTS THE ID; IT NEVER DISCOVERS IT. Discovery means parsing
# vendor output for an identifier, which is the failure mode #529 D2 already
# refuses for `left=`. The id is generated here and pinned on the launch, so
# the engine knows it before the CLI runs and does not have to be told.
#
# D2 — TWO HOOKS, NOT ONE, because pinning an id and resuming one are different
# vendor capabilities and a CLI may have the first without the second. They are
# `declare -F`-guarded exactly as `bot_session_acted` is: an absent
# `bot_cli_session_id_args` means no id is pinned and `sid=` is `unknown`; an
# absent `bot_cli_resume_args` means this profile never resumes and the lane
# behaves exactly as it does today. Measured on the `claude` CLI at 2.1.220 and
# recorded on the PR: `--session-id <uuid>` on a SECOND launch fails outright
# with `Session ID <uuid> is already in use.` and `rc=1`. So the two fragments
# are not merely separable — rendering the pin fragment onto a resume would
# fail the session, which is why nothing here composes them.
#
# WHY THERE IS NO `resumed=` TOKEN, and no third record kind. A resumed session
# carries the KILLED session's `sid` on its own `SESSION START`, so the repeat
# is the record: an operator reading `duty.log` sees one id twice and a reader
# comparing the two lines needs nothing else. A `SESSION RESUME` line would be
# a new record shape for every reader of this log — the floor's units, the
# orphan reconciler's start/end pairing — bought for a fact the existing shape
# already carries.

# The resume bound (D7), and it is deliberately NOT env-overridable and not a
# `fleet.defaults.conf` key. The whole safety argument in `_session_resume_plan`
# rests on this being small, and a tunable invites raising it in exactly the
# incident where raising it is worst. A second resume, if it is ever wanted, is
# a deliberate change with its own evidence — not a config edit.
SESSION_RESUME_MAX_TRIES=1
# Continuation (#760): a session that ended `ok` is resumed by the NEXT
# dispatch of the same kind and key — the vendor session continues, so the
# next session starts from where the last one stopped instead of re-reading
# the world. Bounded by SESSION_CONTINUE_MAX_TRIES consecutive continuations
# (the vendor's own compaction carries a long chain; the cap is what stops a
# chain nobody meant), and broken by any non-ok outcome, which hands the
# decision to the kill-resume above.
SESSION_CONTINUE_MAX_TRIES="${SESSION_CONTINUE_MAX_TRIES:-12}"

# Set by `_session_resume_plan` when the next dispatch continues a session.
# The outcome is carried in the stub rather than rediscovered from duty.log,
# so the resumed prompt can say why the predecessor stopped.
_SESSION_RESUME_OUTCOME=""

# Set after a fresh, unpinned dispatch when the profile can read the identity
# its provider emitted. This id belongs only to the resume stub: it was not
# knowable at SESSION START, so both records for that fresh dispatch continue
# to say sid=unknown. A resumed dispatch reads the value from the stub before
# launch and therefore carries it on both records in the usual way (#673).
_SESSION_OBSERVED_SID=""

# _session_sid_valid SID — a UUID-shaped safe token and nothing else. The
# version nibble is deliberately unconstrained: the kernel mint observed by
# #538 is v4, while Codex 0.146.0 emits a v7-shaped thread id (#673). The shape is
# checked with a glob and the alphabet with a substitution, so no `[[ =~ ]]`
# and no fork. Two guards rather than one, and THE SECOND READS ONLY THE
# POSITIONS THE FIRST LEFT FREE: the glob fixes the length and pins a dash at
# 9, 14, 19 and 24; the four dashes are then cut out by position and every one
# of the remaining thirty-two characters must be hex — dash included in what
# that refuses.
#
# The shape this replaced ran `${1//[0-9a-fA-F-]/}` over the WHOLE string,
# which strips `-` in every position, so the alphabet guard never constrained
# where a dash sat and `------------------------------------` passed both
# guards. A stub carrying it satisfied this reader, reached `bot_cli_resume_args`
# and burned the episode's one resume on an id no CLI would accept. Failing
# open is the one direction a validator whose whole job is the failure
# direction may not fail (#596 review).
_session_sid_valid() {
  local sid="${1:-}"
  case "$sid" in
    ????????-????-????-????-????????????) ;;
    *) return 1 ;;
  esac
  sid="${sid:0:8}${sid:9:4}${sid:14:4}${sid:19:4}${sid:24:12}"
  case "${sid//[0-9a-fA-F]/}" in
    '') return 0 ;;
    *) return 1 ;;
  esac
}

# _session_mint_sid — this dispatch's id, or `unknown`. The kernel's own
# generator first because it costs a read and no fork; `uuidgen` is the
# fallback for a guest without that procfs entry. A box that can produce
# neither gets `unknown`, which pins nothing, stubs nothing and resumes
# nothing — the failure direction every path here takes.
_session_mint_sid() {
  local sid=""
  { read -r sid </proc/sys/kernel/random/uuid; } 2>/dev/null || sid="" # Decision-path empty fallback: an unread generator falls through to uuidgen, and an id that stays empty mints `unknown`.
  if ! _session_sid_valid "$sid"; then
    sid="$(uuidgen 2>/dev/null)" || sid="" # Decision-path empty fallback: `unknown` below pins nothing, stubs nothing and resumes nothing.
  fi
  _session_sid_valid "$sid" && printf '%s' "$sid" || printf unknown
  return 0
}

# _session_head_valid REF — a commit id this engine will compare. Hex and
# 7..64 wide, so both object formats are covered and `unknown` is refused by
# construction rather than by a second case.
_session_head_valid() {
  local ref="${1:-}"
  [ "${#ref}" -ge 7 ] && [ "${#ref}" -le 64 ] || return 1
  case "${ref//[0-9a-f]/}" in
    '') return 0 ;;
    *) return 1 ;;
  esac
}

# _session_head DIR — the head DIR is sitting at, or `unknown`. Best-effort by
# D5: a `$dir` that is not a work tree is an ordinary state here, not an error,
# and the `unknown` it produces is what D6.2 refuses to resume against.
_session_head() {
  local head
  head="$(git -C "$1" rev-parse HEAD 2>/dev/null)" || head="" # Decision-path empty fallback: `unknown` below is exactly what D6.2 refuses to resume against.
  _session_head_valid "$head" || head=unknown
  printf '%s' "$head"
}

# _session_resume_state KIND KEY — the per-lane stub path, beside the terminal
# breaker's and the budget's state files and named the same way. Keyed by
# `(kind, key)` because that pair is what a dispatch resumes: two lanes at the
# same key are different work, and one lane at two keys is two conversations.
#
# THE PATH IS NOT THE IDENTITY. The key is folded to a filename alphabet, and
# the fold is lossy: `review foo/bar_baz` and `review foo_bar/baz` both reach
# `.session-resume.review.foo_bar_baz`. So the identity is carried INSIDE the
# stub — `_session_resume_record` writes the exact `(kind, key)` and
# `_session_resume_read` returns nothing for a stub whose pair is not the
# caller's.
#
# Nothing about the head contains this, and an earlier comment here claimed it
# did (#596 review). Within a lane `$dir` is the repo CLONE, shared by every
# key in that repo — `run_session review "$SR" "$dir"`, `run_session rebase
# "$R#$N" "$dir"` — so `_session_head "$dir"` returns the same head for every
# one of them and D6.2 disambiguates nothing between two keys that alias. What
# contains it today is only that no pair of live keys aliases, which is a fact
# about the registry and not a property of this code; the next person widening
# a key shape would have inherited that comment as a guarantee.
#
# A collision therefore costs a LOST resume and never a wrong one: the
# aliasing dispatch reads the stub, refuses it on the tuple, and — because the
# stub is consumed on every path, refusal included — deletes it, so both lanes
# dispatch ordinary fresh sessions. That is D6's failure direction, which the
# head comparison could not have delivered here.
_session_resume_state() {
  local kind="$1" key="$2"
  printf '%s/.session-resume.%s.%s' \
    "$DUTY_DIR" "${kind//[^[:alnum:]._-]/_}" "${key//[^[:alnum:]._-]/_}"
}

# _session_continue_state KIND KEY — the continuation stub (#760): `sid=` and
# `try=`, written after an ok session, read by the next dispatch of the same
# kind and key. Beside the kill-resume stub, same slugging, different name.
_session_continue_state() {
  local kind="$1" key="$2"
  printf '%s/.session-continue.%s.%s' \
    "$DUTY_DIR" "${kind//[^[:alnum:]._-]/_}" "${key//[^[:alnum:]._-]/_}"
}

# _session_continue_record KIND KEY RC VERDICT — after an ok session with a
# valid id, record it for the next dispatch; after anything else, forget the
# chain (the kill-resume stub, if any, decides the next dispatch).
# _session_continue_task KIND KEY — the task a continuation is OF, or nothing.
# A transcript is resumed only into a session about the same task: the caller
# names it in SESSION_TASK (the builder's resume set, the reviewer's PR set),
# or the key names it when it is task-shaped (`repo#num`). A session with no
# task identity — a build that picks its own issue, a triage sweep — is never
# continued, because the next one is about something else.
_session_continue_task() {
  local task="${SESSION_TASK:-}"
  if [ -z "$task" ]; then case "$2" in *'#'*) task="$2" ;; esac; fi
  printf '%s' "$task" | tr -c 'A-Za-z0-9#/,._-' '_'
}

_session_continue_record() {
  local kind="$1" key="$2" rc="$3" verdict="$4" state sid try=0 task
  state="$(_session_continue_state "$kind" "$key")"
  task="$(_session_continue_task "$kind" "$key")"
  [ -n "$task" ] || { rm -f "$state" 2>/dev/null || true; return 0; }
  if [ "$rc" -ne 0 ] || [ "$verdict" != ok ]; then
    rm -f "$state" 2>/dev/null || true
    return 0
  fi
  sid="$_SESSION_SID"
  [ "$sid" != unknown ] || sid="$_SESSION_OBSERVED_SID"
  _session_sid_valid "$sid" || { rm -f "$state" 2>/dev/null || true; return 0; }
  [ "$_SESSION_RESUME_OUTCOME" = continue ] && try="$_SESSION_CONTINUE_TRY"
  printf 'sid=%s\ntry=%s\ntask=%s\n' "$sid" "$try" "$task" >"$state.tmp" && mv -f "$state.tmp" "$state"
}

# _session_continue_plan KIND KEY — the continuation half of the resume plan:
# called only when no kill-resume stub spoke. Resumes the recorded id when the
# chain is under its cap, the profile can resume at all, and — when the
# profile can say — the transcript is still on disk.
_session_continue_plan() {
  local kind="$1" key="$2" dir="$3" state sid="" try="" task="" field value
  state="$(_session_continue_state "$kind" "$key")"
  [ -r "$state" ] || return 0
  while IFS='=' read -r field value; do
    case "$field" in sid) sid="$value" ;; try) try="$value" ;; task) task="$value" ;; esac
  done <"$state"
  _session_sid_valid "$sid" || { rm -f "$state"; return 0; }
  # The same task, or no continuation: a stub from another task is stale.
  if [ -z "$task" ] || [ "$task" != "$(_session_continue_task "$kind" "$key")" ]; then
    rm -f "$state"; return 0
  fi
  case "$try" in ''|*[!0-9]*) try=0 ;; esac
  if [ "$try" -ge "${SESSION_CONTINUE_MAX_TRIES:-12}" ]; then
    rm -f "$state"; return 0
  fi
  if ! declare -F bot_cli_resume_cmd >/dev/null 2>&1 \
      && ! declare -F bot_cli_resume_args >/dev/null 2>&1; then
    return 0
  fi
  if declare -F bot_session_transcript_present >/dev/null 2>&1 \
      && ! bot_session_transcript_present "$sid" "$dir"; then
    rm -f "$state"; return 0
  fi
  _SESSION_SID="$sid"
  _SESSION_RESUMED=yes
  # The continuation chain has its own count; the kill-resume try stays 0, so a
  # continued session that is killed is still kill-resumable once.
  _SESSION_CONTINUE_TRY=$((try + 1))
  _SESSION_TRY=0
  _SESSION_RESUME_OUTCOME="continue"
}

# _session_resume_read FILE KIND KEY — the stub's fields, validated, as `k=v`
# lines; or nothing. NOTHING IS THE ONLY FAILURE MODE, and it is what "a stub
# that is missing, unreadable, or ambiguous is treated as absent, never as
# resumable" means in code: a missing file, a short read, a repeated key, a
# field that is not the shape it has to be, a line this writer never writes,
# OR A STUB WHOSE `(kind, key)` IS NOT THE CALLER'S all produce the same empty
# answer, and the caller then dispatches an ordinary session.
#
# The tuple is a gate and not a datum, so it is checked here and left out of
# what this prints: `_session_resume_plan` reads the resumability fields and
# has the pair in its own arguments already.
#
# The read is bounded at 64 lines so a stub that is not one — a log rotated
# onto the path, a file an operator dropped there — cannot make this loop the
# expensive part of a dispatch.
#
# THE `left=` FIELD IS READ INTO `survivor_count`, AND THE MISMATCH IS
# DELIBERATE — do not "tidy" the local back to `left`. The wire name is fixed
# by #529 and stays on disk; the local is free, and a local named `left` is
# not. `[ "$survivor_count" -eq 0 ]` in `_session_resume_plan` is an
# arithmetic context, which is what tells shellcheck the name is numeric — and
# ci-shell runs `shellcheck -x`, so every name declared here is visible in
# every file that reaches this one through a `source`. `shared/test/builder.sh`
# has an unquoted bare word `r1=left-alone`; with a numeric `left` in scope
# that reads as `left - alone` and SC2100 fails the whole job, in a file this
# change never touches. `survivor_count` is also simply the better name: it is
# what `run_session` already calls this quantity where it emits it.
_session_resume_read() {
  local file="$1" want_kind="${2-}" want_key="${3-}" line field value lines=0
  local kind="" key="" sid="" head="" wall="" try="" logb="" outcome="" productive=""
  local survivor_count="" task=""
  local seen=""
  [ -s "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    lines=$((lines + 1))
    [ "$lines" -le 64 ] || return 0
    field="${line%%=*}"
    value="${line#*=}"
    # A line with no `=` leaves field and value equal to the whole line; that
    # is not a field this writer produces, so the stub is not one either.
    [ "$field" != "$line" ] || return 0
    # PRESENCE IS TRACKED SEPARATELY FROM VALUE, and the separation is the
    # whole of this guard. This was eight copies of `[ -z "$x" ] || return 0`,
    # which asks "is it empty?" where it means "have I seen it?" — so a stub
    # whose FIRST `kind=` was empty let a second `kind=build` straight past the
    # repeated-key refusal, finished with a non-empty `kind`, satisfied the
    # all-fields check below (which reads FINAL values, so it cannot see the
    # ambiguity either) and RESUMED. An ambiguous stub that resumes is the one
    # outcome D6's failure direction forbids, and it contradicted the contract
    # this function states in its own header (#596 review, found independently
    # by two reviewers).
    #
    # `$field` is unquoted in the pattern below, so one carrying a glob
    # metacharacter can only match MORE readily — the worst that produces is a
    # refusal, which is the safe direction; and an unknown field still falls to
    # the `*)` arm. The ten real names are plain lowercase, so no legitimate
    # stub can trip it.
    case " $seen " in *" $field "*) return 0 ;; esac
    seen="$seen $field"
    case "$field" in
      kind) kind="$value" ;;
      key) key="$value" ;;
      sid) sid="$value" ;;
      head) head="$value" ;;
      wall) wall="$value" ;;
      try) try="$value" ;;
      log) logb="$value" ;;
      outcome) outcome="$value" ;;
      productive) productive="$value" ;;
      left) survivor_count="$value" ;;
      task) task="$value" ;;
      *) return 0 ;;
    esac
  done <"$file"
  # Every field is required. A short stub was half-written when the box died,
  # so it is never treated as resumable.
  [ -n "$kind" ] && [ -n "$key" ] && [ -n "$sid" ] && [ -n "$head" ] \
    && [ -n "$wall" ] && [ -n "$try" ] && [ -n "$logb" ] && [ -n "$outcome" ] \
    && [ -n "$productive" ] && [ -n "$survivor_count" ] || return 0
  # The identity the path could not carry. A stub reached through a colliding
  # fold names the OTHER lane's pair, and a lane that is not this one is not a
  # session this dispatch may continue.
  [ "$kind" = "$want_kind" ] && [ "$key" = "$want_key" ] || return 0
  _session_sid_valid "$sid" || return 0
  { _session_head_valid "$head" || [ "$head" = unknown ]; } || return 0
  case "$wall" in '' | *[!0-9]*) return 0 ;; esac
  case "$try" in '' | *[!0-9]*) return 0 ;; esac
  case "$logb" in unknown) ;; '' | *[!0-9]*) return 0 ;; esac
  case "$outcome" in TIMEOUT | MEMORY) ;; *) return 0 ;; esac
  case "$productive" in yes | no) ;; *) return 0 ;; esac
  case "$survivor_count" in unknown) ;; '' | *[!0-9]*) return 0 ;; esac
  # A stub written before `task=` existed carries none and resumes as it did;
  # one that names a task resumes only into a dispatch for that same task.
  if [ -n "$task" ] && [ "$task" != - ] \
      && [ "$task" != "$(_session_continue_task "$want_kind" "$want_key" | tr -d '\n')" ]; then
    return 0
  fi
  printf 'sid=%s\nhead=%s\nwall=%s\ntry=%s\nlog=%s\noutcome=%s\nproductive=%s\nleft=%s\n' \
    "$sid" "$head" "$wall" "$try" "$logb" "$outcome" "$productive" "$survivor_count"
}

# _session_resume_plan KIND KEY DIR — decide whether this dispatch continues
# the killed session, into _SESSION_SID / _SESSION_RESUMED / _SESSION_TRY.
#
# D6, and its governing sentence: THE FAILURE DIRECTION IS NEVER TO RESUME.
# Every condition below is written so that a fact this engine cannot establish
# reads as a refusal, and every refusal discards the stub and dispatches an
# ordinary fresh session.
#
#  1  a stub exists for this `(kind, key)` and parses;
#  2  its head is not `unknown` and equals `$dir`'s head now — a moved head
#     means the world changed and the carried context is about a tree that is
#     gone;
#  3  the killed session's log did not classify as terminal/error output. The
#     old non-empty test admitted the incident's 15-byte `Execution error`;
#  4  nothing of that session was still alive — `left=0` on its record. This is
#     the load-bearing one and the reason #529 is a functional predecessor and
#     not only a file collision: resuming a lane while a process of the
#     previous session still runs puts two live sessions on one key, and that
#     counter is the only thing that can see it. `unknown` is not zero;
#  5  the try count is below SESSION_RESUME_MAX_TRIES;
#  6  the profile defines a fragment or whole-command resume hook.
#
# THE STUB IS CONSUMED ON EVERY PATH, resume and refusal alike. A stub that
# survived its own refusal would be re-read on the next dispatch against the
# same facts and refused again forever; a stub that survived its own resume
# would be the second resume D7 exists to forbid.
_session_resume_plan() {
  local kind="$1" key="$2" dir="$3" state fields
  local sid="" head="" try="" logb="" outcome="" productive="" survivor_count=""
  _SESSION_SID=""
  _SESSION_RESUMED=no
  _SESSION_TRY=0
  _SESSION_CONTINUE_TRY=0
  _SESSION_RESUME_OUTCOME=""
  state="$(_session_resume_state "$kind" "$key")"
  fields="$(_session_resume_read "$state" "$kind" "$key")"
  rm -f "$state" 2>/dev/null || true
  if [ -z "$fields" ]; then
    _session_continue_plan "$kind" "$key" "$dir"
    return 0
  fi
  while IFS='=' read -r field value; do
    case "$field" in
      sid) sid="$value" ;; head) head="$value" ;; try) try="$value" ;;
      log) logb="$value" ;; outcome) outcome="$value" ;; productive) productive="$value" ;;
      left) survivor_count="$value" ;;
    esac
  done <<<"$fields"
  : "$logb" # Retained record evidence; `productive=` is the decision (#600).
  [ "$head" != unknown ] || return 0
  [ "$head" = "$(_session_head "$dir")" ] || return 0
  [ "$productive" = yes ] || return 0
  [ "$survivor_count" != unknown ] && [ "$survivor_count" -eq 0 ] || return 0
  [ "$try" -lt "$SESSION_RESUME_MAX_TRIES" ] || return 0
  if ! declare -F bot_cli_resume_cmd >/dev/null 2>&1 \
      && ! declare -F bot_cli_resume_args >/dev/null 2>&1; then
    return 0
  fi
  _SESSION_SID="$sid"
  _SESSION_RESUMED=yes
  _SESSION_TRY=$((try + 1))
  _SESSION_RESUME_OUTCOME="$outcome"
  return 0
}

# _session_splice_cli_args ARGS… — put ARGS into this dispatch's invocation.
#
# Ahead of a trailing `-p`, for the reason `bot_cli_model_cmd` gives: run_session
# appends the prompt as the final argument, and `claude -p <prompt>` is what
# makes it the prompt rather than a stray operand. Any other shape an operator
# overlay might carry takes the fragment on the end.
_session_splice_cli_args() {
  [ "$#" -gt 0 ] || return 0
  local last=$(( ${#_SESSION_CLI_CMD[@]} - 1 ))
  if [ "$last" -ge 0 ] && [ "${_SESSION_CLI_CMD[last]}" = "-p" ]; then
    _SESSION_CLI_CMD=("${_SESSION_CLI_CMD[@]:0:last}" "$@" -p)
  else
    _SESSION_CLI_CMD=("${_SESSION_CLI_CMD[@]}" "$@")
  fi
}

# _session_identity KIND KEY DIR — resolve this dispatch's session id and pin
# it on the invocation. Runs AFTER `_session_cli_cmd` and `_session_structured_cmd`,
# so the fragment is spliced into the invocation those two already resolved and
# neither the model tier nor the structured-output flag can be displaced by it.
#
# A hook that refuses, or renders nothing, leaves the invocation byte-identical
# to what it was — the same contract `bot_cli_structured_cmd` has. On the resume
# side that refusal costs the resume too: `_SESSION_RESUMED` goes back to `no`,
# a fresh id is minted, and the session that runs is an ordinary one.
_session_identity() {
  local kind="$1" key="$2" dir="$3"
  _SESSION_OBSERVED_SID=""
  _session_resume_plan "$kind" "$key" "$dir"
  if [ "$_SESSION_RESUMED" = yes ]; then
    if declare -F bot_cli_resume_cmd >/dev/null 2>&1; then
      BOT_CLI_RESUME_CMD=()
      if bot_cli_resume_cmd "${_SESSION_CLI_CMD[@]}" "$_SESSION_SID" \
          && [ "${#BOT_CLI_RESUME_CMD[@]}" -gt 0 ]; then
        _SESSION_CLI_CMD=("${BOT_CLI_RESUME_CMD[@]}")
        return 0
      fi
    else
      BOT_CLI_RESUME_ARGS=()
      if bot_cli_resume_args "$_SESSION_SID" \
          && [ "${#BOT_CLI_RESUME_ARGS[@]}" -gt 0 ]; then
        _session_splice_cli_args "${BOT_CLI_RESUME_ARGS[@]}"
        return 0
      fi
    fi
    _SESSION_SID=""
    _SESSION_RESUMED=no
    _SESSION_TRY=0
    _SESSION_RESUME_OUTCOME=""
  fi
  _SESSION_SID="$(_session_mint_sid)"
  [ "$_SESSION_SID" != unknown ] || return 0
  # No pin hook is not a failure and warns about nothing: it is D2's stated
  # neutral answer, and the lane's sessions are otherwise unchanged. What the
  # engine loses is the ability to name the transcript, which is what `sid=`
  # then says on both lines.
  if declare -F bot_cli_session_id_args >/dev/null 2>&1; then
    BOT_CLI_SESSION_ID_ARGS=()
    if bot_cli_session_id_args "$_SESSION_SID" \
        && [ "${#BOT_CLI_SESSION_ID_ARGS[@]}" -gt 0 ]; then
      _session_splice_cli_args "${BOT_CLI_SESSION_ID_ARGS[@]}"
      return 0
    fi
  fi
  # Minted but not pinned: the CLI will mint its own id and this one names
  # nothing on disk, so claiming it on the record would be worse than saying
  # the engine cannot tell.
  _SESSION_SID=unknown
  return 0
}

# _session_observe_identity STRUCTURED_LOG SESSION_DIR PROSE_LOG — let an
# unpinned provider declare the identity it emitted after a fresh dispatch.
# The profile owns the structured-record selection; the engine owns the final
# safe-token validation. Missing, malformed, ambiguous and refusing answers
# all collapse to no observed id and therefore no resume stub.
_session_observe_identity() {
  local observed=""
  _SESSION_OBSERVED_SID=""
  [ "$_SESSION_RESUMED" = no ] || return 0
  declare -F bot_cli_session_id_args >/dev/null 2>&1 && return 0
  declare -F bot_cli_observed_session_id >/dev/null 2>&1 || return 0
  observed="$(bot_cli_observed_session_id "$1" "$2" "$3")" || observed="" # Decision-path empty fallback: a refusing observation means no identity and therefore no resume stub.
  _session_sid_valid "$observed" || return 0
  _SESSION_OBSERVED_SID="$observed"
  return 0
}

_session_resume_admitted() { # _session_resume_admitted RC VERDICT
  case "$2" in
    TIMEOUT) [ "$1" -eq 124 ] ;;
    MEMORY) [ "$1" -ne 0 ] ;;
    *) return 1 ;;
  esac
}

# _session_resume_record KIND KEY DIR RC WALL LOG_BYTES LEFT VERDICT ACTED LOG
# — the stub, D5.
#
# Written on a TIMEOUT or MEMORY end and on nothing else; ANY other end deletes
# it, which keeps a stub from outliving the episode that produced it. It
# returns 0 on every path — recovery must never be able to fail a session.
#
# THE GATE IS THE VERDICT AND NOT THE RAW `rc`. MEMORY may arrive with 124,
# 137, or 143 depending on whether the kernel kill coincided with timeout's
# wall; the verdict is the engine's resolved fact and admits all three. A
# TIMEOUT still requires 124, preserving the original wall-clock contract.
#
# The decision lives INSIDE this function rather than at the call site, and
# that placement is load-bearing: the caller cannot simply skip the call on a
# classified end, because the delete is here too. Guarding the call would leave
# a previous resumable stub alive across an ordinary end.
#
# WHAT IT CARRIES, and why it is ten fields rather than D5's four. The `sid`,
# the head, the wall and the try count are D5's list. `kind` and `key` are the
# lane's identity, written because the filename cannot hold it — see
# `_session_resume_state`, where the fold is lossy — and read back as a gate:
# a stub whose pair is not the reader's is another lane's and is refused. A
# key carrying a newline would write a stub its own reader then refuses, which
# is the same failure direction; no key this engine dispatches has one (`$R`,
# `$R#$N`, `fleet`). `log` preserves the old byte evidence while `productive`
# replaces it as the gate; that value comes from the shipped action classifier,
# with the terminal classifier as an additional refusal, while the killed log
# still exists. `outcome` supplies the informed prompt, and `left` is the
# survivor count only the ending dispatch can see.
#
# The write is not atomic, deliberately. A box that dies mid-write leaves a
# stub missing fields, and `_session_resume_read` requires all ten — so the
# truncated stub reads as absent, which is the answer it should get. A rename
# dance would buy the same outcome through a second mechanism.
_session_resume_record() {
  local kind="$1" key="$2" dir="$3" rc="$4" wall="$5" logb="$6" survivor_count="$7"
  local verdict="$8" acted="$9" slog="${10}" productive=no state record_sid
  local transcript_productive=unknown hook_rc
  state="$(_session_resume_state "$kind" "$key")"
  # TIMEOUT keeps its 124 invariant. MEMORY instead requires only a dirty end:
  # its raw status varies with which kernel/timeout signal reached reap first.
  if ! _session_resume_admitted "$rc" "$verdict"; then
    rm -f "$state" 2>/dev/null || true
    return 0
  fi
  # An id the engine does not hold names no transcript, so a stub carrying it
  # could never satisfy D6 anyway. Refuse to write one rather than leave a file
  # whose only possible future is being discarded.
  record_sid="$_SESSION_SID"
  [ "$record_sid" != unknown ] || record_sid="$_SESSION_OBSERVED_SID"
  _session_sid_valid "$record_sid" \
    || { rm -f "$state" 2>/dev/null || true; return 0; }
  # The optional profile hook reads the killed session's own addressable
  # artifact. Its positive or negative answer outranks stdout; an absent hook
  # or `cannot tell` preserves the shipped action-classifier fallback. Keep
  # terminal as a second refusal so vendor endings never become resumable if a
  # profile's transcript vocabulary later recognizes work around the banner.
  if declare -F bot_session_productive >/dev/null 2>&1; then
    bot_session_productive "$record_sid" "$dir" && hook_rc=0 || hook_rc=$?
    case "$hook_rc" in
      0) transcript_productive=yes ;;
      1) transcript_productive=no ;;
    esac
  fi
  if ! session_terminal "$slog"; then
    if [ "$transcript_productive" = yes ] \
        || { [ "$transcript_productive" = unknown ] && [ "$acted" = yes ]; }; then
      productive=yes
    fi
  fi
  case "$wall" in '' | *[!0-9]*) wall=0 ;; esac
  # `task=` is the work the killed session was on (the resume set, the PR
  # set, a `repo#num`), so a later dispatch on OTHER work never resumes this
  # transcript into it — the same rule _session_continue_task applies to
  # continuation. `-` when the lane names no task.
  printf 'kind=%s\nkey=%s\nsid=%s\nhead=%s\nwall=%s\ntry=%s\nlog=%s\noutcome=%s\nproductive=%s\nleft=%s\ntask=%s\n' \
    "$kind" "$key" "$record_sid" "$(_session_head "$dir")" "$wall" \
    "$_SESSION_TRY" "$logb" "$verdict" "$productive" "$survivor_count" \
    "$(_session_continue_task "$kind" "$key" | tr -d '\n')" \
    >"$state" 2>/dev/null || true
  return 0
}

# _session_oom_source — the narrowest kernel counter available to this engine.
# cgroup v2's memory.events counts kills in this service's own cgroup; the
# node-wide vmstat counter is the fallback on older or differently mounted
# systems. The private override is a test seam, not operator configuration.
_session_oom_source() {
  local proc_root="${SESSION_PROC_ROOT:-/proc}" cgroup_root="${_SESSION_CGROUP_ROOT:-/sys/fs/cgroup}"
  local hierarchy controllers path candidate
  if [ -n "${_SESSION_OOM_EVENTS_FILE:-}" ] && [ -r "$_SESSION_OOM_EVENTS_FILE" ]; then
    printf '%s' "$_SESSION_OOM_EVENTS_FILE"
    return 0
  fi
  while IFS=: read -r hierarchy controllers path; do
    if [ "$hierarchy" = 0 ] && [ -z "$controllers" ]; then
      candidate="${cgroup_root%/}${path%/}/memory.events"
      [ -r "$candidate" ] && { printf '%s' "$candidate"; return 0; }
      break
    fi
  done <"$proc_root/self/cgroup" 2>/dev/null
  [ -r "$proc_root/vmstat" ] && printf '%s' "$proc_root/vmstat"
  return 0
}

# _session_oom_count FILE — oom_kill from either memory.events or vmstat.
# Anything unreadable or malformed is no measurement and prints nothing.
_session_oom_count() {
  awk '$1 == "oom_kill" && $2 ~ /^[0-9]+$/ { print $2; exit }' "$1" 2>/dev/null
}

_session_resume_preamble() {
  case "$1" in
    MEMORY)
      printf '%s' 'The previous attempt was terminated because this box ran out of memory. The last command in its log is suspect: do not run it again. Record it as unverified, name the tool and the out-of-memory reason, and continue.'
      ;;
    TIMEOUT)
      printf '%s' 'The previous attempt reached its wall-clock limit. Continue from its existing transcript without repeating completed work.'
      ;;
  esac
}

# run_session KIND KEY DIR TIMEOUT PROMPT — the only way a duty launches the
# box CLI. Adds what every hand-rolled variant lacked somewhere: a timeout (a
# hung session used to hold the flock forever, invisibly), captured exit
# status on every path, a per-session log file, and one structured outcome
# line in duty.log (the biggest logging gap in three of five metrics files).
run_session() {
  local kind="$1" key="$2" dir="$3" tmo="$4" prompt="$5"
  local slog session_stamp cli_log structured_log="" cli_stderr_fd=1 rc=0 start terminal=no
  local oom_source="" oom_before="" oom_after="" oom_delta=- oom_hit=no resume_preamble=""
  # Budget BEFORE the terminal gate, and the order is load-bearing (#464): the
  # terminal gate's recovery path makes a live vendor probe, and a lane that
  # has spent its window must not be able to buy one.
  _session_budget_gate "$kind" "$key" || return 0
  _session_terminal_gate "$kind" "$key" || return 0
  # Both gates passed, so this dispatch is really happening: now, and not
  # before, resolve what it is bought with (#469).
  _session_cli_cmd "$kind"
  _session_structured_cmd
  # D4 — THE RESUME DECISION LIVES HERE, NOT IN THE DUTY LANES. Everything it
  # needs is already an argument to this function: `kind`, `key` and `dir`. So
  # every lane — build, review, triage, mention, hygiene, attention — gets both
  # the id and the resume with no per-lane edit, and `duty-builder.sh` and
  # `duty-review.sh`, the two most contended files on this board, are not
  # touched at all.
  _session_identity "$kind" "$key" "$dir"
  if [ "$_SESSION_RESUMED" = yes ]; then
    resume_preamble="$(_session_resume_preamble "$_SESSION_RESUME_OUTCOME")"
    [ -z "$resume_preamble" ] || prompt="$resume_preamble

$prompt"
  fi
  mkdir -p "$LOG_DIR"
  slog="$LOG_DIR/$(date -u '+%Y%m%dT%H%M%SZ')-$kind-${key//[\/#]/_}.log"
  session_stamp="${slog##*/}"
  cli_log="$slog"
  if [ "$_SESSION_STRUCTURED" = yes ]; then
    structured_log="$slog.structured"
    cli_log="$structured_log"
    # SESSION START advertises the prose path, and every reader selects
    # `*.log`. Keep that path real while the vendor JSON is captured beside
    # it; completion appends restored prose after any diagnostics written here.
    : >"$slog"
    exec {cli_stderr_fd}>>"$slog"
  fi
  # holder=: who to ask, at a later tick, whether this session is still
  # running. Nothing below this line runs if the box dies under the CLI, so
  # the start has to carry the liveness question with it — and it has to be a
  # question about a PROCESS, because a build may legitimately run for two
  # hours and no clock can tell that from a death (#478, common/ledger.sh).
  # sid= is APPENDED, after every token this line already carries, and the
  # position is the whole of its compatibility (D3). The floor's RE_START
  # (fleet-floor/server/floor/units.py) matches `SESSION START kind=(\S+)
  # key=(\S+)` and is unanchored at the end, so a trailing token is simply
  # unread and every deployed floor keeps parsing. Inserting anywhere earlier
  # breaks all of them. This is the same position — and the same reason — as
  # tier=, log=, left= and peak_rss= on SESSION END below.
  log "SESSION START kind=$kind key=$key timeout=${tmo}s log=$slog holder=$(_session_holder) sid=$_SESSION_SID"
  # The tick bought a session: duty.sh's idle counter reads this stamp (#759).
  : >"$DUTY_DIR/.tick-acted" 2>/dev/null || true
  start=$SECONDS
  oom_source="$(_session_oom_source)"
  [ -z "$oom_source" ] || oom_before="$(_session_oom_count "$oom_source")"
  # </dev/null: the CLI reads piped stdin to EOF as context, and stdin here
  # is the caller's while-read work list — without this, the first session
  # of a sweep swallowed every remaining repo (one-iteration loops).
  # env -u: sessions must not inherit the lock/snapshot guards, or a
  # duty.sh/notify.sh invocation from inside a session bypasses the flock.
  # timeout -k: a CLI that ignores TERM still dies 60s later.
  # `&` and a `wait`, and that is the whole of the change the measurement asks
  # of this line (#473): the dispatch needs a NAME before it can be measured,
  # and `$!` is the session's own subshell — the root of the process tree the
  # peak is taken over. Backgrounding costs nothing else here: stdin was
  # already </dev/null, and `wait` reports the same status the foreground
  # list did, timeout's 124 included.
  # The process group is UNCHANGED by the `&`, and is not this shell's —
  # measured, not reasoned: GNU `timeout` calls setpgid(0,0) absent
  # --foreground, so it puts ITSELF in a new group and runs the CLI there.
  # The session has never sat in the engine's group, in this shape or the
  # foreground one it replaced; job control is off in a script, so `&`
  # creates no group of its own. Do not read this line as putting the
  # session under a signal delivered to the engine's group — it never was.
  # The sameness is asserted as a differential against the old foreground
  # list: the D5 block in `test/common/session.sh` runs both shapes and
  # requires them to agree on where the session's group sits.
  # `_session_oom_arm` runs INSIDE the subshell and before the `env`, which is
  # the whole of D1 of #474: `oom_score_adj` is a per-process attribute that
  # survives both fork and exec, so raising it here — in the process that is
  # about to become `timeout`, which forks the CLI — is what puts the session's
  # whole tree above the engine, `cron` and `sshd` in the kernel's victim
  # scoring at the moment the CLI is `exec`'d. It cannot fail the dispatch: it
  # returns 0 on every path, so the `&&` chain is unbroken on a guest with no
  # writable procfs.
  # Structured stdout stays parseable beside the advertised prose log, while
  # diagnostics remain on that prose surface. The restored result is appended
  # after the CLI exits, so neither accounting nor diagnostics erase the other.
  ( cd "$dir" && _session_oom_arm && env -u DUTY_LOCKED -u NOTIFY_LOCKED -u DUTY_SNAPSHOT \
      DUTY_SESSION_STAMP="$session_stamp" \
      timeout -k "$OPERATING_LIMIT_SESSION_KILL_GRACE_SECONDS" "$tmo" \
        "${_SESSION_CLI_CMD[@]}" "$prompt" ) </dev/null >"$cli_log" 2>&"$cli_stderr_fd" &
  _SESSION_DISPATCH_PID=$!
  [ "$cli_stderr_fd" -eq 1 ] || exec {cli_stderr_fd}>&-
  # Started AFTER the dispatch, which is D4 by construction: the session is
  # already running by the time anything about measuring it can go wrong.
  # `.peak` and not `.log`, and LOG_DIR's readers select on that suffix — the
  # floor probe's `ls` does since #473, and `common.sh`'s "one file per
  # session" holds for everything that reads the directory as session logs.
  # The claim is about the SELECTION and not about the suffix: an
  # extension-blind walk here would see two files per running session, so a
  # reader added later has to say `*.log` to keep this true. #474's `.mem`
  # marker is the SECOND such file and rides that same rule: the probe's glob
  # covers it with no edit, which is what "the glob is also the general
  # answer" in `fleet-floor/server/probe.sh` was written for.
  _session_peak_rss_start "$slog.peak" "$_SESSION_DISPATCH_PID"
  # Started after the measurement it reads, and it is a THIRD process rather
  # than a branch inside the watcher (#474 D2): #473's D4 is that no order of
  # events lets measuring a session end it, and the guarantee lives in the
  # shape of `_session_peak_rss_watch`. Teaching that function to kill would
  # repeal D4 inside the function that exists to hold it, so the ceiling is a
  # separate actor reading the same figure off the same file.
  _session_mem_watch_start "$slog.peak" "$slog.mem" "$_SESSION_DISPATCH_PID" "$kind"
  wait "$_SESSION_DISPATCH_PID" || rc=$?
  [ -z "$oom_source" ] || oom_after="$(_session_oom_count "$oom_source")"
  case "$oom_before:$oom_after" in
    *[!0-9:]* | :* | *:) ;;
    *)
      if [ "$oom_after" -ge "$oom_before" ]; then
        oom_delta=$((oom_after - oom_before))
        [ "$oom_delta" -gt 0 ] && oom_hit=yes
      fi
      ;;
  esac
  local survivor_count
  printf -v survivor_count '%s' "$(_session_left "$session_stamp")"
  _session_peak_rss_stop
  _session_mem_watch_stop "$slog.mem"
  if [ -n "$structured_log" ]; then
    bot_cli_structured_prose "$structured_log" >>"$slog" 2>/dev/null \
      || cat "$structured_log" >>"$slog"
  fi
  # Fresh providers that cannot accept an engine-minted id may declare the id
  # they emitted in their structured record. It is intentionally observed
  # after dispatch and before the resume stub is considered (#673).
  _session_observe_identity "$structured_log" "$dir" "$slog"
  local dur=$((SECONDS - start)) verdict=ok acted reply_tail peak_rss mem_hit log_bytes
  local usage_suffix pool_suffix sid_suffix why_suffix
  sid_suffix="$(_session_sid_suffix)"
  mem_hit="$(session_mem_hit "$slog.mem")"
  [ "$rc" -eq 124 ] && verdict=TIMEOUT
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && verdict=FAILED
  # The ceiling OUTRANKS the timeout and the terminal classifier, and it has to
  # be a branch rather than an extra condition on the one below (D4 of #474).
  # A session the engine killed reports whatever `timeout` reported for being
  # signalled — 143, or 124 if the deadline landed in the same instant — and
  # both of those read as the CLI's own verdict on the line. Worse, the log of
  # a killed session is a TRUNCATED log, and `session_terminal` classifies
  # truncated output for a living: routing this through it would let a memory
  # kill count toward the vendor breaker and stop a lane for a reason the
  # vendor had nothing to do with.
  if [ -n "$mem_hit" ]; then
    verdict="$SESSION_MEM_OUTCOME"
  elif [ "$oom_hit" = yes ] && [ "$verdict" != ok ]; then
    verdict="$SESSION_MEM_OUTCOME"
  elif [ "$verdict" = FAILED ] && session_terminal "$slog"; then
    verdict=TERMINAL
    terminal=yes
  fi
  acted="$(session_acted "$slog")"
  reply_tail="$(session_reply_tail "$slog")"
  printf -v log_bytes '%s' "$(_session_log_bytes "$slog")"
  peak_rss="$(session_peak_rss "$slog.peak")"
  # Usage reporting is profile-owned and independent of the capture shape.
  # Claude reads structured_log; an artifact-backed profile can instead use
  # the session directory and advertised prose log supplied beside it (#475).
  usage_suffix="$(_session_usage_suffix "$structured_log" "$dir" "$slog")"
  # A pool is useful only beside figures it groups. Keeping it off a missing
  # or malformed usage block also preserves the exact legacy SESSION END line
  # promised to profiles that cannot report structured output (#475).
  if [ -n "$usage_suffix" ]; then
    pool_suffix="$(_session_pool_suffix)"
  else
    pool_suffix=""
  fi
  why_suffix="$(_session_why_suffix)"
  rm -f "$slog.peak" "$slog.mem" 2>/dev/null || true
  [ -z "$structured_log" ] || rm -f "$structured_log" 2>/dev/null || true
  # log= and left= are appended immediately after reply_tail (#529), then the
  # established suffix continues with tier=. The floor's RE_END is unanchored,
  # so deployed floors retain acted/reply_tail while ignoring the new tokens.
  #
  # tier= is APPENDED, after reply_tail, and the position is the whole of D5's
  # compatibility (#469). This chain is justified by an aggregate read off
  # these lines, so a field that breaks the measurement would be a poor way to
  # end it. Two readers constrain where it can go:
  #
  #   - the operator's own awk splits every token on `=` into a map, so it
  #     takes a new field anywhere and gains a column for free;
  #   - the floor's RE_END (fleet-floor/server/floor/units.py) matches
  #     `… outcome=(\S+)(?: acted=… reply_tail=(\S*))?` and is unanchored at
  #     the end. INSERTING before `acted=` would break that optional group and
  #     silently drop acted and reply_tail on every line; appending after it
  #     leaves the match untouched and the trailing token simply unread.
  #
  # So the floor keeps working with no edit, which matters because D7 fences
  # fleet-floor out of this issue. The orphan reconciler already appends
  # `started=` past reply_tail the same way (common/ledger.sh), so this is the
  # established position rather than a new one.
  #
  # peak_rss= is appended past tier= for the same reason and OMITTED ENTIRELY
  # when the kernel gave no figure (#473 D2): a `peak_rss=0` or an
  # `unknown` would be a measurement claimed by a session nobody measured,
  # and an aggregate cannot tell those apart from a cheap session. The
  # reconstructed terminal in common/ledger.sh carries the field as `-`, the
  # convention that file states for a numeric it cannot recover — #553's
  # parity guard is what makes that a rule rather than a habit.
  #
  # oom= follows peak_rss=. Zero is a measured zero delta, a positive number
  # records kernel kills during this dispatch, and `-` says neither kernel
  # counter was readable. sid= remains LAST, past oom, usage and pool suffixes.
  # The id on this line and the id on the SESSION START above are the same by
  # construction — `_session_identity` resolved it once, before the dispatch —
  # so the two records of one session point at one transcript (#538 D3).
  #
  # Through `$sid_suffix` rather than as literal text, for the reason that
  # helper states: it is what keeps #553's source-derived order guard reading
  # the wire order rather than an artifact of where the interpolations stop.
  # Unconditional, unlike the two suffixes ahead of it — a session with no id
  # emits `sid=unknown`, because D3 asks for the token on EVERY record and
  # `unknown` is the answer `_session_mint_sid` already gives.
  log "SESSION END kind=$kind key=$key rc=$rc dur=${dur}s outcome=$verdict acted=$acted reply_tail=$reply_tail log=$log_bytes left=$survivor_count tier=$_SESSION_TIER${peak_rss:+ peak_rss=$peak_rss} oom=$oom_delta$usage_suffix$why_suffix$pool_suffix$sid_suffix"
  # Written after the line that reports the session and before the counters
  # that bill it, reading the two figures that line just published: this stub
  # and that record can never disagree about what the session left behind.
  _session_resume_record "$kind" "$key" "$dir" "$rc" "$tmo" \
    "$log_bytes" "$survivor_count" "$verdict" "$acted" "$slog"
  _session_continue_record "$kind" "$key" "$rc" "$verdict"
  _session_terminal_record "$kind" "$terminal" "$acted" "$slog"
  # The rolling counter is written alongside the line that carries the same
  # duration, so the budget and the log can never disagree about what a
  # session cost. Every outcome counts: a TIMEOUT and a TERMINAL spent the
  # vendor's clock exactly as an ok did.
  _session_budget_record "$kind" "$dur"
  # Outcome exposed for callers that gate follow-up state on success (the seen-
  # ledger commits in duty-triage.sh) WITHOUT reintroducing the set -e abort a
  # failed session must never cause — return stays 0.
  RUN_SESSION_RC="$rc"
  RUN_SESSION_LOG="$slog"
  return 0
}

session_acted() {
  local rc
  declare -F bot_session_acted >/dev/null 2>&1 || { printf unknown; return; }
  bot_session_acted "$1" && rc=0 || rc=$?
  case "$rc" in
    0) printf yes ;;
    1) printf no ;;
    *) printf unknown ;;
  esac
}

session_reply_tail() {
  # SESSION END is space-delimited, so encode arbitrary reply prose as one
  # token; the fleet floor decodes it for display.
  awk 'NF { line=$0 } END { printf "%s", substr(line, 1, 200) }' "$1" 2>/dev/null \
    | base64 | tr -d '\n'
}

# --- peak RSS (#473) --------------------------------------------------------
#
# What SESSION END could not say: a triage session reached 3.42 GB on a ~4 GB
# zero-swap guest, the OOM killer took a process out of the tree and the box
# thrashed unreachable for twelve minutes — and the engine's record of that
# session carries `rc`, `dur` and `outcome`, not one number that grows.
#
# WHAT IS READ, and why it is not a sample of current usage. `VmHWM` in
# `/proc/<pid>/status` is the kernel's own high-water mark for a process: it
# only rises, and it survives the free that follows a spike. Measured on this
# kernel — a process that allocates 300 MiB and releases it reports
# `VmHWM: 315684 kB` beside `VmRSS: 11460 kB`. So every read here returns a
# peak the kernel recorded, never a footprint sampled at the moment of asking,
# and the only thing an interval between reads can lose is growth in a process
# that then dies before the next one.
#
# WHY IT IS READ WHILE THE TREE IS ALIVE, against D1's letter. There is no
# teardown read to make. A task's mm is torn down before it becomes a zombie:
# `/proc/<pid>/status` for an exited-but-unreaped child carries `State: Z` and
# no `Vm*` line at all, and after the wait the directory is gone (both
# measured). `VmHWM` is also per-process and never aggregates — a parent shell
# sat at 3300 kB while its own child peaked at 315928 kB — and bash execs the
# last command of the dispatch subshell, so that pid is `timeout`, whose child
# is the CLI. A figure taken at teardown would be missing or the wrong
# process's. The finding is on #473 and the reader is one function, so a
# ruling that prefers another mechanism replaces this and nothing else.
#
# WHAT THE FIGURE IS: the largest `VmHWM` in the session's process tree, not a
# sum. Summing RSS over a forked tree double-counts the pages a fork shares,
# and the per-process peak is what the OOM killer scores — the incident above
# is one process reaching 3.42 GB, not a tree averaging it.
#
# The interval, and the seam the tests drive. The reads themselves are
# builtins — no `cat`, no `grep`, no `ps` — but `_session_proc_hwm` and
# `_session_proc_children` are called in command substitutions, so the honest
# budget is TWO FORKS PER PROCESS IN THE TREE per SESSION_PEAK_POLL_S, plus
# the `sleep` and the outer substitution. For an agent CLI tree that is tens
# of forks an interval, not two. None of them exec, which is what keeps it
# cheap on a two-core box, and the interval is what keeps it bounded — but
# the number to budget against when editing this is the per-process one.
SESSION_PEAK_POLL_S="${SESSION_PEAK_POLL_S:-5}"

# _session_proc_hwm PID — one live process's VmHWM in KiB, or nothing. The
# read is wrapped because a process that exits mid-walk makes the redirection
# itself fail, and under `set -e` a bare failed redirection ends the tick.
_session_proc_hwm() {
  local field value
  {
    while read -r field value _; do
      if [ "$field" = "VmHWM:" ]; then
        printf '%s' "$value"
        break
      fi
    done <"/proc/$1/status"
  } 2>/dev/null || return 0
  return 0
}

# _session_proc_children PID — the kernel's own child list for PID, from
# `/proc/<pid>/task/<tid>/children`. A kernel built without CONFIG_PROC_
# CHILDREN has no such file, and the walk then sees a one-process tree rather
# than failing (D4).
_session_proc_children() {
  local f kids out=""
  for f in /proc/"$1"/task/*/children; do
    [ -r "$f" ] || continue
    kids=""
    # `read` reports failure on the file's missing trailing newline while
    # still having read the line, so its status is deliberately discarded.
    { read -r kids <"$f"; } 2>/dev/null || :
    [ -z "$kids" ] || out="$out $kids"
  done
  printf '%s' "$out"
}

# _session_tree_hwm PIDS — the largest VmHWM in the trees rooted at PIDS (a
# whitespace-separated list), in KiB. Nothing is printed where no process in
# the tree reported a figure, which is also what a tree that has just exited
# looks like.
#
# The depth bound is a runaway guard and not a policy: 32 generations below
# the dispatch subshell is far past anything an agent CLI builds, and a walk
# that cannot terminate is exactly what must not run every few seconds inside
# the engine.
_session_tree_hwm() {
  local pid kids hwm=0 v depth=0
  # shellcheck disable=SC2206  # a pid list, split on whitespace by design
  local -a pids=($1) next
  while [ "${#pids[@]}" -gt 0 ] && [ "$depth" -lt 32 ]; do
    next=()
    for pid in "${pids[@]}"; do
      v="$(_session_proc_hwm "$pid")"
      [ -n "$v" ] && [ "$v" -gt "$hwm" ] && hwm="$v"
      kids="$(_session_proc_children "$pid")"
      # shellcheck disable=SC2206  # a pid list, split on whitespace by design
      [ -z "$kids" ] || next+=($kids)
    done
    pids=("${next[@]}")
    depth=$((depth + 1))
  done
  [ "$hwm" -gt 0 ] || return 0
  printf '%s' "$hwm"
}

# _session_peak_rss_watch ROOT FILE — hold FILE at the largest VmHWM seen in
# the process tree rooted at ROOT, for as long as ROOT lives. ROOT is the
# dispatch's own subshell, so what is measured is the session and nothing the
# engine is doing beside it. FILE is written only when the figure rises, so a
# box that dies under the CLI leaves the last peak on disk rather than
# nothing.
#
# It sleeps BEFORE its first read, and that is what makes the field's absence
# mean one thing. Reading first would race the tree's own startup: the same
# session would carry a figure or not depending on which process the scheduler
# ran first, and a field that appears at random is worse than one that is
# reliably absent. Sleeping first states the rule instead — a session that
# does not outlive one interval is not measured — and the tests assert both
# sides of it.
_session_peak_rss_watch() {
  local root="$1" out="$2" hwm=0 v
  while kill -0 "$root" 2>/dev/null; do
    # `|| return 0` and not a bare `sleep`: an interval this cannot sleep on
    # ends the watcher instead of spinning the loop hot on /proc for as long
    # as the session runs. Under the engine's `set -e` a failed sleep would
    # end it anyway — the explicit exit is what makes that true everywhere,
    # rather than a property of the caller's shell options.
    sleep "$SESSION_PEAK_POLL_S" || return 0
    v="$(_session_tree_hwm "$root")"
    if [ -n "$v" ] && [ "$v" -gt "$hwm" ]; then
      hwm="$v"
      printf '%s\n' "$hwm" >"$out" 2>/dev/null || return 0
    fi
  done
}

# _session_peak_rss_start FILE ROOT — begin measuring, into _SESSION_PEAK_PID.
#
# The watcher is a SIBLING of the dispatch, never its parent, and it starts
# only once the dispatch is already running. That is D4 structurally rather
# than by promise: there is no order of events in which measuring a session
# refuses, delays or ends it, because by the time this runs the session is
# under way and nothing here is in its path.
_session_peak_rss_start() {
  _SESSION_PEAK_PID=""
  rm -f "$1" 2>/dev/null || true
  # No procfs, no measurement, and no complaint: SESSION END simply carries no
  # peak_rss= on that platform (D2, D4).
  [ -r "/proc/$2/status" ] || return 0
  # Silenced, deliberately: the watcher shares the engine's stdout and stderr,
  # and a duty log is evidence. Anything it could have to say — an interval an
  # operator mistyped, a /proc that vanished mid-walk — is a reason to record
  # no figure, never a line in the middle of a session's own record.
  _session_peak_rss_watch "$2" "$1" >/dev/null 2>&1 &
  _SESSION_PEAK_PID=$!
  return 0
}

# _session_peak_rss_stop — end the watcher, reaping it quietly.
_session_peak_rss_stop() {
  [ -n "${_SESSION_PEAK_PID:-}" ] || return 0
  { kill "$_SESSION_PEAK_PID" 2>/dev/null; wait "$_SESSION_PEAK_PID"; } >/dev/null 2>&1 || true
  _SESSION_PEAK_PID=""
  return 0
}

# session_peak_rss FILE — the recorded figure, in KiB, or nothing. Anything
# that is not a bare integer is nothing: an absent field says the engine did
# not measure this session, and a fabricated one would say it measured zero.
session_peak_rss() {
  local v=""
  { read -r v <"$1"; } 2>/dev/null || :
  case "$v" in
    '' | *[!0-9]*) return 0 ;;
  esac
  printf '%s' "$v"
}

# --- the memory ceiling (#474) ----------------------------------------------
#
# #473 made the growth VISIBLE; this bounds it. On 2026-08-14 one session
# reached 3.42 GB on a ~4 GB zero-swap guest and the engine bounded nothing but
# its clock: the kernel's global victim selection took a process out of the
# session's tree while its siblings kept allocating, so the box stayed down and
# the session did not stop. That is the worst of both outcomes, and the two
# halves below are the two halves of it.
#
# D1 — WHO THE KERNEL PICKS. `oom_score_adj` on the dispatch subshell, so that
# when the kernel does have to choose, it chooses the session over `cron`,
# `sshd` and the engine. Unconditional and unconfigured in the fleet conf: it
# has no number an operator needs to pick, and a fleet where it is off is a
# fleet where the 2026-08-14 outcome is still reachable.
#
# D2 — WHETHER THE KERNEL IS ASKED AT ALL. The (c) watchdog, ruled by triage at
# the past-24h rung on 2026-08-25 over `ulimit -v` (a) and a `systemd` transient
# scope (b): portable, degrading to a warning, and the only one of the three
# that can log WHY before it acts.
#
# WHAT IT READS, and the constraint that shapes everything below. The figure is
# `_session_tree_hwm`'s, produced by `_session_peak_rss_watch` and left on the
# `$slog.peak` scratch file — not a second reader of a different number. And
# the watchdog is a THIRD process rather than a branch inside that watcher,
# because #473's D4 is structural: *there is no order of events in which
# measuring a session refuses, delays or ends it*, and that guarantee is the
# SHAPE of `_session_peak_rss_watch`, not a promise beside it. This issue's
# actor must do the one thing that one must never do, so it cannot be that one.
#
# Reading the file rather than `/proc` a second time is also what keeps the
# cost at zero: the honest budget of the walk is two forks per process in the
# tree per interval (see above), and a second walk would double it on a
# two-core box. The watchdog's own budget is one `read` of a one-line file.
#
# WHY IT CANNOT FIRE EARLY OFF A TORN READ. `_session_peak_rss_watch` writes
# with `>`, which truncates before it writes, so a reader landing mid-write
# sees a PREFIX of the new figure and never a splice of two. A prefix of a
# decimal integer is smaller than the integer, so a torn read can only fail to
# fire this interval and fire on the next — the safe direction, and the reason
# `session_peak_rss`'s "anything but digits is nothing" is enough validation
# for a killing decision.

# The outcome token for a session the ceiling ended (D4). It lives in one place
# for the reason `SESSION_ORPHAN_OUTCOME` does in common/ledger.sh: it is the
# only thing distinguishing this shape from an ordinary FAILED, so the writer
# and every reader have to be looking at the same string. A bare non-zero `rc`
# is exactly what D4 forbids — `timeout` reports 143 for being signalled, which
# reads as the CLI's own verdict.
SESSION_MEM_OUTCOME=MEMORY

# The increment added to the engine's own `oom_score_adj`, and the grace
# between TERM and KILL. Both are in-module defaults, env-overridable, and
# deliberately NOT `fleet.defaults.conf` keys — that file's key is D3's
# ceiling and is this issue's alone, the same fence #473 put around
# SESSION_PEAK_POLL_S.
#
# 500 rather than 1000: the kernel's badness is `oom_score_adj` plus a
# thousandth-of-total-memory share, so +500 picks the session over any process
# not using fifty percentage points more of the box than it — decisive for the
# runaway this exists to catch — while leaving an operator room above it.
SESSION_OOM_SCORE_ADJ="${SESSION_OOM_SCORE_ADJ:-500}"
SESSION_MEM_KILL_GRACE_S="${SESSION_MEM_KILL_GRACE_S:-5}"

# _session_oom_arm — raise THIS process's oom_score_adj. Called inside the
# dispatch subshell, before the CLI is `exec`'d: the attribute survives both
# fork and exec, so arming the subshell arms `timeout`, the CLI, and every
# descendant, with no per-process bookkeeping.
#
# It returns 0 on every path, and that is a contract rather than tidiness: it
# sits in the dispatch's own `&&` chain, so a non-zero return here would refuse
# a session on a guest whose procfs is read-only.
_session_oom_arm() {
  local cur=0 inc base want
  inc="${SESSION_OOM_SCORE_ADJ:-500}"
  case "$inc" in '' | *[!0-9]*) inc=500 ;; esac
  { read -r cur </proc/self/oom_score_adj; } 2>/dev/null || cur=0
  # Anything the kernel would not have written is read as the default, which is
  # also what a guest with no procfs produces: no reading, no adjustment, and
  # no complaint.
  { [ -n "$cur" ] && [ "$cur" -eq "$cur" ]; } 2>/dev/null || cur=0
  # The floor is the KERNEL default and not the engine's own value. An engine
  # deliberately protected at a negative adjustment must not drag the session
  # down with it: the property owed is that the session outranks `cron` and
  # `sshd` as well, and those run at 0.
  base="$cur"
  [ "$base" -gt 0 ] || base=0
  want=$((base + inc))
  [ "$want" -le 1000 ] || want=1000
  # Raising is unprivileged; LOWERING needs CAP_SYS_RESOURCE. So a want at or
  # below the current value is never attempted — it could only fail, and a
  # failure here has nothing useful to say.
  [ "$want" -gt "$cur" ] || return 0
  printf '%s\n' "$want" >/proc/self/oom_score_adj 2>/dev/null || :
  return 0
}

# _session_mem_total_kib — this box's MemTotal in KiB, or nothing. KiB because
# that is `VmHWM`'s unit, so the ceiling and the figure it bounds are never
# converted and can never disagree about a factor of 1024.
_session_mem_total_kib() {
  local field value
  {
    while read -r field value _; do
      if [ "$field" = "MemTotal:" ]; then
        case "$value" in '' | *[!0-9]*) break ;; esac
        printf '%s' "$value"
        break
      fi
    done </proc/meminfo
  } 2>/dev/null || return 0
  return 0
}

# _session_mem_pct — the configured ceiling as a percentage of MemTotal, or
# nothing when no ceiling is armed (D3).
#
# A percentage and not a number of KiB, per the ruling's own reason: a fleet of
# boxes with different memory sizes needs a RELATIVE bound, and the same conf
# ships to a 4 GiB triage box and a 16 GiB builder.
#
# THE PER-ROLE OVERRIDE WINS OVER THE FLEET VALUE, and where a box carries more
# than one role — `BOT_ROLES` is a list — the MOST RESTRICTIVE armed override
# wins. The box is one box and its memory is one resource, so the tighter bound
# is the one that protects it. 0 and unset both mean "this role names no
# ceiling" rather than "this role forbids one", which is the same reading `0 is
# OFF` already has for every BUDGET_* value: a role opting out cannot disarm
# the bound a sibling role asked for.
_session_mem_pct() {
  local role suffix var value best=""
  # shellcheck disable=SC2086  # BOT_ROLES is a space-separated list by design
  for role in ${BOT_ROLES:-}; do
    suffix="${role//[^[:alnum:]]/_}"
    suffix="${suffix^^}"
    var="SESSION_MEM_MAX_PCT_${suffix}"
    value="${!var:-}"
    case "$value" in '' | *[!0-9]*) continue ;; esac
    [ "$value" -gt 0 ] || continue
    if [ -z "$best" ] || [ "$value" -lt "$best" ]; then best="$value"; fi
  done
  if [ -z "$best" ]; then
    best="${SESSION_MEM_MAX_PCT:-0}"
    case "$best" in '' | *[!0-9]*) best=0 ;; esac
  fi
  [ "$best" -gt 0 ] || return 0
  printf '%s' "$best"
}

# _session_mem_ceiling_kib — the armed ceiling in KiB, or nothing. Nothing is
# the shipped state and the whole of "with no ceiling configured, behaviour is
# exactly today's": the caller then starts no watchdog, writes no file and logs
# no line.
_session_mem_ceiling_kib() {
  local pct total ceil
  pct="$(_session_mem_pct)"
  [ -n "$pct" ] || return 0
  total="$(_session_mem_total_kib)"
  [ -n "$total" ] || return 0
  ceil=$((total * pct / 100))
  [ "$ceil" -gt 0 ] || return 0
  printf '%s' "$ceil"
}

# _session_tree_pids ROOT — every LIVE pid in the tree rooted at ROOT, the same
# bounded walk `_session_tree_hwm` makes and for the same reason: 32
# generations is far past anything an agent CLI builds, and a walk that cannot
# terminate must not run inside the engine.
#
# The two guards are the test plan's *"must fail: a ceiling that terminates the
# engine's own process rather than the session tree"*, written into the code
# rather than left to the walk's shape. The walk descends from ROOT and the
# engine is ROOT's PARENT, so it is already unreachable — but `$$` is the
# engine's pid even inside a subshell, so saying it costs one comparison and
# makes the mutation that would break it visible.
_session_tree_pids() {
  local pid kids depth=0 out=""
  # shellcheck disable=SC2206  # a pid list, split on whitespace by design
  local -a pids=($1) next
  while [ "${#pids[@]}" -gt 0 ] && [ "$depth" -lt 32 ]; do
    next=()
    for pid in "${pids[@]}"; do
      case "$pid" in '' | *[!0-9]*) continue ;; esac
      [ "$pid" -gt 1 ] || continue
      [ "$pid" != "$$" ] || continue
      # `kill -0` and not a `/proc` test: it is a builtin, so the liveness
      # check costs no fork, and it answers the question the caller is about
      # to ask anyway. A dead root must come back EMPTY rather than as a pid
      # the terminator would then signal into the void — a pid number is
      # reused, and a list that keeps dead entries is a list that could name
      # somebody else's process by the time it is used.
      kill -0 "$pid" 2>/dev/null || continue
      out="$out $pid"
      kids="$(_session_proc_children "$pid")"
      # shellcheck disable=SC2206  # a pid list, split on whitespace by design
      [ -z "$kids" ] || next+=($kids)
    done
    pids=("${next[@]}")
    depth=$((depth + 1))
  done
  printf '%s' "$out"
}

# _session_proc_pgid PID — PID's process group, or nothing.
#
# Parsed past the LAST `)` rather than by field number from the start, because
# field 2 of `/proc/<pid>/stat` is `comm` in parentheses and `comm` may contain
# both spaces and parentheses — a CLI named `agent (v2)` would shift every
# field after it. Everything from the last `) ` on is fixed-width by position:
# state, ppid, pgrp.
_session_proc_pgid() {
  local stat rest pgrp
  { read -r stat </proc/"$1"/stat; } 2>/dev/null || return 0
  rest="${stat##*') '}"
  # No `) ` at all is a line this function does not understand. Saying nothing
  # is the only safe answer: every caller below treats "no group" as "do not
  # signal a group", and a guessed group is a signal sent somewhere unknown.
  [ "$rest" != "$stat" ] || return 0
  read -r _ _ pgrp _ <<<"$rest"
  case "$pgrp" in '' | *[!0-9]*) return 0 ;; esac
  printf '%s' "$pgrp"
}

# _session_mem_groups PIDS… — the distinct process groups those pids sit in,
# with the engine's own removed. The list is the containment identity the
# terminator signals, and it exists because the pid walk alone cannot hold one:
# a descendant that handles TERM by forking a replacement and exiting leaves
# that replacement reparented to PID 1, where no walk rooted at the session can
# reach it. It is still in the session's GROUP — `timeout` calls `setpgid(0,0)`
# absent `--foreground`, so the session has had a group of its own all along
# (the dispatch comment says so and the D5 block asserts it), and a reparented
# child that never called `setsid()` never leaves it.
#
# THE ENGINE'S OWN GROUP IS REFUSED BY NAME. This is `_session_tree_pids`'s
# `[ "$pid" != "$$" ]` guard one level up, and it is the more important of the
# two: a group kill aimed at the wrong group takes the engine, this watchdog
# and every sibling session with it. `$$` is the engine even inside a subshell,
# and this watchdog is a background subshell of the engine with job control
# off, so it shares that group — one refusal covers both.
#
# A box that cannot say what the engine's group is gets NO group kill at all.
# Not knowing which group to spare is exactly the state in which signalling one
# is unsafe, so the terminator falls back to the pid walk, which is what it had
# before this and is still correct for everything reachable from ROOT.
#
# The groups are collected from the WHOLE snapshot rather than from ROOT alone.
# ROOT is the dispatch subshell, and whether its own pgid is `timeout`'s new
# group or still the engine's depends on whether bash exec'd the subshell's
# last command — an optimisation, not a guarantee (bash 5.2.37 here does take
# it, so ROOT *is* `timeout` and the two agree). Reading the group off every
# pid already walked costs one `/proc` read each, no fork, and is correct under
# either shape. It cannot reach outside the session either: a group is only
# named here if a member of the session's own tree is sitting in it.
_session_mem_groups() {
  local pid grp self out=""
  self="$(_session_proc_pgid "$$")"
  [ -n "$self" ] || return 0
  for pid in "$@"; do
    grp="$(_session_proc_pgid "$pid")"
    case "$grp" in '' | *[!0-9]*) continue ;; esac
    [ "$grp" -gt 1 ] || continue
    [ "$grp" != "$self" ] || continue
    case " $out " in *" $grp "*) continue ;; esac
    out="$out $grp"
  done
  printf '%s' "$out"
}

# _session_mem_kill_grace_s — the TERM→KILL grace, validated. Validated for the
# reason every other numeric in this module is (`_session_oom_arm`'s `inc`,
# `_session_mem_pct`, `session_peak_rss`): the value is env-overridable, and a
# non-numeric one makes `sleep` fail instantly, collapsing the grace to zero
# and landing TERM and KILL back to back — which defeats the one reason TERM
# goes first, letting the CLI flush the transcript this outcome is read against.
_session_mem_kill_grace_s() {
  local v="${SESSION_MEM_KILL_GRACE_S:-5}"
  case "$v" in '' | *[!0-9]*) v=5 ;; esac
  printf '%s' "$v"
}

# _session_mem_terminate ROOT — end the session's tree, TERM then KILL, over
# both the pid walk and the session's own process group.
#
# TERM first because a CLI that is given the chance flushes its own transcript,
# and the session log is the evidence this outcome will be read against. The
# tree is re-walked after the grace rather than reusing the first list alone:
# a process that forked during the grace is new, and one that exited is a kill
# that silently no-ops, so the union is both cheap and complete for anything
# still reachable from ROOT.
#
# BOTH PASSES, and they are not redundant. The walk reaches a process that left
# the group (`setsid()` beats a group kill); the group reaches a process that
# left the tree (a TERM handler that forks and exits beats a walk, because the
# replacement is reparented to PID 1). Neither covers the other, and the
# session-ends-while-a-descendant-keeps-allocating shape this issue exists to
# close is the second one.
#
# THE GROUPS ARE READ BEFORE THE TERM, off the first snapshot, and that
# ordering is load-bearing rather than incidental: the group of a process can
# only be read from a process that still exists, and after the TERM the
# processes that knew it are the ones that have gone.
#
# THE GROUP KILL IS LAST. `KILL` cannot be handled, so nothing can fork a
# replacement out of it — the escape this function is closing is a TERM handler
# forking during the grace, and the final group pass is what makes that
# replacement's death certain rather than likely.
_session_mem_terminate() {
  local root="$1" pid grp
  local -a first=() second=() groups=()
  # A here-string and `read -a` rather than an unquoted substitution: the same
  # split, without the SC2207 the per-file shellcheck loop reds on.
  read -r -a first <<<"$(_session_tree_pids "$root")"
  [ "${#first[@]}" -gt 0 ] || return 0
  read -r -a groups <<<"$(_session_mem_groups "${first[@]}")"
  for pid in "${first[@]}"; do kill -TERM "$pid" 2>/dev/null || :; done
  for grp in ${groups[@]+"${groups[@]}"}; do
    kill -TERM -- -"$grp" 2>/dev/null || :
  done
  sleep "$(_session_mem_kill_grace_s)" 2>/dev/null || :
  read -r -a second <<<"$(_session_tree_pids "$root")"
  for pid in "${first[@]}" ${second[@]+"${second[@]}"}; do
    kill -KILL "$pid" 2>/dev/null || :
  done
  for grp in ${groups[@]+"${groups[@]}"}; do
    kill -KILL -- -"$grp" 2>/dev/null || :
  done
  return 0
}

# _session_mem_watch PEAK MARK ROOT KIND CEILING — the watchdog loop. Polls the
# figure #473's watcher is already producing and, past CEILING, records why and
# ends the tree.
#
# The MARK is written BEFORE the kill, and the order is what makes the outcome
# survive: `run_session` classifies this session by that file, and a box that
# dies between the two would otherwise report a session the engine killed as an
# ordinary CLI failure.
#
# The interval is SESSION_PEAK_POLL_S and not a second knob. The watchdog
# cannot see a figure sooner than the watcher publishes it, so an independent
# interval would be a setting with no effect below that one and no meaning
# above it.
_session_mem_watch() {
  local peak="$1" mark="$2" root="$3" kind="$4" ceil="$5" v
  while kill -0 "$root" 2>/dev/null; do
    sleep "$SESSION_PEAK_POLL_S" || return 0
    v="$(session_peak_rss "$peak")"
    [ -n "$v" ] || continue
    [ "$v" -gt "$ceil" ] || continue
    printf '%s\n' "$v" >"$mark" 2>/dev/null || return 0
    # Logged BEFORE it acts, which is the property (c) was chosen for: an
    # operator reading duty.log afterwards sees the figure, the ceiling and the
    # decision, not just a session that stopped. This watcher's stdout is the
    # duty log on purpose — unlike the peak watcher's, which is silenced
    # because it has nothing to say that is not a reason to record no figure.
    warn "session memory: kind=$kind reached $v KiB against a ceiling of $ceil KiB — terminating the session tree"
    _session_mem_terminate "$root"
    # After the kill, deliberately: `alert` is a curl with a ten-second
    # deadline, and a runaway that is already past the ceiling must not be
    # given ten more seconds of the box to allocate in.
    alert "🚨 $(hostname): $kind session terminated at $v KiB, past its ${ceil} KiB memory ceiling"
    return 0
  done
}

# _session_mem_watch_start PEAK MARK ROOT KIND — arm the ceiling, into
# _SESSION_MEM_PID. A no-op when nothing is configured, and that is the whole
# of "this must not become a mandatory setting": no watchdog, no file, no line.
_session_mem_watch_start() {
  local ceil pct total reason=""
  _SESSION_MEM_PID=""
  rm -f "$2" 2>/dev/null || true
  # NOTHING CONFIGURED IS SILENT, and it is tested as an acceptance criterion:
  # no watchdog, no file, no line. The percentage is read first, and separately
  # from the ceiling, precisely so that this silence cannot swallow the case
  # below — an operator who armed a ceiling and did not get one has to be told,
  # and reading only the resolved ceiling makes "armed but unresolvable"
  # indistinguishable from "not armed".
  pct="$(_session_mem_pct)"
  [ -n "$pct" ] || return 0
  total="$(_session_mem_total_kib)"
  ceil="$(_session_mem_ceiling_kib)"
  # Armed but no bound applied, in the three shapes that produce it. This is
  # (c)'s documented degradation: the ceiling is a percentage of a box read
  # from procfs, of a figure another watcher publishes, so where either is
  # missing there is no bound — and the operator is told rather than left with
  # a setting that silently does nothing. One message, and the reason names
  # which of the three it was, because the operator's next move differs.
  if [ -z "$total" ]; then
    reason="this box's MemTotal is unreadable"
  elif [ -z "$ceil" ]; then
    reason="${pct}% of ${total} KiB rounds to nothing"
  elif [ -z "${_SESSION_PEAK_PID:-}" ]; then
    reason="this session is not measurable"
  fi
  if [ -n "$reason" ]; then
    warn "session memory: kind=$4 a ceiling of ${pct}% is configured but $reason — no memory bound applied"
    return 0
  fi
  _session_mem_watch "$1" "$2" "$3" "$4" "$ceil" &
  _SESSION_MEM_PID=$!
  return 0
}

# _session_mem_watch_stop MARK — end the watchdog.
#
# A watchdog that has FIRED is waited for instead of signalled, and the
# distinction is load-bearing. Its second half — the KILL after the grace — is
# what reaps a process deeper in the tree than the root `wait` can see, so
# killing it there would leave that survivor running for the life of the box:
# the precise failure 2026-08-14 was, one level down. MARK is how the parent
# can tell: the watchdog writes it before it signals anything, so a root that
# has already exited with the file present has been killed by this ceiling.
_session_mem_watch_stop() {
  local pid="${_SESSION_MEM_PID:-}"
  _SESSION_MEM_PID=""
  [ -n "$pid" ] || return 0
  if [ -e "$1" ]; then
    wait "$pid" >/dev/null 2>&1 || true
  else
    { kill "$pid" 2>/dev/null; wait "$pid"; } >/dev/null 2>&1 || true
  fi
  return 0
}

# session_mem_hit FILE — the figure that crossed the ceiling, or nothing.
# Validated like session_peak_rss and for the same reason: this file decides an
# outcome, and anything the watchdog did not write is not one.
session_mem_hit() {
  local v=""
  { read -r v <"$1"; } 2>/dev/null || :
  case "$v" in
    '' | *[!0-9]*) return 0 ;;
  esac
  printf '%s' "$v"
}

# idle_ticks_account — the host's stop-on-idle reads $DUTY_DIR/.idle-ticks: the
# number of consecutive ticks that bought no session, reset by the first tick
# that does (run_session stamps .tick-acted above). duty.sh calls it on every
# exit path, right after its `duty run end` line (#759). It lives here and
# not in duty.sh because the first-tick fixture runs duty.sh's identity block
# with only this library sourced, and the accounting is on that block's
# exit paths too.
idle_ticks_account() {
  local n
  if [ -e "$DUTY_DIR/.tick-acted" ]; then
    printf '0\n' >"$DUTY_DIR/.idle-ticks"
  else
    n="$(cat "$DUTY_DIR/.idle-ticks" 2>/dev/null || echo 0)"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s\n' "$((n + 1))" >"$DUTY_DIR/.idle-ticks"
  fi
}
