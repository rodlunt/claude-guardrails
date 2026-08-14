#!/usr/bin/env bash
#
# Test suite for bin/guard-git-push.sh.
#
# It classifies against the REAL hook contract rather than just looking for the
# deny JSON, and that distinction is not academic. An early version of the guard
# died on a shell syntax error and exited 2. Exit 2 BLOCKS, so that broken guard
# was blocking every Bash call in the session, and the first harness reported it
# as ALLOW because it only inspected stdout. A harness that cannot tell "allowed"
# from "crashed" is the same bug the guard exists to prevent.
#
#   exit 2                       -> BLOCK   (hard block, regardless of stdout)
#   exit 0 + permissionDecision  -> DENY
#   exit 0 + nothing             -> ALLOW
#   anything else                -> CRASH
#
# Usage: tests/test-guard-git-push.sh
# Exits 0 if every case passes, 1 otherwise.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="${HERE}/../bin/guard-git-push.sh"

[ -x "${GUARD}" ] || { echo "not executable: ${GUARD}" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "these tests need jq" >&2; exit 1; }

PASS=0
FAIL=0

run() {
  local expect="$1" label="$2" cmd="$3" out rc got
  out="$(jq -nc --arg c "${cmd}" \
        '{tool_name:"Bash",tool_input:{command:$c},hook_event_name:"PreToolUse"}' \
        | "${GUARD}" 2>/dev/null)"
  rc=$?
  if [ "${rc}" -eq 2 ]; then
    got=BLOCK
  elif [ "${rc}" -ne 0 ]; then
    got="CRASH(${rc})"
  elif printf '%s' "${out}" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    got=DENY
  else
    got=ALLOW
  fi
  if [ "${got}" = "${expect}" ]; then
    printf '  PASS  %-5s  %s\n' "${got}" "${label}"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  got=%-9s want=%-5s  %s\n' "${got}" "${expect}" "${label}"
    FAIL=$((FAIL + 1))
  fi
}

echo "Refuses a push that does not name its branch"
run DENY  "bare push"                  'git push'
run DENY  "origin, no refspec"         'git push origin'
run DENY  "origin HEAD"                'git push origin HEAD'
run DENY  "-u origin HEAD"             'git push -u origin HEAD'
run DENY  "HEAD:main refspec"          'git push origin HEAD:main'
run DENY  "@ refspec"                  'git push origin @'
run DENY  "buried in a compound cmd"   'git add f && git commit -q -m "x" && git push origin HEAD'
run DENY  "after a cd"                 'cd /tmp/x && git push'
run DENY  "after a heredoc closes"     'git commit -F - <<XEOF
message body
XEOF
git push origin HEAD'

echo
echo "Allows a push that names its branch"
run ALLOW "explicit branch"            'git push origin main'
run ALLOW "explicit -u branch"         'git push -u origin feat/thing'
run ALLOW "branch read in-command"     'B=$(git branch --show-current) && git push origin "$B"'
run ALLOW "git -C with a branch"       'git -C /srv/x push origin main'
run ALLOW "dry run with a branch"      'git push origin main --dry-run'

echo
echo "Does not mistake text about a push for a push"
run ALLOW "echoed"                     'echo "git push origin HEAD"'
run ALLOW "grepped"                    'grep -rn "git push origin HEAD" .'
run ALLOW "inside -m message"          'git commit -m "do not use git push origin HEAD"'
run ALLOW "quoted heredoc body"        'git commit -F - <<'"'"'MSG'"'"'
Documents the trap:
    git add x && git commit -m "y" && git push origin HEAD
MSG'
run ALLOW "unquoted heredoc body"      'git commit -F - <<MSG
mentions git push origin HEAD inline
MSG'
run ALLOW "indented heredoc <<-"       'git commit -F - <<-MSG
	git push origin HEAD
	MSG'

echo
echo "Leaves unrelated commands alone"
run ALLOW "git status"                 'git status'
run ALLOW "git pull"                   'git pull --rebase'
run ALLOW "not git at all"             'ls -la'

echo
echo "Fails OPEN, never closed, when it cannot run"
TD="$(mktemp -d)"
OUT="$(printf '{"tool_input":{"command":"git push origin HEAD"}}' \
      | PATH="${TD}" /bin/bash "${GUARD}" 2>/dev/null)"
RC=$?
rmdir "${TD}" 2>/dev/null || rm -rf "${TD}"
if [ "${RC}" -eq 0 ] && printf '%s' "${OUT}" | grep -q 'NOT ENFORCED'; then
  printf '  PASS  ALLOW  no jq on PATH: allows, and says so loudly\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL  rc=%s  no jq on PATH must exit 0 with a NOT ENFORCED warning\n' "${RC}"
  FAIL=$((FAIL + 1))
fi

# The control for the case above. Without it, "it allowed" proves nothing,
# because a guard that allows everything would also pass that test.
if printf '{"tool_input":{"command":"git push origin HEAD"}}' | "${GUARD}" \
   | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  printf '  PASS  DENY   control: the same input IS denied when jq is present\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL  control: the guard should deny this when jq is available\n'
  FAIL=$((FAIL + 1))
fi

echo
echo "----------------------------------------"
printf '  %d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
