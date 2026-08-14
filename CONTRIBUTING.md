# Contributing

Thanks for wanting to improve claude-guardrails. This is a solo-maintained repository
of one person's working practice, so the bar for merging is a little unusual: a change
has to be defensible as a *mechanism*, not just as a preference.

## The one rule that matters

**A check must be able to tell "passed" from "could not run".**

Most of what is here exists because a safety mechanism died quietly and looked exactly
like a healthy one. If you add or change a guard, a hook or a check, it has to fail in
a way somebody notices. `return true` in an error path, a swallowed exception, or a
silent no-op will not merge, however tidy the rest of the change is.

## Where things go

- **Bugs**: [open an issue](https://github.com/rodlunt/claude-guardrails/issues/new/choose).
  "The guard did not fire" is the most valuable report you can send.
- **Questions and ideas**: [Discussions](https://github.com/rodlunt/claude-guardrails/discussions).
  Raising an idea before building it protects you from writing something that will not merge.
- **Security problems**: never in public. See [SECURITY.md](SECURITY.md).

## Working on the guard

The hook has a test suite, and it is the part of this repository most worth your
scepticism:

```sh
tests/test-guard-git-push.sh          # 25 cases, exits non-zero on any failure
shellcheck -S warning bin/*.sh tests/*.sh
```

If you change matching behaviour, add a case in **both** directions. The suite already
covers the traps that bit during development: a command that merely *mentions* a push
must be allowed, and a push after a heredoc terminator must still be denied.

The harness deliberately classifies against the real hook contract:

| Result | Meaning |
|---|---|
| exit 2 | hard block, whatever was printed |
| exit 0 + `permissionDecision: deny` | denied |
| exit 0 + no output | allowed |
| anything else | crash |

That distinction is not pedantry. An early version of the guard crashed with a syntax
error and exited 2, which *blocks*, and a harness that only read stdout reported it as
"allow". The suite would have called a session-breaking bug a pass.

## Style

- Australian English.
- No em dashes or en dashes. Commas, colons, full stops or parentheses.
- Conventional commit prefixes: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`, `ci:`.
- Commit messages explain *why*, and say how the change was verified. Show output, do
  not assert success.
- Never squash-merge. Merge commits or rebase, so individual commits survive.
- **Never `git push origin HEAD` or a bare `git push`.** Name the branch. The repository
  enforces this on itself, which is a reasonable summary of the whole project.

## What will not be accepted

- Anything that makes a check quieter.
- Personal configuration: machine names, network addresses, private paths. This repository
  is a deliberately sanitised subset of a private one, and it stays that way.
- Instructions that depend on the assistant remembering to comply, where a hook could
  enforce it instead.
