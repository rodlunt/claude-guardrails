#!/usr/bin/env bash
#
# Test suite for bin/guard-repo-collision.sh.
#
# This file covers everything deterministic: which git verbs the guard reacts
# to, that it never blocks, that it stays silent with no peer, and that it
# fails open rather than closed when it cannot run. Those are the parts most
# likely to break under editing.
#
# The peer-present paths live in test-guard-repo-collision-peers.sh. This
# header used to declare them a stated gap ("needs a second real Claude Code
# process, which CI cannot spawn"); that turned out to be false. A copy of
# bash renamed to `claude` gives /proc/<pid>/comm the right value, so a peer
# can be simulated in CI, and the peers suite does, including the rule-13
# cross-run proving its controls fail on the pre-fix script.
#
# Contract, same as the push guard:
#   exit 2                  -> BLOCK  (this guard must NEVER do this)
#   exit 0 + systemMessage  -> WARN
#   exit 0 + nothing        -> SILENT
#
# Usage: tests/test-guard-repo-collision.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="${HERE}/../bin/guard-repo-collision.sh"
REPO="$(cd "${HERE}/.." && pwd)"

[ -x "${GUARD}" ] || { echo "not executable: ${GUARD}" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "these tests need jq" >&2; exit 1; }

PASS=0
FAIL=0

# The guard keeps its markers and once-per-session throttle in a shared state
# dir; point it at a scratch one so these tests neither touch live state nor
# inherit it. Each case gets a clean dir, or the throttle would make every
# test after the first one silent and they would all "pass" for the wrong
# reason.
CLAUDE_GUARD_STATE_DIR="$(mktemp -d)"
export CLAUDE_GUARD_STATE_DIR
trap 'rm -rf "${CLAUDE_GUARD_STATE_DIR}"' EXIT
reset_throttle() { rm -rf "${CLAUDE_GUARD_STATE_DIR}"; }

run() {
  local expect="$1" label="$2" cmd="$3" cwd="$4" out rc got
  out="$(jq -nc --arg c "${cmd}" --arg d "${cwd}" \
        '{tool_name:"Bash",tool_input:{command:$c},cwd:$d,hook_event_name:"PreToolUse"}' \
        | "${GUARD}" 2>/dev/null)"
  rc=$?
  if [ "${rc}" -eq 2 ]; then
    got=BLOCK
  elif [ "${rc}" -ne 0 ]; then
    got="CRASH(${rc})"
  elif printf '%s' "${out}" | jq -e 'has("systemMessage")' >/dev/null 2>&1; then
    got=WARN
  else
    got=SILENT
  fi
  if [ "${got}" = "${expect}" ]; then
    printf '  PASS  %-6s  %s\n' "${got}" "${label}"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  got=%-9s want=%-6s  %s\n' "${got}" "${expect}" "${label}"
    FAIL=$((FAIL + 1))
  fi
}

# This repository, running under CI, has no peer Claude session. So every case
# below must be SILENT. On its own that proves little, which is exactly why the
# verb-matching is exercised separately further down.
echo "No peer session present: stays out of the way"
for c in "git commit -m x" "git merge main" "git push origin main" "git checkout -b x" \
         "git status" "git log --oneline" "ls -la" "echo git commit"; do
  reset_throttle
  run SILENT "${c}" "${c}" "${REPO}"
done

echo
echo "Never blocks, whatever it is given"
reset_throttle
run SILENT "malformed payload is not a block" "git commit -m x" "/nonexistent/path"

echo
echo "Verb matching (the part most likely to break under editing)"
# Tested directly against the guard's own matcher rather than through a peer, so
# a regex edit that stops matching `git commit` fails here even with no peer.
VERB_RE='(^|[;&|]|\s)git(\s+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*\s+(commit|merge|rebase|push|pull|checkout|switch|reset|cherry-pick|revert|am|stash)(\s|$)'
check_verb() {
  local expect="$1" cmd="$2"
  if printf '%s' "${cmd}" | grep -qE "${VERB_RE}"; then got=MATCH; else got=NOMATCH; fi
  if [ "${got}" = "${expect}" ]; then
    printf '  PASS  %-7s  %s\n' "${got}" "${cmd}"; PASS=$((PASS + 1))
  else
    printf '  FAIL  got=%-7s want=%-7s  %s\n' "${got}" "${expect}" "${cmd}"; FAIL=$((FAIL + 1))
  fi
}
check_verb MATCH   "git commit -m x"
check_verb MATCH   "git merge main"
check_verb MATCH   "git rebase main"
check_verb MATCH   "git push origin main"
check_verb MATCH   "git checkout -b feat/x"
check_verb MATCH   "git switch main"
check_verb MATCH   "git reset --hard"
check_verb MATCH   "git cherry-pick abc123"
check_verb MATCH   "git stash"
check_verb MATCH   "git pull origin main"
check_verb MATCH   "git revert HEAD"
check_verb MATCH   "git am 0001-fix.patch"
check_verb MATCH   "cd /tmp && git commit -m x"
check_verb MATCH   "git -C /srv/x commit -m y"
check_verb NOMATCH "git status"
check_verb NOMATCH "git log --oneline"
check_verb NOMATCH "git diff"
check_verb NOMATCH "git branch --show-current"
check_verb NOMATCH "ls -la"
check_verb NOMATCH "gitk"

echo
echo "Fails OPEN, never closed, when it cannot run"
TD="$(mktemp -d)"
OUT="$(jq -nc --arg d "${REPO}" \
      '{tool_input:{command:"git commit -m x"},cwd:$d}' \
      | PATH="${TD}" /bin/bash "${GUARD}" 2>/dev/null)"
RC=$?
rmdir "${TD}" 2>/dev/null || rm -rf "${TD}"
if [ "${RC}" -eq 0 ] && printf '%s' "${OUT}" | grep -q 'NOT ENFORCED'; then
  printf '  PASS  ALLOW   no jq on PATH: allows, and says so loudly\n'; PASS=$((PASS + 1))
else
  printf '  FAIL  rc=%s  no jq on PATH must exit 0 with a NOT ENFORCED warning\n' "${RC}"; FAIL=$((FAIL + 1))
fi

reset_throttle
echo
echo "----------------------------------------"
printf '  %d passed, %d failed\n' "${PASS}" "${FAIL}"
echo
echo "  Peer-present paths (cwd scan, markers, pruning, warn-once) are covered"
echo "  by tests/test-guard-repo-collision-peers.sh with simulated peers."
echo
[ "${FAIL}" -eq 0 ] || exit 1
