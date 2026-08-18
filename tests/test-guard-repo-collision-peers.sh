#!/usr/bin/env bash
#
# test-guard-repo-collision.sh <path-to-guard-script> <old|new>
#
# Rule 13 harness for guard-repo-collision.sh. Every detection path has a
# control that fires, and the harness encodes BOTH expectation sets:
#
#   old  = the pre-2026-08-18 behaviour (peer detection via /proc cwd only).
#          Running with "old" against the old script passes, which DOCUMENTS
#          the blind spot: scenarios 2 and 3 expect SILENT there.
#   new  = the fixed behaviour (marker channel + command-parsed repo).
#
# The rule-13 proof is the cross-run: `... <old-script> new` must FAIL on
# scenarios 2 and 3. A control that cannot fail on the broken version proves
# nothing, so run it that way once and watch it fail before trusting a pass.
#
# The harness never touches live state: the script is pointed at scratch
# state via CLAUDE_GUARD_STATE_DIR, and TMPDIR is exported too so the OLD
# script's ${TMPDIR:-/tmp} warn-mark dir lands in the sandbox as well (it
# ignores CLAUDE_GUARD_STATE_DIR). "claude" peers are simulated with a copy
# of bash named claude, so /proc/<pid>/comm reads "claude" without a real
# session.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${1:-${HERE}/../bin/guard-repo-collision.sh}"
MODE="${2:-new}"
[ -x "${SCRIPT}" ] || { echo "not executable: ${SCRIPT}" >&2; exit 2; }
case "${MODE}" in old|new) ;; *) echo "mode must be old or new" >&2; exit 2 ;; esac

T="$(mktemp -d)"
FAILURES=0
PIDS_TO_KILL=""
cleanup() {
  for p in ${PIDS_TO_KILL}; do kill "${p}" 2>/dev/null; done
  rm -rf "${T}"
}
trap cleanup EXIT

# A git repo the scenarios collide over, and a non-repo directory standing in
# for $HOME (so the harness does not depend on the runner's $HOME not being a
# repo).
REPO="${T}/repo"
ELSEWHERE="${T}/elsewhere"
mkdir -p "${REPO}" "${ELSEWHERE}"
git -C "${REPO}" init -q -b main
git -C "${REPO}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# comm == "claude" without a real session: a renamed copy of bash.
cp "$(command -v bash)" "${T}/claude"

STATE="${T}/state"
export CLAUDE_GUARD_STATE_DIR="${STATE}"
export TMPDIR="${T}"

# Poll instead of fixed sleeps: a fixed sleep is a race under load, and a
# flaky control teaches you to distrust the harness.
await() { # $1=max tries at 0.1s, rest = condition command
  local n="$1" i=0; shift
  while [ "${i}" -lt "${n}" ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done
  return 1
}
peer_at() { [ "$(readlink -f "/proc/$1/cwd" 2>/dev/null)" = "$2" ]; }

payload() { # $1=command $2=cwd
  jq -nc --arg cmd "$1" --arg cwd "$2" '{tool_input:{command:$cmd},cwd:$cwd}'
}

# Run the guard with a fake-claude ANCESTOR so own_claude_pid() resolves to a
# harness-owned pid, never to a real session (and never to empty when run from
# a plain terminal). Prints the guard's stdout.
run_guard() { # $1=payload
  "${T}/claude" -c 'printf %s "$1" | "$2"' _ "$1" "${SCRIPT}"
}

assert() { # $1=name $2=expected(WARN|SILENT) $3=output
  local got="SILENT"
  printf '%s' "$3" | grep -q 'another Claude Code session' && got="WARN"
  if [ "${got}" = "$2" ]; then
    echo "PASS  $1 (expected $2)"
  else
    echo "FAIL  $1 (expected $2, got ${got})"
    FAILURES=$((FAILURES + 1))
  fi
}

start_peer() { # $1=cwd for the fake claude peer; echoes its pid
  # stdio detached, or the command substitution capturing this function's
  # output would block on the pipe until the peer exits. Trailing ":" stops
  # bash exec-replacing itself with sleep, which would change comm.
  "${T}/claude" -c 'cd "$1" && sleep 60; :' _ "$1" >/dev/null 2>&1 &
  local pid=$!
  PIDS_TO_KILL="${PIDS_TO_KILL} ${pid}"
  await 30 peer_at "${pid}" "$1" \
    || echo "WARNING: peer ${pid} never reached $1" >&2
  echo "${pid}"
}

plant_marker() { # $1=pid  -- marker as the fixed script writes it
  mkdir -p "${STATE}/markers"
  printf '%s\n' "${REPO}" > "${STATE}/markers/$(printf '%s' "${REPO}" | tr '/' '_').$1"
}

fresh_state() { rm -rf "${STATE}"; }

echo "== scenario 1: control -- peer whose process cwd IS the repo =="
# Must WARN on old AND new. This is the harness's own liveness proof: if this
# stays silent the harness is broken and every other SILENT means nothing.
fresh_state
P1="$(start_peer "${REPO}")"
OUT="$(run_guard "$(payload 'git commit -m x' "${REPO}")")"
assert "s1-cwd-peer" "WARN" "${OUT}"
kill "${P1}" 2>/dev/null

echo "== scenario 2: peer at non-repo cwd, live marker for the repo =="
# The real-world topology: every session launches from $HOME and cd's inside
# Bash commands, so the peer's process cwd is useless. Old: SILENT (the blind
# spot). New: WARN via the marker.
fresh_state
P2="$(start_peer "${ELSEWHERE}")"
plant_marker "${P2}"
OUT="$(run_guard "$(payload 'git commit -m x' "${REPO}")")"
assert "s2-marker-peer" "$([ "${MODE}" = new ] && echo WARN || echo SILENT)" "${OUT}"

echo "== scenario 3: self payload cwd is not a repo, command cd's in =="
# Same peer still live with its marker; the SELF side now has to find the repo
# by parsing the command. Old: SILENT (bails at rev-parse of payload cwd).
OUT="$(run_guard "$(payload "cd ${REPO} && git commit -m x" "${ELSEWHERE}")")"
assert "s3-cd-parsed-self" "$([ "${MODE}" = new ] && echo WARN || echo SILENT)" "${OUT}"

echo "== scenario 3b: git -C form =="
OUT="$(run_guard "$(payload "git -C ${REPO} commit -m x" "${ELSEWHERE}")")"
assert "s3b-dash-C-self" "$([ "${MODE}" = new ] && echo WARN || echo SILENT)" "${OUT}"
kill "${P2}" 2>/dev/null

echo "== scenario 4: no peers at all =="
fresh_state
OUT="$(run_guard "$(payload 'git commit -m x' "${REPO}")")"
assert "s4-no-peers" "SILENT" "${OUT}"

echo "== scenario 5: marker whose pid is dead gets pruned, no warning =="
fresh_state
DEAD=99999999   # beyond kernel.pid_max default; never a live pid
plant_marker "${DEAD}"
OUT="$(run_guard "$(payload 'git commit -m x' "${REPO}")")"
assert "s5-dead-marker-silent" "SILENT" "${OUT}"
if [ "${MODE}" = new ]; then
  if [ -e "${STATE}/markers/$(printf '%s' "${REPO}" | tr '/' '_').${DEAD}" ]; then
    echo "FAIL  s5-dead-marker-pruned (marker still present)"; FAILURES=$((FAILURES + 1))
  else
    echo "PASS  s5-dead-marker-pruned"
  fi
fi

echo "== scenario 6: warns once per session per repo =="
# Two invocations under the SAME fake-claude ancestor: first warns, second is
# quiet. Peer detected via cwd so this runs on old and new alike.
fresh_state
P6="$(start_peer "${REPO}")"
OUT="$("${T}/claude" -c '
  printf %s "$1" | "$2"
  echo "---SECOND---"
  printf %s "$1" | "$2"
' _ "$(payload 'git commit -m x' "${REPO}")" "${SCRIPT}")"
FIRST="${OUT%%---SECOND---*}"
SECOND="${OUT##*---SECOND---}"
assert "s6-first-warns" "WARN" "${FIRST}"
assert "s6-second-quiet" "SILENT" "${SECOND}"
kill "${P6}" 2>/dev/null

if [ "${MODE}" = new ]; then
  echo "== scenario 7: the script WRITES its own marker on a git write =="
  # Read-path scenarios plant markers by hand; this proves the write path, so
  # two fixed sessions detect each other without the harness's help.
  fresh_state
  # stdio detached here too: the orphaned sleep would otherwise hold any pipe
  # capturing this harness's output open for the full 60s after the kill.
  "${T}/claude" -c 'printf %s "$1" | "$2" >/dev/null; sleep 60; :' _ \
    "$(payload 'git commit -m x' "${REPO}")" "${SCRIPT}" >/dev/null 2>&1 &
  W=$!; PIDS_TO_KILL="${PIDS_TO_KILL} ${W}"
  # own_claude_pid inside that run resolves to ${W} (the fake-claude ancestor)
  await 50 test -e "${STATE}/markers/$(printf '%s' "${REPO}" | tr '/' '_').${W}" || true
  if [ -e "${STATE}/markers/$(printf '%s' "${REPO}" | tr '/' '_').${W}" ]; then
    echo "PASS  s7-marker-written"
  else
    echo "FAIL  s7-marker-written"; FAILURES=$((FAILURES + 1))
  fi
  # ...and a second session now sees it purely via the script's own machinery.
  OUT="$(run_guard "$(payload 'git commit -m x' "${REPO}")")"
  assert "s7-end-to-end" "WARN" "${OUT}"
  kill "${W}" 2>/dev/null
fi

echo "== scenario 8: git -C names a DIFFERENT repo than the payload cwd =="
# Session sits in repoA but writes to repoB with `git -C`. The explicit target
# must win, or the marker and the peer check land on the wrong repo. Old:
# SILENT (it resolved the payload cwd and looked for peers in repoA).
REPO_B="${T}/repob"
mkdir -p "${REPO_B}"
git -C "${REPO_B}" init -q -b main
git -C "${REPO_B}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
fresh_state
P8="$(start_peer "${ELSEWHERE}")"
mkdir -p "${STATE}/markers"
printf '%s\n' "${REPO_B}" > "${STATE}/markers/$(printf '%s' "${REPO_B}" | tr '/' '_').${P8}"
OUT="$(run_guard "$(payload "git -C ${REPO_B} commit -m x" "${REPO}")")"
assert "s8-cross-repo-dash-C" "$([ "${MODE}" = new ] && echo WARN || echo SILENT)" "${OUT}"
kill "${P8}" 2>/dev/null

echo
if [ "${FAILURES}" -gt 0 ]; then
  echo "RESULT: ${FAILURES} failure(s) [script=${SCRIPT} mode=${MODE}]"
  exit 1
fi
echo "RESULT: all passed [script=${SCRIPT} mode=${MODE}]"
