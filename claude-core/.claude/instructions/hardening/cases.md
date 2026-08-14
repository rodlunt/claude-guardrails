# Hardening: the cases behind the rules

Read on demand. `../hardening.md` holds the twelve rules as one-liners; this file holds the outage
each one was bought with, plus the detail that only matters when you are actually writing or
reviewing something.

**Rule numbers are cited across ~60 source files in six repos. Never renumber.** If a rule is ever
retired, leave its number in place with a note, so old citations still resolve.

## Where this came from

One night, 2026-07-14, turned up five silent failures at once. The two that best describe the
class: an **nftables rule gone for 30 hours** while every systemd unit reported `active`, and a
**content gate that returned "clean" whenever its own LLM call failed**. Neither crashed. Neither
alerted. Both looked healthy.

---

## 1. Fail closed by default. Fail open only for a human, never for a cron

Anything named gate, guard, check, verify, validate or lint must **block** when its own machinery
fails, not wave the work through.

The usual objection is real: *"a dev box where the tool isn't installed must still be able to
work."* That is true **interactively** and false **unattended**. Detect which you are in and branch
on it. Most stacks already have the predicate (a TTY check, `is_autonomous_run()`, `CI=`, an
explicit `--unattended`); if one exists, use it to decide **policy**, not just verbosity.

## 2. A skipped check must never be representable as a pass

`return True` on exception is the single most dangerous line in a codebase, because every caller
downstream now believes the check ran.

Give the failure its own value: raise, or return a tri-state (`pass` / `fail` / `could-not-run`).
If a caller cannot tell "checked and clean" from "never ran", **the check does not exist**.

## 3. Status must be derived from the work, never asserted by the wrapper

`return StepResult(status="green")` hardcoded at the end of a step is a lie the whole observability
stack then repeats: the dashboard, the digest, the log.

If the work computed a number (dead links, errors, findings), **return it**. A success signal that
cannot express failure is decoration. This is rule 2 at the wrapper rather than at the check.

## 4. Detecting a problem and proceeding anyway is the same as not detecting it

If a step classifies something as bad (dead link, failed fact-check, guardrail hit, expired cert)
and nothing blocks, alerts or records it, **delete the check**. It is costing time and buying a
false sense of coverage. Either act on the finding or stop computing it.

## 5. An alert you cannot hear is not an alert

Ship anything that means "a protection is off" at **high or urgent** priority. ntfy delivers `low`
and `min` with no sound and no banner, and that is what let a **three-day outage pass unnoticed**.
Reserve `low` for genuine progress pings.

Then **throttle**: re-nag hourly at most while a fault persists, because an alert you learn to mute
is an alert you do not have.

## 6. The alarm's own failure must be loud

`try: notify(...) except Exception: pass` means a broken notifier hides the one message that
reports the thing is hidden. Silence all the way down.

This rule is **rule 9 applied to the notifier**, and **rule 11 is its fix**. It keeps its own number
because it is the single most repeated instance of both.

## 7. Prove liveness. Never infer it from configuration

"The unit is `active`" and "the config looks right" are not evidence that work is happening.

The nft rule was gone for **30 hours** while all three units reported `active`, because `OnFailure=`
catches a unit that **crashes**, and a missing table is not a crashed unit.

Find a counter, a heartbeat, a last-success timestamp, something that **moves** when the system is
doing its job, and check that it moved.

**The trap underneath the trap:** a quiet system and a dead one look identical. If you filter a
monitor's noise down to near-zero, its own counter stops being a liveness signal and you must add a
dedicated heartbeat.

## 8. Watch the watcher, and say so when you can't

Every monitor needs something that notices when *it* stops. Prefer **piggybacking on a unit already
proven to run** over adding a new timer, which is just one more thing that can quietly stop.

Where the chain genuinely ends (nothing watches the last watcher), **write that gap down in the
README** rather than letting it be discovered at 3am. A stated gap is a risk; an unstated one is a
surprise.

## 9. A swallowed exception needs a written reason

`except Exception: pass` and a linter-silencing marker (`# noqa: BLE001`, `|| true`, `2>/dev/null`)
are fine for genuine best-effort telemetry and nothing else.

When you write one, say in a comment why the caller does not need to know. **If you cannot write
that sentence, the exception should not be swallowed.**

## 10. Beware the idiom that escapes its blast radius

"Best-effort, never fatal" is correct for a notifier and catastrophic for a gate. "Never fatal"
quietly becomes "never blocks" becomes "fails open".

When a phrase like that spreads by copy-paste, it stops being a decision and starts being a habit.
Grep for the idiom before adopting it.

## 11. Build one shared loud-failure primitive, and make everything call it

Every site that hand-rolls its own "something is broken, tell someone" gets it subtly wrong.

Observed: a module that **quoted the correct lesson in a comment and then re-shipped both halves of
the bug it was citing**. One helper, one place, used everywhere.

## 12. Never pre-write the verdict

Do not staple an interpretation to the command that gathers the data
(`cmd; echo "empty = no problem"`). When the command *fails*, its output is empty and the label
renders **"the instrument broke"** as **"I found nothing"**: opposite findings, identical output.

Print the data; interpret in a separate step. If **absence** is the finding, first fire a **control
that must appear**, or zero means nothing. Same for a search loop: never `continue` past a failed
read, because a skipped item is not an absent match.

**Instruments that have produced confidently wrong "nothing found" results:**

- a `grep` whose target phrase was line-wrapped
- `jq -e`, which exits non-zero on empty output
- a `grep` for a **log marker that had been renamed** since the code was written, returning zero for
  the busiest week on record (2026-08-10, reconstructing egress-watch alert volume: the unit logged
  `queued unallowlisted` early on and `queued new` later, so counting either alone read as silence)
- `git branch -r`, which serves **stale cached remote-tracking refs** until you `git fetch --prune`,
  so deleted branches appear to still exist (2026-08-10)

---

## Applying it

- **Writing a new check:** decide its unattended behaviour *before* writing it, and write the test
  proving a skipped check is distinguishable from a passed one. **Your own verification is not
  exempt:** a script that reports success without having run anything is the same bug in a lab coat.
- **After a silent failure bites:** fix the shape, not just the bug. Ask which rule above would have
  caught it, and whether the same shape exists elsewhere. It usually does, because these are habits,
  not accidents.
- **Reviewing code:** the grep list lives in `../hardening.md`, because it is the highest-frequency
  use and should not need a second file open.
