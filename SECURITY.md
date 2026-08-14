# Security policy

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Use GitHub's private vulnerability reporting on this repository:
**Security → Report a vulnerability**. That opens a private channel visible only to
the maintainer.

Expect an acknowledgement within a week. This is a solo-maintained project, so there is
no formal SLA beyond that.

## Scope

This repository ships shell scripts that run inside your Claude Code session, one of
them as a `PreToolUse` hook on every Bash call. Things genuinely in scope:

- A way to make `bin/guard-git-push.sh` **allow** a push it should deny, in particular
  by hiding the invocation from its parser.
- A way to make it **block** a command it should allow, since a guard that blocks
  everything is a denial of service on your own session.
- Command injection or unsafe evaluation in any script here, especially where a hook
  payload is parsed.
- Anything in these files that would exfiltrate data from a machine that installs them.

## Known and deliberate limits

These are documented rather than fixed, so please do not report them as vulnerabilities:

- **The guard constrains the assistant, not you.** Typing `git push origin HEAD` in your
  own terminal is untouched.
- **`bash -c 'git push origin HEAD'` bypasses it.** The failure mode being defended
  against is accidental, not adversarial.
- **It fails open when it cannot run.** No `jq` means the call is allowed, with a loud
  warning on stderr and in a `systemMessage`. Blocking every Bash call on a machine
  without `jq` would be worse than the bug it prevents. This is a deliberate reading of
  "fail closed by default, fail open only for a human".
- **Nothing here detects two sessions sharing one checkout.** Claude Code does not
  either. The guard is a seatbelt for one common consequence, not prevention.
