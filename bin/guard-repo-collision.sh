#!/usr/bin/env bash
#
# guard-repo-collision.sh
#
# PreToolUse(Bash) hook. Warns, once per session per repository, when ANOTHER
# Claude Code session is running against the same git checkout and this session
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
  | grep -qE '(^|[;&|]|\s)git(\s+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*\s+(commit|merge|rebase|push|checkout|switch|reset|cherry-pick|stash)(\s|$)' \
  || exit 0

# Everything below is best-effort inspection of /proc. Anything unreadable means
# the answer is "cannot tell", which is not the same as "no peers" -- but this is
# an advisory, so it stays quiet rather than crying wolf. The push guard is the
# thing that actually blocks.
CWD="$(printf '%s' "${PAYLOAD}" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "${CWD}" ] || CWD="$(pwd)"
REPO="$(git -C "${CWD}" rev-parse --show-toplevel 2>/dev/null)" || exit 0
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

PEERS=""
for p in $(pgrep -x claude 2>/dev/null); do
  [ "${p}" = "${SELF}" ] && continue
  pcwd="$(readlink -f "/proc/${p}/cwd" 2>/dev/null)" || continue
  prepo="$(git -C "${pcwd}" rev-parse --show-toplevel 2>/dev/null)" || continue
  [ "${prepo}" = "${REPO}" ] || continue
  PEERS="${PEERS}${PEERS:+, }pid ${p}"
done
[ -n "${PEERS}" ] || exit 0

# Warn ONCE per session per repository. A warning on every git command is a
# warning you stop reading, which is the failure mode this whole toolkit exists
# to avoid. Keyed on our own claude pid so a new session warns again.
MARK_DIR="${TMPDIR:-/tmp}/claude-repo-collision"
mkdir -p "${MARK_DIR}" 2>/dev/null || true
MARK="${MARK_DIR}/$(printf '%s-%s' "${SELF:-unknown}" "$(printf '%s' "${REPO}" | tr '/' '_')")"
[ -e "${MARK}" ] && exit 0
: > "${MARK}" 2>/dev/null || true

BRANCH="$(git -C "${REPO}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")"

jq -nc --arg peers "${PEERS}" --arg repo "${REPO}" --arg branch "${BRANCH}" '{
  systemMessage: (
    "guard-repo-collision: another Claude Code session is running in this same checkout.\n\n" +
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
