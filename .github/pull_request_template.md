## What this changes

<!-- One or two sentences. -->

## Why

<!-- The problem it solves. If it is a guard, say what it failed to catch. -->

## How it was verified

<!-- Show the command and its output, not a claim that it works.
     If you touched bin/guard-git-push.sh, tests/test-guard-git-push.sh must pass,
     and a new behaviour needs a new case in it. -->

- [ ] `tests/test-guard-git-push.sh` passes
- [ ] `shellcheck -S warning bin/*.sh tests/*.sh` is clean
- [ ] If this changes a check, it can still tell "passed" from "could not run"
