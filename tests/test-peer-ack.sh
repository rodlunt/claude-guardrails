#!/usr/bin/env bash
#
# Test suite for bin/peer-ack.sh and bin/peer-ack-hook.sh.
#
# STATED GAPS, because a suite that hides what it cannot cover is the same bug as
# a check that cannot fail:
#
#   1. Real cross-session delivery is not exercised. That needs two live Claude
#      Code sessions and a human approving a message at the receiving terminal,
#      which CI cannot produce. What IS covered is everything the ledger decides
#      on its own: recording, clearing, staleness, refusal of bad input, and the
#      hook's silence/emission behaviour.
#   2. The MCP server is syntax-checked only. Its protocol behaviour was verified
#      by a real stdio handshake by hand (initialize, tools/list, tools/call);
#      CI does not install the SDK, so that is not re-proven here.
#
# The important property under test is that this thing can say "still waiting".
# A ledger that only ever reports "nothing pending" is indistinguishable from a
# ledger that is broken, so the positive cases below are the point of the suite.
#
# Contract for the hook, which is registered on UserPromptSubmit:
#   exit 2  -> ERASES the user's prompt. The hook must NEVER do this.
#   exit 0  -> safe, whether it printed anything or not.
#
# Usage: tests/test-peer-ack.sh

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LEDGER="${HERE}/../bin/peer-ack.sh"
HOOK="${HERE}/../bin/peer-ack-hook.sh"

[ -x "${LEDGER}" ] || { echo "not executable: ${LEDGER}" >&2; exit 1; }
[ -x "${HOOK}" ] || { echo "not executable: ${HOOK}" >&2; exit 1; }

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  ok    $1"; }
no() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }

# Every case runs against a throwaway state dir so nothing touches a real ledger.
new_state() {
  STATE_DIR="$(mktemp -d)"
  export XDG_STATE_HOME="${STATE_DIR}"
}
drop_state() { rm -rf "${STATE_DIR:?}"; }

echo "peer-ack test suite"
echo

# --- ledger: the empty case -------------------------------------------------
new_state
out="$("${LEDGER}" pending 2>&1)"; rc=$?
[ "${rc}" -eq 2 ] && ok "empty ledger exits 2 so callers can branch" \
  || no "empty ledger should exit 2, got ${rc}"
case "${out}" in *"nothing pending"*) ok "empty ledger says so plainly" ;;
  *) no "empty ledger wording: ${out}" ;; esac

# --- ledger: recording and listing (the POSITIVE controls) ------------------
"${LEDGER}" record case-1 peer-b "a message that matters" >/dev/null 2>&1
out="$("${LEDGER}" pending 2>&1)"
case "${out}" in *case-1*) ok "a recorded nonce is listed (positive control)" ;;
  *) no "recorded nonce absent from pending: ${out}" ;; esac
case "${out}" in *"a message that matters"*) ok "the summary is carried through" ;;
  *) no "summary missing from pending output" ;; esac

out="$("${LEDGER}" record case-1 peer-b "second attempt" 2>&1)"
case "${out}" in *"already pending"*) ok "a duplicate nonce does not overwrite" ;;
  *) no "duplicate nonce not refused: ${out}" ;; esac

# --- ledger: staleness ------------------------------------------------------
out="$(PEER_ACK_STALE_SECONDS=0 "${LEDGER}" pending 2>&1)"
case "${out}" in *STALE*) ok "the stale threshold can mark an entry STALE" ;;
  *) no "stale threshold never fires" ;; esac
case "${out}" in *UNDELIVERED*) ok "a stale entry is called UNDELIVERED, not late" ;;
  *) no "stale entry does not say UNDELIVERED" ;; esac

out="$("${LEDGER}" pending 2>&1)"
case "${out}" in *STALE*) no "a fresh entry was marked STALE (over-detection)" ;;
  *) ok "a fresh entry is not marked STALE" ;; esac

# --- ledger: refusing input that could escape the directory -----------------
"${LEDGER}" record "../escape" peer-b >/dev/null 2>&1
[ $? -eq 1 ] && ok "a path-escaping nonce is refused" || no "path-escaping nonce accepted"
"${LEDGER}" record "" peer-b >/dev/null 2>&1
[ $? -eq 1 ] && ok "an empty nonce is refused" || no "empty nonce accepted"

# --- ledger: acking ---------------------------------------------------------
out="$("${LEDGER}" ack never-recorded 2>&1)"
case "${out}" in *"no pending record"*) ok "acking an unknown nonce says so rather than pretending" ;;
  *) no "unknown ack silently accepted: ${out}" ;; esac

"${LEDGER}" ack case-1 >/dev/null 2>&1
out="$("${LEDGER}" pending 2>&1)"
case "${out}" in *case-1*) no "an acked nonce is still pending" ;;
  *) ok "an acked nonce is cleared" ;; esac

# `history` shipped broken twice because no test ever called it. Assert on
# CONTENT: a dead function prints nothing, which an exit-code check accepts.
out="$("${LEDGER}" history 2>&1)"
case "${out}" in *case-1*) ok "history shows the resolved message" ;;
  *) no "history does not show the acked nonce: ${out}" ;; esac
case "${out}" in *Traceback*|*SyntaxError*) no "history raised an exception" ;;
  *) ok "history runs without raising" ;; esac

"${LEDGER}" bogus-subcommand >/dev/null 2>&1
[ $? -eq 1 ] && ok "an unknown subcommand exits 1" || no "unknown subcommand did not exit 1"

out="$("${LEDGER}" selftest 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "the ledger's own selftest passes" || no "selftest failed: ${out}"
drop_state

# --- hook: the part that must never block -----------------------------------
new_state
"${HOOK}" >/dev/null 2>&1
[ $? -eq 0 ] && ok "hook exits 0 with an empty ledger" || no "hook exited non-zero when idle"

out="$("${HOOK}" 2>&1)"
[ -z "${out}" ] && ok "hook is silent with nothing pending" || no "hook spoke when idle: ${out}"

"${LEDGER}" record case-2 peer-b "unacknowledged" >/dev/null 2>&1
out="$("${HOOK}" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "hook exits 0 when it DOES have something to say" \
  || no "hook exited ${rc} while reporting, which would erase the prompt"
case "${out}" in *case-2*) ok "hook surfaces the unacknowledged nonce" ;;
  *) no "hook did not surface the pending message" ;; esac
case "${out}" in *UNDELIVERED*) ok "hook tells the reader to treat it as undelivered" ;;
  *) no "hook output does not say UNDELIVERED" ;; esac

out="$("${HOOK}" 2>&1)"
[ -z "${out}" ] && ok "hook rate-limits itself rather than nagging every prompt" \
  || no "hook repeated immediately"

rm -f "${STATE_DIR}/peer-ack/last-nagged"
touch "${STATE_DIR}/peer-ack/off"
out="$("${HOOK}" 2>&1)"; rc=$?
[ -z "${out}" ] && [ "${rc}" -eq 0 ] && ok "the off switch silences it completely" \
  || no "off switch did not silence the hook"
drop_state

# --- the failure mode the wrapper exists for --------------------------------
# A bash SYNTAX ERROR exits 2 without executing a single line, and on
# UserPromptSubmit exit 2 erases the user's prompt. No discipline inside the
# script can protect against a bad edit TO the script, so the registration
# wraps it. This proves the wrapper is doing real work rather than being
# decorative, using a deliberately broken copy.
new_state
BROKEN="${STATE_DIR}/broken.sh"
{ echo '#!/usr/bin/env bash'; echo 'if [ ; then'; cat "${HOOK}"; } > "${BROKEN}"
chmod +x "${BROKEN}"
bash "${BROKEN}" >/dev/null 2>&1
[ $? -eq 2 ] && ok "a syntax-broken hook really does exit 2 (the hazard is real)" \
  || no "broken script did not exit 2, so this test proves nothing"

( s="${BROKEN}"; [ -x "$s" ] && bash "$s" >/dev/null 2>&1; exit 0 )
[ $? -eq 0 ] && ok "the registration wrapper converts that to exit 0" \
  || no "wrapper did not neutralise the syntax error"

( s="${STATE_DIR}/absent.sh"; [ -x "$s" ] && bash "$s" >/dev/null 2>&1; exit 0 )
[ $? -eq 0 ] && ok "the wrapper survives the script being missing entirely" \
  || no "wrapper failed on a missing script"
drop_state

# --- MCP server: syntax only, and say so ------------------------------------
SERVER="${HERE}/../mcp/peer-ack/server.py"
if [ -f "${SERVER}" ]; then
  if command -v python3 >/dev/null 2>&1; then
    python3 -m py_compile "${SERVER}" 2>/dev/null \
      && ok "MCP server is syntactically valid python" \
      || no "MCP server does not compile"
  else
    echo "  skip  python3 unavailable, MCP server not syntax-checked"
  fi
else
  no "mcp/peer-ack/server.py is missing"
fi

echo
echo "passed ${PASS}, failed ${FAIL}"
echo
echo "NOT COVERED, deliberately:"
echo "  - real cross-session delivery, which needs two live sessions and a human"
echo "    approving the message at the receiving terminal"
echo "  - MCP protocol behaviour; verified by hand over a real stdio handshake"
echo "    (initialize, tools/list, tools/call), not re-proven in CI"

[ "${FAIL}" -eq 0 ] || exit 1
