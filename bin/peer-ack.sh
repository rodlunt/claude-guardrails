#!/usr/bin/env bash
# peer-ack.sh - delivery ledger for cross-session Claude messages.
#
# WHY THIS EXISTS
# Claude Code's SendMessage returns {"success": true} when a message is QUEUED,
# not when a peer receives it. On 2026-08-16 a message returned success, was held
# for the recipient terminal's approval, expired unapproved, and never reached
# that session, which then closed. Nothing anywhere recorded that it was still
# waiting, so a silent expiry looked exactly like a delivered message.
#
# This does not deliver anything and deliberately does not try. It records that a
# message is awaiting an ack, and it makes an unacknowledged message VISIBLE
# instead of assumed-delivered. Delivery stays on the built-in transport, which
# keeps the recipient user's approval gate intact. Building a channel that
# bypasses that gate would be trading a human control for convenience.
#
# USAGE
#   peer-ack.sh record <nonce> <to> [summary]   # after sending something with ACK-REQ
#   peer-ack.sh ack    <nonce>                  # when the matching ACK arrives
#   peer-ack.sh pending [--quiet]               # list outstanding; --quiet = machine output
#   peer-ack.sh history [n]                     # last n resolved entries
#   peer-ack.sh selftest                        # controls: does it detect AND not over-detect
#
# EXIT CODES
#   0  ok
#   1  usage error
#   2  nothing pending (only for `pending`, so callers can branch)
# It never exits non-zero for a hook-relevant reason; the hook wrapper forces 0.

set -uo pipefail

STATE="${XDG_STATE_HOME:-$HOME/.local/state}/peer-ack"
PENDING="$STATE/pending"
LOG="$STATE/resolved.jsonl"
STALE_SECONDS="${PEER_ACK_STALE_SECONDS:-600}"

mkdir -p "$PENDING" 2>/dev/null || {
  echo "peer-ack: cannot create $PENDING" >&2
  exit 1
}

now_iso() { date -Is; }
now_epoch() { date +%s; }

# Nonces name files, so refuse anything that could escape the directory. A bad
# nonce is a usage error, never something we silently sanitise and accept.
valid_nonce() {
  case "$1" in
    ''|*/*|*..*) return 1 ;;
    *) [ "${#1}" -le 128 ] && printf '%s' "$1" | grep -qE '^[A-Za-z0-9._-]+$' ;;
  esac
}

cmd_record() {
  local nonce="${1:-}" to="${2:-}" summary="${3:-}"
  if ! valid_nonce "$nonce" || [ -z "$to" ]; then
    echo "usage: peer-ack.sh record <nonce> <to> [summary]" >&2; exit 1
  fi
  local f="$PENDING/$nonce.json"
  if [ -e "$f" ]; then
    echo "peer-ack: $nonce is already pending (not overwriting)" >&2
    exit 0
  fi
  python3 - "$f" "$nonce" "$to" "$summary" "$(now_iso)" "$(now_epoch)" <<'PY'
import json,sys
f,nonce,to,summary,iso,epoch = sys.argv[1:7]
json.dump({"nonce":nonce,"to":to,"summary":summary,"sent_at":iso,
           "sent_epoch":int(epoch),"session":__import__("os").environ.get("CLAUDE_SESSION_ID","")},
          open(f,"w"))
PY
  echo "peer-ack: recorded $nonce -> $to (awaiting ack)"
}

cmd_ack() {
  local nonce="${1:-}"
  valid_nonce "$nonce" || { echo "usage: peer-ack.sh ack <nonce>" >&2; exit 1; }
  local f="$PENDING/$nonce.json"
  if [ ! -e "$f" ]; then
    # Not an error: acking something we never recorded is worth SAYING, because
    # it means either the peer invented a nonce or our record was lost.
    echo "peer-ack: no pending record for $nonce (acked anyway, nothing to clear)"
    exit 0
  fi
  python3 - "$f" "$LOG" "$(now_iso)" <<'PY'
import json,sys
f,log,iso = sys.argv[1:4]
d=json.load(open(f))
d["acked_at"]=iso
d["outcome"]="acked"
with open(log,"a") as fh: fh.write(json.dumps(d)+"\n")
PY
  rm -f "$f"
  echo "peer-ack: $nonce acknowledged and cleared"
}

# Prints the ledger. Everything here is DERIVED from the files on disk; nothing
# asserts a status the data did not produce.
cmd_pending() {
  local quiet="${1:-}"
  local n=0
  shopt -s nullglob
  local files=("$PENDING"/*.json)
  shopt -u nullglob
  n=${#files[@]}
  if [ "$n" -eq 0 ]; then
    [ "$quiet" = "--quiet" ] || echo "peer-ack: nothing pending"
    exit 2
  fi
  python3 - "$STALE_SECONDS" "$quiet" "${files[@]}" <<'PY'
import json,sys,time
stale=int(sys.argv[1]); quiet=sys.argv[2]=="--quiet"; files=sys.argv[3:]
now=int(time.time()); rows=[]
for f in files:
    try: d=json.load(open(f))
    except Exception: continue
    age=now-int(d.get("sent_epoch",now))
    rows.append((age,d))
rows.sort(reverse=True)
if not quiet:
    print(f"peer-ack: {len(rows)} message(s) awaiting acknowledgement")
for age,d in rows:
    mark = "STALE" if age>=stale else "waiting"
    mins = age//60
    print(f"  [{mark}] {d['nonce']}  to={d.get('to','?')}  {mins}m ago  {d.get('summary','')}"[:200])
if not quiet and any(a>=stale for a,_ in rows):
    print("  A STALE entry has had no ack. Treat it as UNDELIVERED, not delivered.")
PY
}

cmd_history() {
  local n="${1:-10}"
  [ -f "$LOG" ] || { echo "peer-ack: no history yet"; exit 0; }
  # Heredoc, NOT `python3 -c` with a quoted script. The escaped double quotes in
  # an f-string did not survive the shell and this function died with a
  # SyntaxError the FIRST time it was ever called (2026-08-16). Every other
  # function here already used a heredoc; this one was the odd one out, and the
  # selftest passed regardless because nothing invoked it.
  # Do NOT pipe into this. `python3 - <<HEREDOC` takes the PROGRAM from stdin,
  # so a `tail | python3 - <<...` can never see the tail output: the heredoc has
  # already claimed stdin. That was the second bug in this one function on
  # 2026-08-16, found by the selftest written after the first. Read the file in
  # Python and pass the path as argv instead.
  python3 - "$LOG" "$n" <<'HISTPY'
import json, sys
path, n = sys.argv[1], int(sys.argv[2])
try:
    lines = [l for l in open(path).read().splitlines() if l.strip()][-n:]
except OSError as err:
    print(f"  cannot read {path}: {err}")
    sys.exit(0)
for line in lines:
    try:
        d = json.loads(line)
    except Exception:
        continue
    print(f"  {str(d.get('acked_at','?'))[:19]}  {d.get('nonce','?')}  to={d.get('to','?')}  {d.get('outcome','?')}")
HISTPY
}

# Rule 12: a detector that has never fired a positive is not known to work. This
# proves BOTH directions against a throwaway state dir, so it cannot pass by
# simply never finding anything.
cmd_selftest() {
  local tmp; tmp="$(mktemp -d)"
  local rc=0
  export XDG_STATE_HOME="$tmp"
  local self="$0"

  out="$("$self" pending 2>&1)"; [ $? -eq 2 ] || { echo "FAIL: empty ledger should exit 2"; rc=1; }
  case "$out" in *"nothing pending"*) ;; *) echo "FAIL: empty ledger wording: $out"; rc=1;; esac

  "$self" record ctrl-1 peer-x "control message" >/dev/null || { echo "FAIL: record"; rc=1; }
  out="$("$self" pending 2>&1)"
  case "$out" in *ctrl-1*) ;; *) echo "FAIL: recorded nonce not listed (POSITIVE control)"; rc=1;; esac

  PEER_ACK_STALE_SECONDS=0 "$self" pending 2>&1 | grep -q "STALE" \
    || { echo "FAIL: stale threshold never marks STALE"; rc=1; }

  "$self" ack ctrl-1 >/dev/null || { echo "FAIL: ack"; rc=1; }
  out="$("$self" pending 2>&1)"
  case "$out" in *ctrl-1*) echo "FAIL: acked nonce still pending"; rc=1;; esac

  "$self" record ../escape peer-x 2>/dev/null && { echo "FAIL: path-escaping nonce accepted"; rc=1; }

  grep -q '"outcome": "acked"' "$tmp/peer-ack/resolved.jsonl" 2>/dev/null \
    || { echo "FAIL: resolved.jsonl missing the acked record"; rc=1; }

  # `history` was BROKEN and this selftest passed anyway, because no test ever
  # invoked it (2026-08-16, found by using it for real). Exercise every
  # subcommand, and assert on CONTENT: a function that dies still prints
  # nothing, which an exit-code-only check accepts happily.
  out="$("$self" history 2>&1)" || { echo "FAIL: history exited non-zero"; rc=1; }
  case "$out" in *ctrl-1*) ;; *) echo "FAIL: history does not show the acked nonce: $out"; rc=1;; esac
  case "$out" in *Traceback*|*SyntaxError*) echo "FAIL: history raised an exception"; rc=1;; esac

  "$self" bogus-subcommand >/dev/null 2>&1
  [ $? -eq 1 ] || { echo "FAIL: unknown subcommand should exit 1"; rc=1; }

  rm -rf "$tmp"
  [ $rc -eq 0 ] && echo "peer-ack selftest: PASS (detects, clears, refuses bad nonces, marks stale)"
  return $rc
}

case "${1:-}" in
  record)   shift; cmd_record "$@" ;;
  ack)      shift; cmd_ack "$@" ;;
  pending)  shift; cmd_pending "${1:-}" ;;
  history)  shift; cmd_history "${1:-}" ;;
  selftest) cmd_selftest ;;
  *) echo "usage: peer-ack.sh {record|ack|pending|history|selftest} ..." >&2; exit 1 ;;
esac
