---
description: Generic end-of-session protocol. Detects stack (Node, Python, Go, Rust, Hugo, Vite) from disk, runs the right tests, audits TODO/CLAUDE.md/.gitignore/README, offers a code review, commits clean, pushes, then sweeps every other local branch for unpushed commits and prompts to push them too. Projects extend it with a .claude/session-end-extra.md extension file, executed first when present.
disable-model-invocation: true
---

You are ending this Claude Code session. Execute the steps IN ORDER. Do not skip. Do not parallelise: each step's output informs the next.

This command lives in user scope and runs in every project. It detects the stack from disk before acting. Do NOT create a project command with this same name: user-scope commands shadow project-scope ones (personal > project precedence, confirmed empirically), so a same-name project override never loads. Projects tailor this protocol through the extension hook in Step -1 instead.

Write user-facing output in Australian English (organise, colour, analyse, defence). Do not use em-dashes or en-dashes anywhere (colons, commas, parentheses, or two sentences instead). Every non-trivial claim this command surfaces to the user should carry a VERIFIED / LIKELY / GUESSING confidence label.

## Step -1: Project extension hook (compulsory, runs before everything else)

Check for a project extension file at the repo root:

```bash
cd "$(git rev-parse --show-toplevel)" && ls .claude/session-end-extra.md 2>/dev/null && echo "EXTENSION PRESENT" || echo "no extension; proceed to Step 0"
```

- **Absent:** proceed straight to Step 0. Do not mention the hook again.
- **Present:** Read the file and execute its instructions IN FULL before Step 0. The
  extension adds project-specific steps in front of this protocol; it removes nothing
  from it. Honour the extension's own failure semantics: if it declares a compulsory
  check and that check fails or cannot run, that is a STOP per the extension's wording,
  and you do not continue to this protocol's commit and push steps until resolved. A
  skipped extension check must never be reported as a pass. Carry each extension step's
  outcome into the Step 12 final summary with a confidence label.

Why this hook exists: the previous mechanism (a project-level `.claude/commands/session-end.md`) never loads because of command-scope precedence, and two sessions ran without their compulsory freshness checks before the shadowing was proven. An extension file read by the generic command cannot be shadowed.

## Step 0: Detect stack and build the session baseline

Run this block first. Every later step reads from `/tmp/session-end-baseline-<repo>.txt` (repo-unique so concurrent sessions in different repos cannot clobber each other; `<repo>` is `$(basename "$REPO")`) and the detected variables.

```bash
bash -c '
set -u
REPO=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "NOT A GIT REPO: /session-end requires git. Aborting."; exit 1; }
cd "$REPO"
SLUG=$(basename "$REPO")   # repo-unique suffix so concurrent sessions do not clobber shared /tmp state

BRANCH=$(git branch --show-current)
if [ -z "$BRANCH" ]; then
  echo "WARN: detached HEAD. Commit and push steps will be skipped. Continue manually."
fi

# Stack detection
NODE_PM=""
[ -f package.json ] && {
  if [ -f pnpm-lock.yaml ]; then NODE_PM=pnpm
  elif [ -f yarn.lock ]; then NODE_PM=yarn
  else NODE_PM=pnpm   # pnpm-first per working-style; npm only if the repo explicitly requires it
  fi
}
PY=""
[ -f pyproject.toml ] || [ -f setup.py ] && PY="yes"
PY_RUN="python3 -m pytest"
[ -x .venv/bin/pytest ] && PY_RUN=".venv/bin/pytest"
GO=""; [ -f go.mod ] && GO="yes"
RUST=""; [ -f Cargo.toml ] && RUST="yes"
HUGO=""; { [ -f config.toml ] || [ -f config.yaml ] || [ -f hugo.toml ] || [ -f site/config.toml ] || [ -f content/site/config.toml ]; } && HUGO="yes"
VITE=""; compgen -G "vite.config.*" >/dev/null 2>&1 && VITE="yes"

echo "=== Session baseline ==="
echo "Repo:        $REPO"
echo "Branch:      ${BRANCH:-<detached>}"
echo "Node:        ${NODE_PM:-<none>}"
echo "Python:      ${PY:+yes (${PY_RUN})}"
echo "Go:          ${GO:-<none>}"
echo "Rust:        ${RUST:-<none>}"
echo "Hugo:        ${HUGO:-<none>}"
echo "Vite:        ${VITE:-<none>}"

# File classification (uncommitted + staged + committed in last 24h)
TMP=/tmp/session-end-baseline-$SLUG.txt
> "$TMP"
{
  git diff HEAD --name-only 2>/dev/null
  git diff --cached --name-only 2>/dev/null
  git log --since="24 hours ago" --name-only --pretty=format: HEAD 2>/dev/null
} | sort -u | grep -v "^$" >> "$TMP" || true

total=$(wc -l < "$TMP")
echo ""
echo "Files touched this session (24h window): $total"

# Persist the detected variables for later steps (repo-unique path)
cat > /tmp/session-end-vars-$SLUG.sh <<EOF
REPO="$REPO"
BRANCH="$BRANCH"
NODE_PM="$NODE_PM"
PY="$PY"
PY_RUN="$PY_RUN"
GO="$GO"
RUST="$RUST"
HUGO="$HUGO"
VITE="$VITE"
EOF
'
```

If the baseline shows zero files touched in 24 hours, the session may have spanned more than a day; ask the user whether they want a wider window before declaring "no changes to review". Do not override silently.

## Step 1: Offer code review (optional)

Use `AskUserQuestion`:

- Header: `Run code review?`
- Question: `This session produced changes. Run a code-reviewer agent against the diff before closing?`
- Options:
  - `Yes`: dispatch `superpowers:requesting-code-review` (or the `feature-dev:code-reviewer` agent if the skill is unavailable). Wait for completion. Report critical issues; user decides whether to fix before closing.
  - `No`: skip and proceed.

Skip the prompt entirely if the baseline shows zero files touched.

## Step 2: Audit TODO tracking

If `TODO.md` exists at repo root: read lines 1-80 (the summary). For every `[ ]` entry under "Scheduled" / "Waiting on user action" / equivalent headings, cross-check against git log and filesystem state.

- If evidence shows it is done, flip to `[x]` and add a short `DONE YYYY-MM-DD (commit <sha>)` note on the same line.
- If still pending, leave it.
- If uncertain, leave it and flag in the Step 12 summary.

Do NOT speculatively flip items you were not directly involved in this session.

If there is no `TODO.md`, skip this step and note the skip. Do not invent a TODO file.

## Step 3: Capture lessons learned in CLAUDE.md (only if worth it)

Scan the session for genuinely non-obvious items:

- Gotchas that cost time (failures, surprising behaviours)
- Constraints the code does not surface
- Workflow patterns that worked well or poorly

If any exist AND are not duplicative of existing CLAUDE.md content, append as a numbered gotcha at the end. Match the file's existing format. Do NOT renumber existing items. Do NOT pad CLAUDE.md with marginal content: each entry costs future-session reading time.

If no new lessons, skip and note the skip.

## Step 3.5: Global CLAUDE.md topic-file size audit

Read-only check. The global `~/.claude/CLAUDE.md` is a thin import index; the actual rules live in `~/.claude/instructions/`. Count only **hand-written** lines: exclude any block between `<!-- BEGIN GENERATED` and `<!-- END GENERATED -->`, because generated inventory length tracks the size of the stack, not prose verbosity, and is not a trim target. Run:

```bash
for f in ~/.claude/instructions/*.md; do
  n=$(awk '/<!-- BEGIN GENERATED/{s=1} !s{c++} /<!-- END GENERATED/{s=0} END{print c+0}' "$f")
  printf '%4d %s\n' "$n" "$f"
done | sort -rn | head -20
```

If a file exceeds **55 hand-written lines**, surface it as a trim candidate:

```
CLAUDE.md audit: <filename> is N hand-written lines; consider trimming verbose explanations to reduce per-turn token cost.
```

Two caveats before flagging, so the audit stays honest:
- `wc -l` (and this line count) measures newlines, which is only a rough proxy for token cost. A file written as long single-line paragraphs (e.g. `working-style.md`) reads as "few lines" while being genuinely token-heavy; a file of short lines reads large while being cheap. Weigh apparent length against how each file is written before calling it verbose.
- Some files are long because every line is load-bearing, not padded (e.g. `hardening.md`, where each rule carries the outage that earned it). A file that cannot shrink without losing a distinct lesson or a live inventory entry is not a trim candidate, however many lines it has. Say so and move on rather than proposing a cut that removes meaning.

List the three largest files regardless of threshold so the user has a size map. Do NOT edit any file. This is observation only.

If `~/.claude/instructions/` does not exist or is empty, skip with a one-line note.

## Step 4: .gitignore hygiene

```bash
cd "$(git rev-parse --show-toplevel)" && git status --ignored --short | head -40
```

Check for:

- Files that SHOULD be gitignored but are not: `.env`, `.env.local`, credentials, build outputs, caches, personal notes, `SSH.md`, `.venv`, `node_modules`, `dist`, `build`, `coverage`, `__pycache__`, `.DS_Store`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.vite`, `target` (Rust).
- Files ignored that should be tracked (rare).

If `.gitignore` needs updates, add patterns in the correct section. Do NOT remove existing patterns without explicit reason. Re-verify with `git status --ignored` after editing.

## Step 5: README update (only if user-facing behaviour changed)

If this session added or changed anything a first-time reader of the repo would need to know (new commands, new scripts, changed invocation, new environment variables, new infrastructure requirements), update `README.md` to reflect the current state. Keep it concise: README is a landing page, not a manual.

If the session was purely internal (refactors, internal docs, bug fixes with no user-visible change), skip.

## Step 5.5: GitHub Issues drift (skip if no baseline)

If `.github/issue-baseline.json` does NOT exist, skip this step silently. The project has not been initialised with `/setup-issues`.

Otherwise, compare the project baseline against actual repo state, and surface anything that has drifted. This catches new labels you started using, milestones referenced but missing from the VS Code trays, and untriaged issues piling up.

```bash
bash -c '
set -u
cd "$(git rev-parse --show-toplevel)"
[ -f .github/issue-baseline.json ] || { echo "(no .github/issue-baseline.json; skipping drift check)"; exit 0; }

echo "=== labels in repo not in baseline ==="
BL_LABELS=$(jq -r ".labels[].name" .github/issue-baseline.json | sort)
ACTUAL_LABELS=$(gh label list --limit 200 --json name --jq ".[].name" | sort)
comm -23 <(echo "$ACTUAL_LABELS") <(echo "$BL_LABELS") | sed "s/^/  +/" || true
[ -z "$(comm -23 <(echo "$ACTUAL_LABELS") <(echo "$BL_LABELS"))" ] && echo "  (none)"

echo ""
echo "=== labels in baseline missing from repo ==="
comm -13 <(echo "$ACTUAL_LABELS") <(echo "$BL_LABELS") | sed "s/^/  -/" || true
[ -z "$(comm -13 <(echo "$ACTUAL_LABELS") <(echo "$BL_LABELS"))" ] && echo "  (none)"

echo ""
echo "=== milestones in repo not in baseline ==="
BL_MS=$(jq -r ".milestones[].title" .github/issue-baseline.json | sort)
ACTUAL_MS=$(gh api "repos/:owner/:repo/milestones?state=all" --jq ".[].title" 2>/dev/null | sort)
comm -23 <(echo "$ACTUAL_MS") <(echo "$BL_MS") | sed "s/^/  +/" || true
[ -z "$(comm -23 <(echo "$ACTUAL_MS") <(echo "$BL_MS"))" ] && echo "  (none)"

echo ""
echo "=== milestones referenced in baseline but no VS Code tray query ==="
if [ -f .vscode/settings.json ]; then
  QUERIES=$(jq -r ".[\"githubIssues.queries\"] // [] | .[].query" .vscode/settings.json 2>/dev/null)
  echo "$BL_MS" | while read -r ms; do
    [ -z "$ms" ] && continue
    echo "$QUERIES" | grep -Fq "milestone:\"$ms\"" || echo "  ! $ms (no tray query)"
  done
else
  echo "  (.vscode/settings.json absent)"
fi

echo ""
echo "=== untriaged open issues (no milestone, not deferred) ==="
UNTRIAGED=$(gh issue list --state open --search "no:milestone -label:deferred" --json number --jq length 2>/dev/null || echo "?")
echo "  count: $UNTRIAGED"
[ "$UNTRIAGED" != "?" ] && [ "$UNTRIAGED" -gt 5 ] && echo "  (consider triaging; threshold 5)"

echo ""
echo "=== issues with legacy Phase N: title prefix ==="
LEGACY=$(gh issue list --state open --search "in:title \"Phase 2:\" OR in:title \"Phase 3:\" OR in:title \"Phase 4:\"" --json number --jq length 2>/dev/null || echo "?")
echo "  count: $LEGACY"
[ "$LEGACY" != "?" ] && [ "$LEGACY" -gt 0 ] && echo "  (the milestone field is the source of truth; consider renaming these)"
'
```

If the output shows ANY drift, surface it in the Step 12 summary as a single line: "GitHub Issues drift: N new labels, M missing trays, K untriaged. Consider editing .github/issue-baseline.json or running /setup-issues to re-sync." Do NOT auto-fix; the user decides whether to update the baseline or revert the divergence.

## Step 5.6: Open-issue review

Goal: stale open issues are a real maintenance cost across projects. This step always runs when `gh` is available, catching issues that have been actioned in this or recent sessions but never closed, plus ones drifting without activity. Surface candidates and offer to close on the user's behalf. Never auto-close without explicit confirmation.

Skip silently with a one-line note if `gh` is unavailable or the repo has zero open issues.

```bash
bash -c '
cd "$(git rev-parse --show-toplevel)"
command -v gh >/dev/null 2>&1 || { echo "(gh not available; skipping)"; exit 0; }

OPEN_COUNT=$(gh issue list --state open --json number --jq length 2>/dev/null)
[ "${OPEN_COUNT:-0}" = "0" ] && { echo "(no open issues; skipping)"; exit 0; }

echo "=== open issues sorted by oldest update (top 30) ==="
gh issue list --state open --limit 30 --json number,title,updatedAt \
  --jq "sort_by(.updatedAt) | .[] | \"  #\(.number) [\(.updatedAt[:10])] \(.title)\"" 2>/dev/null

echo ""
echo "=== commits in last 30 days referencing issues by number ==="
echo "(cross-check: any of these reference an issue still open above?)"
git log --since="30 days ago" --oneline 2>/dev/null \
  | grep -E "#[0-9]+" \
  | head -30 \
  | sed "s/^/  /" \
  || echo "  (no commit refs found)"
'
```

After the list prints, use `AskUserQuestion`:

- Header: `Close any open issues?`
- Question: `Any of the open issues above already done? Close them now and the rest go in the summary.`
- Options:
  - `Yes, list issue numbers`: prompt for space-separated numbers. For each, run `gh issue close <num> --comment "Closed during session-end: work landed in this or a recent session."`. Verify each close returned success. Carry the closed list into the Step 12 summary.
  - `No, surface in summary`: leave all open; the count goes into the Step 12 summary as "N open issues to triage later".
  - `Skip`: too many to review in-session; just record the count.

Whatever the choice, the open count (and any closed-this-session list) feeds into Step 9.5's `nextsession.md` content under "Open follow-ups" so future-you sees it on pickup.

## Step 5.7: Open-PR sweep

Goal: catch PRs the user authored that were opened in this or a recent session and never landed. The "shipped feature, ran out of time before merge" failure mode produces stale branches, divergent main, and forgotten work. Surface every open PR in the current repo authored by `@me` and decide its fate per PR.

Skip silently with a one-line note if `gh` is unavailable or there are no open PRs the user authored.

```bash
bash -c '
cd "$(git rev-parse --show-toplevel)"
command -v gh >/dev/null 2>&1 || { echo "(gh not available; skipping)"; exit 0; }

OPEN_PR_COUNT=$(gh pr list --author @me --state open --json number --jq length 2>/dev/null)
[ "${OPEN_PR_COUNT:-0}" = "0" ] && { echo "(no open PRs you authored; skipping)"; exit 0; }

echo "=== open PRs (yours) sorted by oldest first ==="
gh pr list --author @me --state open --limit 30 --json number,title,mergeable,headRefName,createdAt \
  --jq "sort_by(.createdAt) | .[] | \"  #\(.number) [\(.mergeable)] (\(.headRefName)) -- \(.title)\"" 2>/dev/null
'
```

If the list is empty, skip.

For each PR in the list, use `AskUserQuestion` with one question per PR (single-select):

- Header: `PR #<n>`
- Question: `Open PR #<n> (<short title>): what would you like to do?`
- Options:
  - `Merge`: `gh pr merge <n> --merge --delete-branch` (regular merge commit, never `--squash`: preserves individual commit history per global working-style). If `mergeable=UNKNOWN` (GitHub still calculating), add `--auto` so it queues. If `mergeable=CONFLICTING`, do not merge: leave open and flag for rebase in the summary.
  - `Leave open`: take no action. The PR number goes into the Step 9.5 baton's "Open follow-ups" list so future-you remembers it.
  - `Close (without merging)`: confirm intent first; closing discards the work. On confirmation, `gh pr close <n> --delete-branch`.

Stale-PR warning: if a PR's `createdAt` is older than the most recent main commit's authored date, surface a one-line caution before the question:

> ⚠ This PR was opened before recent merges to main; merging blindly may revert other changes. Consider rebasing first.

Lesson: GitHub's `MERGEABLE` status is semantic-merge-clean, not "this PR is still doing what it set out to do." Rebase before merging when in doubt.

After the sweep, if anything was merged, the workflow on `push: branches: [main]` (or equivalent) will fire a deploy. Note the run id (or absence of a deploy workflow) in the Step 12 summary so the next session-pickup can verify post-deploy state.

## Step 6: In-flight subagent check

Before running tests, verify no background subagents are still modifying files. A half-modified tree produces unreliable test results.

- If `TaskList` or an equivalent tool is available, enumerate running tasks.
- Otherwise inspect `/tmp/claude-*/tasks/*.output` freshness: any file modified within the last 60 seconds suggests an active subagent.

If ANY subagent is still running: STOP. Tell the user to wait. Do NOT proceed to Step 7.

## Step 7: Run the test suite (compulsory)

Use the detected stack. Load the vars first:

```bash
source /tmp/session-end-vars-$(basename "$(git rev-parse --show-toplevel)").sh
```

Pick the command:

| Stack           | Command                                         |
|-----------------|-------------------------------------------------|
| Node            | `$NODE_PM test` (respects repo's test script)   |
| Python          | `$PY_RUN tests/ -q` (uses `.venv` if present)   |
| Go              | `go test ./...`                                 |
| Rust            | `cargo test`                                    |
| None recognised | Skip with a note. Do NOT treat as failure.      |

- If ANY test fails: STOP. Report details. Do NOT proceed. Fix and re-run `/session-end`.
- If all pass: note the count and runtime for the Step 12 summary.
- If the suite is skipped (no setup): note in the summary.

This step is compulsory and not user-gated.

## Step 8: Offer stack-specific build verification (conditional)

Only ask if source files matching the detected build tool changed this session (check `/tmp/session-end-baseline-$(basename "$REPO").txt`):

| Tool  | Build command      | Triggering paths                                 |
|-------|--------------------|--------------------------------------------------|
| Hugo  | `hugo --minify`    | `content/**`, `layouts/**`, `assets/**`, `site/**`|
| Vite  | `$NODE_PM run build` | `src/**`, `vite.config.*`, `public/**`          |
| None  | Skip silently.     |                                                  |

Use `AskUserQuestion` with `Yes` / `No`. If `Yes` and the build fails, STOP and report. If warnings only, report but continue.

## Step 9: Sensitive-file guard

Before any commit, scan the staged set:

```bash
git diff --cached --name-only | grep -Ei "\\.(env|pem|key|p12|credentials|secret|token)$|(^|/)credentials\\.json$|(^|/)\\.env(\\..*)?$" || echo "OK: no suspicious filenames staged"
```

If anything matches, STOP and confirm with the user before committing. This is a hard gate.

## Step 9.5: Write `nextsession.md` (handoff baton)

This step runs BEFORE the commit so `nextsession.md` can be staged alongside the other housekeeping files in Step 10. Build the session report content here and write it to `<repo-root>/nextsession.md`. The same content gets echoed to chat in Step 12: write once, surface twice.

File path: `<repo-root>/nextsession.md`. **Overwrite** if present. This is a baton, not a journal: each session replaces the last so future-you reads the most recent handoff, not an accreting blob. Past handoffs live in git history (if committed) or are gone (if gitignored).

Content:

1. Header: `# Next session brief: <today's date DD/MM/YYYY>` and the current branch
2. Commits pushed earlier in this session (oneline log since session start if known, otherwise last 24h). Add a final line "(+ this housekeeping commit, about to land)" since Step 10 has not run yet.
3. Overall file changes touched this session (paths + counts, from `/tmp/session-end-baseline-$(basename "$REPO").txt`)
4. `[ ]` TODO items still open that were worked on this session
5. Verification results from Step 7/8: tests passed/skipped, build run/skipped/not-asked
6. Open GitHub issue count (from Step 5.6) and any issues closed during this session-end (with their numbers and titles). If the count is non-trivial (10+), include the top 3 oldest as candidates worth triaging.
7. Anything flagged as uncertain in earlier steps
8. **Suggested starting point for the next session (1-2 sentences)**: the load-bearing line; future-you reads this first

Australian English, no em-dashes, confidence labels (VERIFIED / LIKELY / GUESSING) on non-trivial claims, per the global rules at the top of this command.

**Default: commit `nextsession.md`** (Step 10 will stage it). Cross-device sync via git is the point of writing this file. If the user has explicitly added `nextsession.md` to `.gitignore` in a project, respect that: write the file but do not stage it.

## Step 10: Stage, commit, push

Run `git status`. Stage ONLY the session-end housekeeping files this command touched (TODO.md, CLAUDE.md, .gitignore, README.md, **nextsession.md** as applicable). Do NOT stage unrelated modified files: those are separate commits or in-progress work.

If nothing is staged, skip the commit and proceed to Step 11.

Commit message (conventional commits, no em-dashes):

```
chore(session-end): TODO sweep + [concrete list of changes]

- TODO.md: flipped N items with evidence (or: no changes)
- CLAUDE.md: added gotcha #X [title] (or: no new lessons)
- .gitignore: added Y pattern (or: no changes)
- README.md: updated Z section (or: no changes)
- nextsession.md: written (or: gitignored, file written but not staged)
```

Rules:

- NEVER amend a previous commit.
- NEVER skip hooks (`--no-verify`).
- NEVER force-push.

Push to the current branch's upstream. If no upstream is set, push with `-u` to `origin/$BRANCH`. If the push is rejected (parallel push landed), run `git pull --rebase`, verify no conflicts, then retry. Do NOT force-push to recover.

If `BRANCH` is empty (detached HEAD), skip the push and tell the user.

## Step 10.5: Cross-branch push sweep

The push in Step 10 only covers the current branch's housekeeping commit. Multi-branch sessions (feature work on a side branch you switched away from, stacked PRs, etc.) can leave commits stranded locally on branches that the current-branch push never touches. This step surveys every local branch with a tracked upstream and offers to push anything ahead.

Run:

```bash
git for-each-ref --format='%(refname:short)|%(upstream:short)|%(upstream:track)' refs/heads/ \
  | awk -F'|' 'NF==3 && $3 ~ /ahead/ {print}'
```

For each row, show:

- `<branch>: N commit(s) ahead of <upstream>`
- `git log --oneline <upstream>..<branch>` (one line per pending commit)

Also list (separately, **without** offering to push them) any local branches whose upstream column is empty. Those are local-only branches that need an explicit `-u` decision the user has not made yet. Mention them so future-you knows they exist; do not auto-push.

If any tracked branches are ahead, prompt via `AskUserQuestion`:

- Header: `Push other branches?`
- Question: `<N> branch(es) have unpushed commits. Push now?`
- Options: `Yes (push all)` / `Skip` / `Pick specific`

For each branch the user chose to push, run `git push origin <branch>` from the worktree (no checkout needed: `git push` accepts a refspec directly). If a push is rejected because the upstream moved, do not auto-rebase: surface the rejection and let the user decide. Never force-push.

If a branch shows both `ahead` and `behind`, treat it as needing manual attention: list it but do not include it in `Yes (push all)`. The user must rebase or merge first.

After the sweep, record the outcome in the Step 12 final report so the chat handoff names which branches landed on origin and which were left local on purpose.

## Step 11: Offer to save session memories

End-of-session is when future-you needs cues that are not in code, CLAUDE.md, or commit history.

Use `AskUserQuestion`:

- Header: `Save session memories?`
- Question: `Save any learnings from this session to memory?`
- Options: `Yes` (review and write 1-3 memory files) / `No` (skip).

Good candidates if Yes:

- User preferences observed (not already recorded)
- New gotchas (not duplicating existing memories)
- Project-state decisions with non-obvious motivation
- External-system references (dashboards, issue trackers, Slack channels)

Skip if nothing surprised you. Writing forgettable memories is worse than writing none.

## Step 12: Final summary

Echo the contents of `nextsession.md` (written in Step 9.5) to chat verbatim, plus a one-line preamble naming the file path so future-you knows where it lives. The file is the durable handoff baton; this chat output is for the current user.

If, in this session-end run, you committed `nextsession.md` in Step 10, append a single line: `Committed at <short-sha>.` Otherwise (gitignored or no commit happened) note that explicitly.

Keep it terse. The user wants: "is the session cleanly closed, and what should I look at next time?"

## Guardrails (apply to every step above)

- NEVER force-push without an explicit user request.
- NEVER skip hooks (`--no-verify`) without an explicit user request.
- NEVER amend a previous commit during session-end: always a new commit.
- NEVER delete or archive files as part of session-end: that is a real change and belongs in its own commit.
- NEVER run long pipelines (content generation, fact-check, deploys) as part of session-end: if something needs running, tell the user and let them decide.
- If ANY step fails or produces unexpected output, STOP and report. Do NOT auto-recover past uncertain state.
- Every claim made in the final summary carries a VERIFIED / LIKELY / GUESSING confidence label, per the Five Laws in global CLAUDE.md.
