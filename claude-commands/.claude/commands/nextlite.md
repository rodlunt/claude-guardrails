---
description: Lightweight session close. Updates nextsession.md with a concise baton (recent commits + open follow-ups), commits and pushes it, then prompts the user to /clear. No tests, no code review, no audits. Use this for quick mid-day handoffs or when /session-end is overkill.
allowed-tools: Bash(git:*), Read, Write, AskUserQuestion
disable-model-invocation: true
---

You are doing a lightweight session handoff for the current project. Steps in order.

Write all user-facing output in Australian English (organise, colour, analyse, defence). No em-dashes or en-dashes anywhere.

## Step 1: Orient

```bash
bash -c '
REPO=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "NOT A GIT REPO"; exit 1; }
cd "$REPO"
echo "REPO=$REPO"
echo "BRANCH=$(git branch --show-current)"
echo "=== last 10 commits ==="
git log --oneline -10
echo "=== uncommitted changes ==="
git status -s | head -20
'
```

If there are uncommitted changes that look like unfinished work, surface them before proceeding. Do NOT silently commit or discard them.

## Step 2: Read the existing baton (if present)

Read `nextsession.md` at the repo root with the Read tool. If it does not exist, start fresh. The "Open follow-ups" section of the current baton is the primary input for the new one -- carry forward any items that are still open, and drop any that the commits in Step 1 show as done.

## Step 3: Write the new nextsession.md

Overwrite `<repo-root>/nextsession.md`. Keep it tight: this is a handoff note, not a report.

Content:

1. `# <repo name> Session Handoff Baton` header (repo name = `basename "$REPO"` from Step 1, e.g. `my-project`), with today's date and a 3-5 word session label (e.g. "OG cards + ESLint session")
2. `**Branch:** <current branch>` (the actual branch from Step 1, not hardcoded `main`)
3. `**Last commits this session:**` -- last 5-8 commits as oneline list with short SHAs
4. `---`
5. `## What shipped this session` -- bullet list of meaningful changes. Group by feature/fix. One or two sentences each. Skip pure chore commits unless they matter for context.
6. `---`
7. `## Open follow-ups` -- numbered list. Carry forward anything from the previous baton that is still open. Add any new items from this session. Be specific: name the issue number, file, or decision point, not just "look at X".
8. `---`
9. `## Suggested starting point` -- one or two sentences. The most valuable thing to pick up next session.

Australian English. No em-dashes. No fabricated details. If unsure whether a follow-up is still open, mark it LIKELY or GUESSING.

## Step 4: Commit and push

First, guard against committing the baton to a feature branch by accident. Work out the default branch and compare it to the current one:

```bash
cd "$(git rev-parse --show-toplevel)"
DEFAULT=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
[ -z "$DEFAULT" ] && DEFAULT=$(git rev-parse --verify --quiet main >/dev/null && echo main || echo master)
CURRENT=$(git branch --show-current)
echo "default=$DEFAULT current=$CURRENT"
```

If `CURRENT` is NOT the default branch, ask the user before committing: the baton is a repo-root file and committing it onto a feature branch mixes housekeeping into feature work. Offer two options: `Commit here anyway` (proceed with the commit below on the current branch), or `Write only, skip commit` (the file is already written from Step 3; skip the commit and push entirely, and tell the user to commit it themselves where they want it). If `CURRENT` is the default branch, proceed without asking.

When committing, stage only `nextsession.md`:

```bash
cd "$(git rev-parse --show-toplevel)" && git add nextsession.md && git commit -m "chore(session-end): update handoff baton for $(date +%Y-%m-%d) session" && B=$(git branch --show-current) && git push origin "$B"
```

The branch is read in the SAME command that pushes, deliberately. Never `git push origin HEAD` or a bare `git push` here: both push whatever is checked out at the instant they run, and on a checkout shared with another session the tree can switch between two tool calls. `bin/guard-git-push.sh` in this repository denies both forms, so the older wording could not complete this step on a machine with the hook installed.

If the push is rejected (upstream moved), run `git pull --rebase` then retry. Never force-push.

If `nextsession.md` is gitignored in this project, write the file but skip the commit. Note the skip.

## Step 5: Done

Output exactly:

```
Baton written and pushed. Run /clear to start fresh.
```

Nothing else after this line.
