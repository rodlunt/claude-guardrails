#!/usr/bin/env bash
# peer-ack-hook.sh - surfaces cross-session messages that were never acknowledged.
#
# Runs on SessionStart and UserPromptSubmit. Advisory only: it prints, it never
# blocks, and every exit is 0.
#
# ⚠️ WHY THE PARANOIA, read before editing
# On UserPromptSubmit BOTH blocking channels, exit 2 and decision:"block", ERASE
# the user's prompt outright. They do not degrade it. So a defect in this file
# does not make the feature stop working, it silently eats everything the user
# types, from inside the session that is eating it. A bash SYNTAX ERROR exits 2
# without running a single line, so no discipline inside this file can protect
# against a bad edit TO this file. That is why the registration in
# settings-policy.json wraps it as:
#
#     s="$HOME/claude-guardrails/bin/peer-ack-hook.sh"; [ -x "$s" ] && bash "$s"; exit 0
#
# The trailing `exit 0` is the only thing that holds when this script cannot run
# at all. It is NOT redundant with the `exit 0` at the bottom of this file and it
# must never be tidied away. Same reasoning that makes any hook on a
# blocking event signal through a wrapper rather than with a bare exit code.
#
# OFF SWITCH, per machine, outside anything apply-settings.sh can re-add:
#     touch "${XDG_STATE_HOME:-$HOME/.local/state}/peer-ack/off"
# That is a state file, not a settings change, so it does not fight the policy
# and nothing will silently undo it.

set -uo pipefail

STATE="${XDG_STATE_HOME:-$HOME/.local/state}/peer-ack"
LEDGER="$(dirname "$0")/peer-ack.sh"
NAGGED="$STATE/last-nagged"
NAG_INTERVAL="${PEER_ACK_NAG_SECONDS:-900}"

# Escape hatch first, before anything that could fail.
[ -e "$STATE/off" ] && exit 0

# If the ledger is missing or not runnable, say nothing. A missing dependency
# must never turn into noise on every prompt, and it certainly must not turn
# into a non-zero exit on this event.
[ -x "$LEDGER" ] || exit 0

# Rate limit: without this it reprints on every single prompt. Anything that
# nags constantly gets ignored, and an alert that is ignored is not an alert.
now=$(date +%s)
if [ -f "$NAGGED" ]; then
  last=$(cat "$NAGGED" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((now - last)) -lt "$NAG_INTERVAL" ]; then exit 0; fi
fi

out="$("$LEDGER" pending --quiet 2>/dev/null)"
rc=$?

# rc 2 means nothing pending, which is the normal case and is silent.
if [ "$rc" -ne 0 ] || [ -z "$out" ]; then exit 0; fi

mkdir -p "$STATE" 2>/dev/null
echo "$now" > "$NAGGED" 2>/dev/null

# stdout on these events becomes context for the assistant.
cat <<EOF
[peer-ack] Cross-session messages you sent are still UNACKNOWLEDGED:

$out

A successful SendMessage means the message was QUEUED, not received: it can sit
awaiting the recipient terminal's approval and expire unread. Treat anything
above as UNDELIVERED. Do not assume the peer acted on it, and if it matters,
tell the user rather than assuming it landed. Clear one with:
  bash ~/claude-guardrails/bin/peer-ack.sh ack <nonce>
EOF

exit 0
