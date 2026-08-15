#!/usr/bin/env python3
"""peer-ack MCP server: delivery bookkeeping for cross-session Claude messages.

WHAT IT IS FOR
Claude Code's built-in SendMessage returns success when a message is QUEUED, not
when a peer receives it. On 2026-08-16 a message returned success, sat awaiting
the recipient terminal's approval, expired unread, and the session closed. The
sender had no way to tell that from a delivered message.

WHAT IT DELIBERATELY DOES NOT DO
It does not send anything and it does not implement a transport. Delivery stays
on the built-in tool, which keeps the recipient user's approval gate intact.
Building a channel that bypasses that gate would trade a human control for
convenience. A human approval gate is not an obstacle to route around.

It shares one ledger on disk with bin/peer-ack.sh, so the shell path and the MCP
path cannot disagree: same files, same rules.

RUN
    uv run --with mcp python mcp/peer-ack/server.py
Python via uv rather than Node, so the only dependency is the MCP SDK itself.
"""

import json
import os
import re
import time
from pathlib import Path

# The SDK renamed this. Newer builds expose mcp.server.MCPServer; older ones
# expose mcp.server.fastmcp.FastMCP. Both take the same .tool() decorator and
# .run(), so support whichever is installed rather than pinning a version these
# dotfiles cannot control across machines. Verified 2026-08-16 against
# mcp 2.0.0 on Python 3.14, which has MCPServer and NO fastmcp module at all.
# 2.0 was a breaking rename; do not restore the fastmcp import as the primary.
try:
    from mcp.server import MCPServer as _Server
except ImportError:  # older SDK
    from mcp.server.fastmcp import FastMCP as _Server

STATE = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "peer-ack"
PENDING = STATE / "pending"
RESOLVED = STATE / "resolved.jsonl"
STALE_SECONDS = int(os.environ.get("PEER_ACK_STALE_SECONDS", "600"))
SOCK_DIR = Path(f"/run/user/{os.getuid()}/cc-socks")

NONCE_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")

mcp = _Server("peer-ack", version="1.0.0")


def _ensure():
    PENDING.mkdir(parents=True, exist_ok=True)


def _valid(nonce: str) -> bool:
    # Nonces become filenames. Anything that could escape the directory is a
    # usage error, never something to quietly sanitise and accept.
    return bool(NONCE_RE.match(nonce or "")) and ".." not in nonce


@mcp.tool()
def record(nonce: str, to: str, summary: str = "") -> str:
    """Record that a message carrying ACK-REQ <nonce> is awaiting acknowledgement.

    Call this immediately after SendMessage returns, for any message whose
    delivery matters. Until the matching ack arrives, the message counts as
    UNDELIVERED.
    """
    _ensure()
    if not _valid(nonce):
        return f"REFUSED: {nonce!r} is not a usable nonce (A-Za-z0-9._- only, max 128)"
    if not to:
        return "REFUSED: 'to' is required"
    f = PENDING / f"{nonce}.json"
    if f.exists():
        return f"already pending: {nonce} (not overwritten)"
    f.write_text(json.dumps({
        "nonce": nonce, "to": to, "summary": summary,
        "sent_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "sent_epoch": int(time.time()),
        "session": os.environ.get("CLAUDE_SESSION_ID", ""),
    }))
    return f"recorded {nonce} -> {to}; treat as UNDELIVERED until acked"


@mcp.tool()
def ack(nonce: str) -> str:
    """Clear a pending message because the peer acknowledged it."""
    _ensure()
    if not _valid(nonce):
        return f"REFUSED: {nonce!r} is not a usable nonce"
    f = PENDING / f"{nonce}.json"
    if not f.exists():
        # Say this rather than swallowing it: either the peer invented a nonce
        # we never recorded, or our record was lost. Both are worth knowing.
        return f"no pending record for {nonce}; nothing to clear (was it ever recorded?)"
    d = json.loads(f.read_text())
    d["acked_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    d["outcome"] = "acked"
    with RESOLVED.open("a") as fh:
        fh.write(json.dumps(d) + "\n")
    f.unlink()
    return f"{nonce} acknowledged and cleared"


@mcp.tool()
def pending() -> str:
    """List messages sent but never acknowledged. Anything STALE is UNDELIVERED."""
    _ensure()
    now = int(time.time())
    rows = []
    for f in PENDING.glob("*.json"):
        try:
            d = json.loads(f.read_text())
        except Exception:
            continue
        rows.append((now - int(d.get("sent_epoch", now)), d))
    if not rows:
        return "nothing pending: every message you recorded has been acknowledged"
    rows.sort(reverse=True)
    out = [f"{len(rows)} message(s) awaiting acknowledgement:"]
    for age, d in rows:
        mark = "STALE" if age >= STALE_SECONDS else "waiting"
        out.append(f"  [{mark}] {d['nonce']}  to={d.get('to','?')}  {age//60}m ago  {d.get('summary','')}")
    if any(a >= STALE_SECONDS for a, _ in rows):
        out.append("A STALE entry has had no reply. Treat it as UNDELIVERED, not delivered,")
        out.append("and if it matters, tell the user rather than assuming the peer acted on it.")
    return "\n".join(out)


@mcp.tool()
def history(limit: int = 10) -> str:
    """Show recently acknowledged messages."""
    if not RESOLVED.exists():
        return "no history yet"
    lines = [l for l in RESOLVED.read_text().splitlines() if l.strip()][-max(1, limit):]
    out = []
    for l in lines:
        try:
            d = json.loads(l)
        except Exception:
            continue
        out.append(f"  {d.get('acked_at','?')[:19]}  {d['nonce']}  to={d.get('to','?')}  {d.get('outcome','?')}")
    return "\n".join(out) or "no history yet"


@mcp.tool()
def peers() -> str:
    """List live peer sessions by their transport socket.

    This reports what is ON DISK, which is not the same as what can be reached:
    a socket can exist while its session refuses or never approves a message.
    Use ListAgents for names. This is for correlating a delivery failure with a
    session that has since gone, which is exactly how the 2026-08-16 expiry was
    identified after the fact.
    """
    if not SOCK_DIR.is_dir():
        return f"no socket dir at {SOCK_DIR}"
    socks = sorted(SOCK_DIR.glob("*.sock"))
    if not socks:
        return f"{SOCK_DIR} exists but holds no sockets"
    out = [f"{len(socks)} session socket(s) in {SOCK_DIR}:"]
    for s in socks:
        pid = s.stem
        alive = Path(f"/proc/{pid}").exists()
        out.append(f"  {s.name}  pid={pid}  process={'alive' if alive else 'GONE'}")
    return "\n".join(out)


if __name__ == "__main__":
    mcp.run()
