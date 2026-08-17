## Hardening Against Silent Failure

The most expensive bugs here have all been the same bug: **a safety mechanism that died quietly
and looked exactly like a healthy one.** Not a crash, not an error. A green tick over a machine
that had stopped doing its job.

**The rule numbers are cited by number across dozens of source files in several
repositories.** **Never renumber them.** Each rule is one line here; the
outage that earned it lives in `hardening/cases.md`.

### When to open the cases file

| Before you... | Read |
|---|---|
| write or change a gate, guard, check, healthcheck, notifier or watchdog | `~/.claude/instructions/hardening/cases.md` |
| conclude "nothing found" from a command's empty output | rule 12's case, and fire a control first |
| claim something is running because its unit reports `active` | rule 7's case |
| decide what a check should do when its own machinery fails | rule 1's case |
| treat a passing test or selftest as evidence the thing works | rule 13's case |
| trust a guard on a repo, path or branch another session can move | rule 14's case |

A one-line rule is easier to misapply than one carrying its outage. **Recalling a rule is fine
from this page; acting on one means opening the case.** That is the trade this split makes, and
it only works if you honour it.

### The rules

1. **Fail closed by default. Fail open only for a human, never for a cron.** Detect interactive
   versus unattended and branch on it to decide **policy**, not just verbosity.
2. **A skipped check must never be representable as a pass.** Raise, or return a tri-state
   (`pass` / `fail` / `could-not-run`). Never `return True` on exception.
3. **Status must be derived from the work, never asserted by the wrapper.** If the work computed
   a number (dead links, errors, findings), return it.
4. **Detecting a problem and proceeding anyway is the same as not detecting it.** Either act on
   the finding or stop computing it.
5. **An alert you cannot hear is not an alert.** Anything meaning "a protection is off" ships at
   high or urgent, then throttles to hourly at most while the fault persists.
6. **The alarm's own failure must be loud.** This is rule 9 applied to the notifier, and rule 11
   is its fix. Print it, log it, exit non-zero, but never swallow it.
7. **Prove liveness. Never infer it from configuration.** Find something that **moves** when the
   system is doing its job, and check that it moved.
8. **Watch the watcher, and say so when you can't.** Prefer piggybacking on a unit already proven
   to run. Where the chain genuinely ends, write the gap down rather than leaving it for 3am.
9. **A swallowed exception needs a written reason.** If you cannot write the sentence explaining
   why the caller does not need to know, do not swallow it.
10. **Beware the idiom that escapes its blast radius.** "Best-effort, never fatal" is right for a
    notifier and catastrophic for a gate. Grep for the idiom before adopting it.
11. **Build one shared loud-failure primitive, and make everything call it.** One helper, one
    place, used everywhere.
12. **Never pre-write the verdict.** Print the data; interpret in a separate step. If **absence**
    is the finding, first fire a **control that must appear**, or zero means nothing.
13. **A control must fail on the broken version. Run it both ways.** A test that passes proves
    nothing until you have watched it fail against the defect it exists to catch. Build the
    fixture from something independent of the thing under test, and never let absence of output
    stand as a result: confirm the code reached the part you are testing.
14. **A guard validates an argument, not its meaning.** The name you checked resolves later,
    against state something else can move in between. Bind the check and the use into one
    operation, or the guard only proves you typed something plausible.

**Reviewing code:** grep for `except.*:\s*pass`, `return True` inside an `except`, `|| true`,
`2>/dev/null`, hardcoded `status="green"`, and `priority="low"`. Each is a question to answer,
not automatically a bug. Fuller guidance on writing a new check, and on what to do after a silent
failure bites, is in `hardening/cases.md`.

### Choosing the tool to build this with

Most silent failures happen in the **gap between** these, not inside any one of them. The
right-hand column is the point: every tool here is blind to something, and the blindness is
what bites.

| Question | Tool | Blind to |
|---|---|---|
| Is this URL still answering? | an uptime monitor | whether a cron ran, whether a gate fired, whether the answer is *correct* |
| Did this code throw? | an error tracker | anything caught and swallowed, which is every bug on this page |
| Did this unit crash? | systemd `OnFailure=` | a unit that is `active` while doing nothing |
| Is this mechanism *actually working*? | **a liveness probe you write** | nothing, but you have to write it |
| Tell me right now | a push-notification channel | it is the delivery channel, not a detector |

The fourth row keeps being skipped and is the one that matters. Every other row is an outage
somebody has actually had.
