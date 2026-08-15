# peer-ack

Delivery bookkeeping for messages between Claude Code sessions. Three parts, one
ledger.

| Part | Path | Role |
|---|---|---|
| Ledger CLI | `bin/peer-ack.sh` | `record` / `ack` / `pending` / `history` / `selftest` |
| Hook | `bin/peer-ack-hook.sh` | surfaces unacknowledged messages at SessionStart and UserPromptSubmit |
| MCP server | `mcp/peer-ack/server.py` | the same operations as tools, plus `peers` |

## Why

Claude Code's `SendMessage` returns `{"success": true}` when a message is
**queued**, not when a peer receives it.

A message can be held for approval at the receiving terminal, expire unread, and
leave the sender believing it was delivered. That happened: a session reported a
message as sent, the recipient never approved it, it expired, and the recipient
session then closed. Nothing recorded that it was still waiting, so a silent
expiry was indistinguishable from success.

This is the same shape as every other guard in this repository. "Remember which
messages are still unacknowledged" is a hope. A ledger that refuses to forget is
a mechanism.

## What it deliberately does NOT do

It sends nothing and implements no transport.

The obvious fix is a private channel between sessions that delivers directly.
That was rejected. The message was not lost to a flaw: it was held for a human's
approval that never came. A channel that auto-delivered would have removed that
gate. A human approval gate is not an obstacle to route around.

So delivery stays on the built-in tool, and this only tracks what happened to it.

## The convention

1. A message needing confirmation ends with `ACK-REQ <nonce>`. The nonce is
   **sender-invented**: the sender cannot know its own transport id until after
   the send returns, so the transport id cannot appear in the body being sent.
2. The receiver's first act on delivery is `ACK <nonce>`, before doing any of
   the work the message asked for.
3. **Unacknowledged means UNDELIVERED.** Never assume the peer acted on it.

It is a convention, so it only works if both sides hold it. The ledger's job is
to make a broken convention visible rather than silent.

## Usage

```bash
bin/peer-ack.sh record <nonce> <to> "summary"   # after sending, if it matters
bin/peer-ack.sh ack <nonce>                     # when the ack arrives
bin/peer-ack.sh pending                         # what is still outstanding
bin/peer-ack.sh selftest                        # controls, both directions
```

## The MCP server

```bash
claude mcp add peer-ack -- uv run --with mcp python "$HOME/claude-guardrails/mcp/peer-ack/server.py"
```

Tools: `record`, `ack`, `pending`, `history`, `peers`.

Python via `uv` rather than Node, so the only dependency is the MCP SDK itself.

**SDK version.** Verified against **mcp 2.0.0** on Python 3.14, negotiating
protocol **2025-06-18**, by a real stdio handshake (`initialize`, `tools/list`,
`tools/call`) rather than by importing the module. 2.0 was a breaking rename:
`mcp.server.fastmcp.FastMCP` no longer exists and the entry point is
`mcp.server.MCPServer`. `server.py` tries the 2.x path and falls back to the 1.x
one, so it works on either. Do not collapse that back to a single import.

⚠️ **The registration is not version-controlled and cannot be.** MCP servers are
registered in `~/.claude.json`, which this repository does not manage. Claude
Code loads that file at session start and rewrites the whole thing from its
in-memory copy when it flushes state, so an external edit made while a session is
running can be silently reverted by that session's later flush. `apply-settings.sh
--heal` runs from a SessionStart hook, which is exactly that condition, so it
cannot own this the way it owns `settings.json`. Write-time verification proves
nothing here; any check has to run in a **later** session.

Registration therefore stays a manual step, re-run after any machine rebuild. A
mechanism that reverts silently is worse than a manual step, because it looks
like a mechanism.

## Off switch

```bash
touch "${XDG_STATE_HOME:-$HOME/.local/state}/peer-ack/off"
```

A state file, not a settings change, so `apply-settings.sh` will not fight it.
The hook checks it before doing anything else.

## The wrapper is not decorative

The hook is registered as:

```
s="$HOME/claude-guardrails/bin/peer-ack-hook.sh"; [ -x "$s" ] && bash "$s"; exit 0
```

On `UserPromptSubmit` both blocking channels erase the user's prompt outright, and
a bash **syntax error exits 2 without executing a single line**, so no discipline
inside the script protects against a bad edit to it. The trailing `exit 0` is the
only thing that holds when the file cannot run at all.

`tests/test-peer-ack.sh` proves both halves: that a syntax-broken hook really does
exit 2, and that the wrapper converts that to 0. A test that only proved the
second half would pass against a hazard that had quietly stopped existing.

## What is not preserved

The ledger itself (`~/.local/state/peer-ack/`) is per-machine runtime state and is
deliberately not version-controlled. A pending entry restored onto a fresh machine
would be a lie about a message nobody is waiting on.
