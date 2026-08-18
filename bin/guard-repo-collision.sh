#!/usr/bin/env bash
#
# guard-repo-collision.sh
#
# PreToolUse(Bash) hook. Warns, once per session per repository, when ANOTHER
# Claude Code session is working against the same git checkout and this session
# is about to run a git command that writes.
#
# WHY THIS EXISTS
#
# guard-git-push.sh blocks the one command whose damage is unrecoverable-ish
# (a push of the wrong branch). It cannot tell you the underlying fact: that
# somebody else is in here with you. Twice in one day a peer session switched
# the shared checkout between two of this session's tool calls, and the second
# time it happened AFTER this session had already started, so a start-up check
# alone would have missed it.
#
# Claude Code does not detect this. Verified against the docs 2026-08-14: only
# BACKGROUND sessions get an automatic worktree; interactive ones need an
# explicit --worktree, and nothing warns when two of them share a directory.
#
# HOW PEERS ARE DETECTED (two channels, both required)
#
# 1. Process cwd: any other claude process whose /proc/<pid>/cwd resolves to
#    this repo. Catches a session launched inside the checkout.
# 2. Markers: every time this hook sees a git-write command it records
#    "<claude-pid> works in <repo>" in a shared state dir; a marker whose pid
#    is still a live claude process is a peer, regardless of where that
#    process's cwd points.
#
# Channel 2 exists because channel 1 alone was structurally blind, verified
# 2026-08-18: sessions here launch from $HOME and cd inside Bash commands, so
# every claude process's cwd was /home/<user>, every peer failed the repo
# resolve, and the guard could never fire. Six live sessions working in
# ~/Projects/* repos, all invisible. Walking each peer's child shells was
# considered and rejected: the Bash tool's shells exist only while a command
# runs, so that channel is blind whenever a peer is between commands, which is
# most of the time. Markers persist for the session's lifetime and are pruned
# when the pid dies.
#
# The SELF side had the same hole: the payload cwd of a home-launched session
# is $HOME, not the repo. The repo is now resolved from, in order, the payload
# cwd, a `git -C <path>`, and the first `cd <path>` in the command.
#
# SCOPE: same CHECKOUT only, deliberately. Two clones (or two worktrees) of
# the same remote are not detected. Git's own non-fast-forward rejection
# already arbitrates cross-clone pushes, and warning on a shared remote would
# fire on every pair of worktrees, which is exactly the isolation this
# guard's own message recommends.
#
# WHAT IT DOES NOT DO
#
# It does not block. The push guard already refuses the genuinely dangerous
# form, and blocking every git command whenever a colleague is in the same repo
# would be unusable. This one supplies the missing FACT, at the moment it
# matters, and tells the model what to do about it: name branches explicitly,
# re-read the branch in the same command that uses it, and consider SendMessage
# to coordinate with the peer directly.
#
# It cannot call SendMessage itself. Hooks are shell commands; SendMessage is a
# tool available to the model. The hook's job is to tell the model to use it.
#
# KNOWN LIMITS (advisory guard, stated rather than hidden):
# - A marker outlives the peer's interest: a session that committed here this
#   morning and moved on still counts until it exits. One warning per session
#   is the cost, and a live session can always come back.
# - Pid reuse within a boot could mis-attribute a marker to a new claude
#   process. Vanishingly rare, and the failure is a spurious advisory line.
# - A session whose own claude pid cannot be resolved writes no marker (peers
#   cannot see it) and shares the "unknown" warn-once key with any other such
#   session. It still SEES peers on both channels.
# - CLAUDE_GUARD_STATE_DIR overrides the state dir; it exists for the test
#   harness.
#
# FAIL OPEN, LOUDLY, same as the push guard: a machine that cannot run this
# check still has to be usable, so it allows the call and says on stderr that
# the check did not run. Silence is the one outcome it must never produce.

set -u

emit_allow_with_warning() {
  printf '{"systemMessage":"guard-repo-collision: NOT ENFORCED (%s).","hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n' "$1"
  echo "guard-repo-collision: NOT ENFORCED: $1" >&2
  exit 0
}

command -v jq >/dev/null 2>&1 || emit_allow_with_warning "jq is not installed"

PAYLOAD="$(cat)" || emit_allow_with_warning "could not read hook payload"
[ -n "${PAYLOAD}" ] || emit_allow_with_warning "empty hook payload"

CMD="$(printf '%s' "${PAYLOAD}" | jq -r '.tool_input.command // empty' 2>/dev/null)" \
  || emit_allow_with_warning "hook payload was not valid JSON"
[ -n "${CMD}" ] || exit 0

# Only the git verbs that WRITE. A `git status` or `git log` in a shared repo is
# harmless, and warning on it would train you to ignore the warning.
printf '%s' "${CMD}" \
  | grep -qE '(^|[;&|]|\s)git(\s+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*\s+(commit|merge|rebase|push|pull|checkout|switch|reset|cherry-pick|revert|am|stash)(\s|$)' \
  || exit 0

# Everything below is best-effort inspection of /proc. Anything unreadable means
# the answer is "cannot tell", which is not the same as "no peers" -- but this is
# an advisory, so it stays quiet rather than crying wolf. The push guard is the
# thing that actually blocks.
CWD="$(printf '%s' "${PAYLOAD}" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "${CWD}" ] || CWD="$(pwd)"

# Resolve the repository this git command actually targets. Paths named in
# the command itself win over the payload cwd: `git -C <path>` names the
# target explicitly, `cd <path>` is where the git will actually run, and the
# payload cwd of a home-launched session is $HOME anyway. A session sitting
# in repoA running `git -C repoB push` is working in repoB, and resolving it
# to repoA would mark and warn about the wrong repo. Best-effort: quoted
# paths with spaces are beyond a hook's pay grade, and an unresolvable
# candidate falls through to the next one rather than producing a wrong
# answer.
resolve_repo_at() { # $1 = path candidate, may be relative to CWD or ~-prefixed
  local p="$1"
  p="${p%\"}"; p="${p#\"}"; p="${p%\'}"; p="${p#\'}"
  if [ "${p}" = "~" ]; then
    p="${HOME}"
  elif [ "${p#"~/"}" != "${p}" ]; then
    p="${HOME}/${p#"~/"}"
  fi
  # If CWD is unusable, only an absolute candidate may resolve: a relative one
  # would silently resolve against whatever directory this hook happens to run
  # in, which is a wrong answer, not a missing one.
  ( if ! cd "${CWD}" 2>/dev/null; then
      case "${p}" in /*) cd / || exit 1 ;; *) exit 1 ;; esac
    fi
    git -C "${p}" rev-parse --show-toplevel 2>/dev/null )
}

REPO=""
CAND="$(printf '%s' "${CMD}" \
  | grep -oE 'git[[:space:]]+-C[[:space:]]+[^[:space:];&|]+' | head -n1 \
  | sed -E 's/^git[[:space:]]+-C[[:space:]]+//')"
[ -n "${CAND}" ] && REPO="$(resolve_repo_at "${CAND}")"
if [ -z "${REPO}" ]; then
  CAND="$(printf '%s' "${CMD}" \
    | grep -oE '(^|[;&|])[[:space:]]*cd[[:space:]]+[^[:space:];&|]+' | head -n1 \
    | sed -E 's/^[;&|]?[[:space:]]*cd[[:space:]]+//')"
  [ -n "${CAND}" ] && REPO="$(resolve_repo_at "${CAND}")"
fi
[ -n "${REPO}" ] || REPO="$(git -C "${CWD}" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "${REPO}" ] || exit 0

# Which claude process are WE? Walk the parent chain rather than assuming depth.
own_claude_pid() {
  local pid=$PPID depth=0
  while [ "${pid}" -gt 1 ] && [ "${depth}" -lt 12 ]; do
    local comm ppid
    comm="$(cat "/proc/${pid}/comm" 2>/dev/null)" || return 1
    if [ "${comm}" = "claude" ]; then printf '%s' "${pid}"; return 0; fi
    ppid="$(awk '{print $4}' "/proc/${pid}/stat" 2>/dev/null)" || return 1
    [ -n "${ppid}" ] || return 1
    pid="${ppid}"; depth=$((depth + 1))
  done
  return 1
}
SELF="$(own_claude_pid || true)"

# Shared state dir. Fixed path, NOT $TMPDIR, because sandboxed sessions get
# per-session TMPDIRs and the whole point is that every session sees the same
# markers. Per-boot /tmp means a reboot clears it, which is exactly the
# lifetime pid-keyed markers want.
#
# A state-dir failure degrades, it does not abort: channel 1 needs no state at
# all, and throwing away a working detection channel because an unrelated
# persistence mechanism failed is rule 4's shape. Without state there is no
# warn-once throttle either, so a detected peer warns on every write, which is
# the old fallback behaviour and louder, not quieter.
STATE_DIR="${CLAUDE_GUARD_STATE_DIR:-/tmp/claude-repo-collision.$(id -u)}"
STATE_OK=1
if [ -L "${STATE_DIR}" ]; then
  # /tmp is world-writable: a symlink planted here would redirect our writes
  # into a directory we DO own somewhere else, and pass the -O check below.
  echo "guard-repo-collision: state dir ${STATE_DIR} is a symlink; marker channel off" >&2
  STATE_OK=0
elif ! mkdir -p "${STATE_DIR}/markers" "${STATE_DIR}/warned" 2>/dev/null; then
  echo "guard-repo-collision: cannot create state dir ${STATE_DIR}; marker channel off" >&2
  STATE_OK=0
elif ! [ -O "${STATE_DIR}" ]; then
  # Somebody else squatted the path: their markers could fake or suppress
  # warnings, so nothing in there is trusted.
  echo "guard-repo-collision: state dir ${STATE_DIR} is not owned by this user; marker channel off" >&2
  STATE_OK=0
else
  chmod 700 "${STATE_DIR}" 2>/dev/null || true
fi

REPO_KEY="$(printf '%s' "${REPO}" | tr '/' '_')"

# Record that WE work in this repo, every time, so peers can see us even when
# our process cwd is $HOME. Filename is an index; the content is the truth
# (two repo paths can collide once slashes become underscores).
if [ "${STATE_OK}" = 1 ] && [ -n "${SELF}" ]; then
  printf '%s\n' "${REPO}" > "${STATE_DIR}/markers/${REPO_KEY}.${SELF}" 2>/dev/null || true
fi

PEER_PIDS=""

# Channel 1: another claude process sitting IN the checkout.
for p in $(pgrep -x claude 2>/dev/null); do
  [ "${p}" = "${SELF:-}" ] && continue
  pcwd="$(readlink -f "/proc/${p}/cwd" 2>/dev/null)" || continue
  prepo="$(git -C "${pcwd}" rev-parse --show-toplevel 2>/dev/null)" || continue
  [ "${prepo}" = "${REPO}" ] || continue
  PEER_PIDS="${PEER_PIDS} ${p}"
done

# Channel 2: another live session that has run git writes here, wherever its
# process cwd points. Markers for dead or non-claude pids are pruned in
# passing, so the dir self-cleans. Runs even when SELF is unknown: a session
# that could not identify itself wrote no marker, so there is nothing of its
# own to mistake for a peer.
if [ "${STATE_OK}" = 1 ]; then
  for m in "${STATE_DIR}/markers/${REPO_KEY}."*; do
    [ -e "${m}" ] || continue
    mpid="${m##*.}"
    if [ -n "${SELF}" ] && [ "${mpid}" = "${SELF}" ]; then continue; fi
    case "${mpid}" in ''|*[!0-9]*) rm -f "${m}" 2>/dev/null; continue ;; esac
    [ "$(head -n1 "${m}" 2>/dev/null)" = "${REPO}" ] || continue
    if [ "$(cat "/proc/${mpid}/comm" 2>/dev/null)" = "claude" ]; then
      PEER_PIDS="${PEER_PIDS} ${mpid}"
    else
      rm -f "${m}" 2>/dev/null || true
    fi
  done
fi

PEERS="$(printf '%s\n' ${PEER_PIDS} | grep . | sort -un | sed 's/^/pid /' | paste -sd ',' - | sed 's/,/, /g')"
[ -n "${PEERS}" ] || exit 0

# Warn ONCE per session per repository. A warning on every git command is a
# warning you stop reading, which is the failure mode this whole toolkit exists
# to avoid. Keyed on our own claude pid so a new session warns again, and the
# mark carries the repo path because two paths can collide as a key. With no
# usable state dir there is no throttle, and warning every time beats not
# warning at all.
if [ "${STATE_OK}" = 1 ]; then
  MARK="${STATE_DIR}/warned/${SELF:-unknown}.${REPO_KEY}"
  if [ -e "${MARK}" ] && [ "$(head -n1 "${MARK}" 2>/dev/null)" = "${REPO}" ]; then
    exit 0
  fi
  printf '%s\n' "${REPO}" > "${MARK}" 2>/dev/null || true
fi

# branch --show-current, not rev-parse --abbrev-ref: the latter prints "HEAD"
# AND fails on an unborn branch, mangling the message into "HEAD\n?".
BRANCH="$(git -C "${REPO}" branch --show-current 2>/dev/null)"
[ -n "${BRANCH}" ] || BRANCH="?"

jq -nc --arg peers "${PEERS}" --arg repo "${REPO}" --arg branch "${BRANCH}" '{
  systemMessage: (
    "guard-repo-collision: another Claude Code session is working in this same checkout.\n\n" +
    "  repo:   " + $repo + "\n" +
    "  branch: " + $branch + " (right now, and it can change under you)\n" +
    "  peers:  " + $peers + "\n\n" +
    "The branch can change between two of your tool calls. Do not read it once and rely on it later.\n" +
    "  - Name branches explicitly: `git push origin <branch>`, never HEAD or a bare push.\n" +
    "  - Re-read the branch in the SAME command that uses it.\n" +
    "  - Check `git branch --show-current` in the same breath as any commit or merge.\n" +
    "  - Consider ListAgents and SendMessage to tell the peer what you are about to do.\n" +
    "  - If you are about to do sustained work, relaunching under --worktree avoids this entirely.\n\n" +
    "Shown once per session per repository."
  ),
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow"
  }
}'
exit 0
