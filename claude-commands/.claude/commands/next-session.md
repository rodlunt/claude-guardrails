---
description: Resume work from the previous session. Reads the nextsession.md handoff baton at the repo root, reality-checks drift (new commits, uncommitted changes), and asks which open thread to pick up. Natural pair of /session-end; run it as the first command of a session.
allowed-tools: Bash(git:*), Read, AskUserQuestion
disable-model-invocation: true
---

You are picking up where the last session left off. Read the handoff baton from the current repo, sanity-check what has drifted, and ask the user which open thread to resume.

This command lives in user scope and runs in every project. It is the natural pair of `/session-end`.

Write user-facing output in Australian English (organise, colour, analyse, defence). Do not use em-dashes or en-dashes anywhere (colons, commas, parentheses, or two sentences instead). Every non-trivial claim this command surfaces to the user should carry a VERIFIED / LIKELY / GUESSING confidence label.

## Step 0: Locate the handoff baton

The baton is a markdown file at the **current repository root**. The command is cwd-scoped on purpose: if you are in the wrong workspace, the right move is to switch workspaces, not to scan five places and pick one.

```bash
bash -c '
REPO=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "NOT A GIT REPO: /next-session requires git. cd to a project first."; exit 1; }
cd "$REPO"
if [ -f nextsession.md ]; then
  echo "FOUND: $REPO/nextsession.md"
  BATON="nextsession.md"
elif [ -f next-session.md ]; then
  echo "FOUND (legacy hyphen): $REPO/next-session.md"
  BATON="next-session.md"
else
  echo "NO BATON: no nextsession.md or next-session.md at $REPO. The previous session may not have run /session-end."
  exit 2
fi
'
```

If no baton is found, STOP. Tell the user: "No handoff baton in this repo. Either run /session-end at the end of the last session next time, or just tell me what to work on."

## Step 1: Read the baton and surface it

Read the file with the Read tool (NOT shell `cat`). Echo it to chat verbatim with a one-line preamble naming the file path. The user wants to see the same content the prior session committed; do not paraphrase or summarise.

## Step 2: Reality-check what has drifted

The baton was written at session-end time. Between then and now, you may have made manual commits, switched branches, accumulated uncommitted changes, or addressed some of the open follow-ups outside a Claude session. Surface anything that has drifted.

```bash
bash -c '
REPO=$(git rev-parse --show-toplevel) && cd "$REPO" || exit 1
BATON=nextsession.md
[ -f "$BATON" ] || BATON=next-session.md
echo "=== current branch ==="
git branch --show-current
echo "=== commits since baton was written ==="
BATON_COMMIT=$(git log -1 --format=%H -- "$BATON" 2>/dev/null)
if [ -n "$BATON_COMMIT" ]; then
  COUNT=$(git log --oneline "${BATON_COMMIT}..HEAD" 2>/dev/null | wc -l)
  if [ "$COUNT" -gt 0 ]; then
    echo "$COUNT commit(s) landed since the baton commit. Review them; some open follow-ups may already be done."
    git log --oneline "${BATON_COMMIT}..HEAD"
  else
    echo "no commits since baton; baton state is current"
  fi
else
  echo "(baton file is untracked or never committed; cannot compute drift)"
fi
echo "=== uncommitted changes ==="
git status -s | head -20
'
```

If anything looks unexpected (eg a branch the baton did not name, divergent commits, sensitive-looking uncommitted files), report it and ask whether to proceed before moving on.

## Step 3: Pick a thread

Read the baton again with attention to the **"Suggested starting point"** section and the **"Open follow-ups"** list. These are the named threads to potentially pick up.

Use `AskUserQuestion`:

- Header: `Resume thread`
- Question: short paraphrase of "What should we work on?" with options drawn from the baton.
- Options (2 to 4): the suggested starting point should be the first option (labelled `(Recommended)`), followed by 1 to 3 other named open follow-ups from the baton, then optionally `Something else` as the last option for freeform redirection.

If the baton has no clear "Suggested starting point" or no open follow-ups, ask the user freeform what they want to do.

## Step 4: Route to the right skill

Once a thread is chosen, decide how to start work on it:

| Thread shape                                    | Route                                                |
|-------------------------------------------------|------------------------------------------------------|
| Multi-step feature or refactor                  | `superpowers:brainstorming` then `superpowers:writing-plans` |
| Bug fix or test failure                         | `superpowers:systematic-debugging`                   |
| Investigation across the codebase               | dispatch a `feature-dev:code-explorer` subagent      |
| Quick targeted change with clear scope          | just do it; no formal skill                          |
| Code review or merge prep                       | `superpowers:requesting-code-review`                 |
| Worktree-isolated work                          | `superpowers:using-git-worktrees`                    |
| Named skill/subagent unavailable in this env    | do the work inline in the main thread; note the missing skill so the user knows it was not routed |

Announce the route in one sentence ("Using systematic-debugging to track down the race window flagged in the baton") and start.

## Step 5: Do NOT auto-clear the baton

Leave `nextsession.md` in place. The next `/session-end` will overwrite it. Clearing it now risks losing the baton if the session ends abruptly before completion.

## Guardrails

- NEVER assume the baton is fully accurate. It is a snapshot from a prior session; reality may have moved.
- NEVER auto-execute open follow-ups without surfacing them to the user first. The user picks the thread.
- NEVER scan multiple repos for a baton. Cwd-scoped.
- If the baton names commits or files, verify they exist before acting (paths rot, branches get deleted).
- If `git status` shows uncommitted changes that look unrelated to the baton, ask before acting on top of them. They might be the user's in-progress work.
