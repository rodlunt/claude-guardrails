## Environment

- **Assume memory-constrained for parallel agents unless the machine's local settings indicate otherwise.** Default to inline sequential execution over parallel subagents unless the task genuinely benefits from parallelism. When dispatching parallel agents, strict non-overlapping file allowlists are required. (A machine with headroom can relax this via its own `settings.local.json` or project CLAUDE.md; this file states the safe default, not a universal hardware fact.)
- **Terminal paste from chat is unreliable.** Multi-line commands pasted from Claude Code output into the terminal frequently mangle. Run commands directly via Bash tool when on the same machine instead of handing them to the user to paste.
- **Per-machine specifics belong in project CLAUDE.md or `~/.claude/settings.local.json`,** never here. This file applies to every machine this dotfiles repo is stowed on.
