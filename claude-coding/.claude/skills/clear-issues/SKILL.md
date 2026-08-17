---
name: clear-issues
description: Use when the user wants to triage a backlog of GitHub issues and burn down as many as possible in one session. Surveys open issues via `gh`, sorts them into buckets (close-without-code, trivial, bundleable, standalone, needs-discussion, blocked), then quizzes the user one focused question per turn to lock in scope. Defaults sequential execution; reaches for parallel subagents only when issues touch genuinely disjoint files.
---

# Clear issues

Triage a backlog of GitHub issues with the goal of moving as many as possible from open to closed in one focused session. Lean sequential by default; reach for parallel only when issues genuinely touch disjoint parts of the codebase.

## Procedure

### 1. Survey

Run `gh issue list --state open --json number,title,labels,body,createdAt,updatedAt --limit 100` to pull the full backlog. For any issue under serious consideration, also fetch comments via `gh issue view <N> --comments`. Comments often carry the actual blocker or the "actually we decided X" thread that the body never got updated for.

Sort each open issue into ONE bucket:

- **Close-without-code:** obsolete, duplicate, won't-do, or already-resolved-by-other-work.
- **Trivial:** small, contained, single-PR-sized, low risk.
- **Bundleable:** several related issues that share files or domain logic; one grouped PR closes many.
- **Standalone substantive:** real work, needs its own PR but doesn't naturally bundle.
- **Needs-discussion:** scope or design is unclear; cannot start without a decision.
- **Blocked:** depends on an external repo, decision, or vendor.

Open ages matter: an issue idle for 12+ months is more likely to be obsolete than one from last week. Surface the age in the bucket assignment.

### 2. Quiz the user, one question per turn

Do NOT propose the whole strategy upfront. Walk through the buckets in priority order, asking ONE focused question at a time. Quiz examples:

- For each Close-without-code candidate: "#42 looks obsolete (idle 14 months, mentions a feature already shipped in `f3a01b2`). Close without a PR?"
- For each Bundleable group: "#13, #18, #21 all touch the rate-limit middleware. Bundle into one PR?"
- For each Needs-discussion: "#27 needs a scope call (mentions both `auth` and `audit-log`; unclear which is in scope). Defer it or talk through it now?"
- For Trivial: skip the quiz, propose them in batch and ask "any to drop from this list?"

Skip categories the user already has a clear opinion on. The quiz is for the actual decision points, not a checklist. If the backlog is large (50+), open with: "Backlog has N open. Want to scope this session to a focused subset (the close-without-code and bundleable buckets), or full sweep?"

### 3. Propose a dispatch plan

Once buckets are agreed, present a one-screen plan:

```
Closeable without code: #N1, #N2, #N3: bulk close with `gh issue close --comment ...`
Bundle A: #M1+#M2 (same files: app/middleware/*.py, sequential PR)
Bundle B: #M3+#M4 (same files: app/templates/*, sequential PR)
Standalone: #S1, #S2, #S3 (sequential, one at a time)
Defer to backlog: #D1, #D2 (label `backlog`, comment, move on)
```

**Default to sequential.** Reach for parallel ONLY when ALL of these hold:

1. Issues touch genuinely disjoint files (overlap = race conditions on commits / merge hell).
2. The work is large enough that parallelism saves real time (small fixes are faster sequential).
3. Memory budget allows multiple agents at once. The default is NO parallel agents: run a single agent unless the user has explicitly approved running several at once.

When parallel IS warranted: use `superpowers:using-git-worktrees` to give each agent its own checkout, with strict non-overlapping file allowlists in the dispatch prompt.

### 4. Execute

For each bundle or standalone, dispatch the right subagent type. Match the issue's shape:

| Issue shape                                | Subagent / skill                                      |
|--------------------------------------------|-------------------------------------------------------|
| Bug fix, test failure                      | `superpowers:systematic-debugging`                    |
| Multi-step feature, refactor               | `superpowers:writing-plans` then `feature-dev:code-architect` |
| Cross-codebase investigation               | `feature-dev:code-explorer` (read-only)               |
| Quick targeted change with clear scope     | inline, no subagent                                   |
| Code review or merge prep                  | `superpowers:requesting-code-review`                  |

If a named skill or subagent type in the table above is not available in this environment, fall back to doing the work inline in the main thread rather than aborting: the routing is a convenience, not a hard dependency.

Every PR follows global branch discipline: a descriptive feature branch (e.g. `fix/issue-42-rate-limit`), and a regular merge or rebase only, never `--squash` (squash collapses the branch history the commits document).

Auto-link issues to PRs via PR body (`Closes #N1, closes #N2`) so merge auto-closes them. For issues closed without a PR, use `gh issue close N --comment "..."` with a brief reason.

### 5. Re-quiz between batches

After each PR lands or each batch closes, ask: "Continue with the next bundle, or pause to review?" Long burndowns benefit from check-ins. Do NOT silently chew through 10 issues: the user wants to stay in the loop, not delegate the whole sweep.

## Output format per issue worked

For each issue, surface:

- Issue number + one-line title
- Bucket assigned (and why, if ambiguous)
- Action taken (closed / PRed / deferred / left open)
- Confidence label on the close decision: **VERIFIED** (read body + comments + cross-checked against current code), **LIKELY** (read body, surface signal strong), **GUESSING** (title-only skim).

## Guardrails

- Never bulk-close without per-issue confirmation. Closing eats history; a wrong close erodes trust in the issue tracker.
- Never label an issue obsolete based on title alone. Read the comments. Old "we'll fix it" promises hide in there.
- Never run two agents on overlapping files. Use worktrees plus file allowlists, or go sequential.
- If the backlog has 50+ open issues, propose a focused subset for the session. Do not try to clear everything in one pass, because context dilution makes triage worse.
- Stale labels lie. An issue tagged `priority:high` from 2023 may be cold; use updated_at + comment recency, not labels alone.

## When the right move is to NOT clear

Some backlogs accumulate because the issues are real but no one has bandwidth. Clearing them by closing-as-wontfix without honesty erodes the project. If most of the backlog falls in `Needs-discussion` or `Standalone substantive`, surface that to the user: "This is a capacity problem, not a triage problem. Do you want to mark the bottom N as `parking-lot` and move on, or is there a different lever?"
