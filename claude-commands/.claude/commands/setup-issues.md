---
description: Bootstrap the standard GitHub Issues setup for a project (labels, Phase 2/3/4 milestones, issue form template, VS Code tray queries). Idempotent. Reads the master baseline from ~/claude-guardrails/claude-core/issue-baseline.json. Run once per project; the project is then free to diverge by editing .github/issue-baseline.json.
disable-model-invocation: true
---

You are bootstrapping the standard GitHub Issues setup for the current project. This is a one-shot setup command, but it is safe to re-run (idempotent for labels and milestones; merges for `.vscode/settings.json`).

Australian English. No em-dashes (use comma, colon, semicolon, parentheses, or two sentences). Every non-trivial claim carries a VERIFIED / LIKELY / GUESSING confidence label.

## Step 0: Verify environment and detect state

```bash
bash -c '
set -u
REPO=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "NOT A GIT REPO. cd to a project first."; exit 1; }
cd "$REPO"

# GitHub remote check
REPO_FULL=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || {
  echo "NO GITHUB REMOTE. /setup-issues requires a gh-recognised remote. Run: gh repo create or git remote add origin ..."
  exit 1
}

BASELINE_SRC="${ISSUE_BASELINE_SRC:-$HOME/claude-guardrails/claude-core/issue-baseline.json}"
TEMPLATE_SRC="$HOME/claude-guardrails/claude-core/issue-template.yml"
CONFIG_SRC="$HOME/claude-guardrails/claude-core/issue-config.yml"
[ -f "$BASELINE_SRC" ] || { echo "MASTER BASELINE MISSING: $BASELINE_SRC. Pull dotfiles."; exit 1; }
[ -f "$TEMPLATE_SRC" ] || { echo "MASTER TEMPLATE MISSING: $TEMPLATE_SRC. Pull dotfiles."; exit 1; }
[ -f "$CONFIG_SRC" ] || { echo "MASTER CONFIG MISSING: $CONFIG_SRC. Pull dotfiles."; exit 1; }

echo "=== detected state ==="
echo "Repo:           $REPO_FULL"
echo "Cwd:            $REPO"
echo "Baseline file:  $([ -f .github/issue-baseline.json ] && echo "PRESENT" || echo "absent")"
echo "Issue forms:    $([ -d .github/ISSUE_TEMPLATE ] && ls .github/ISSUE_TEMPLATE/ | tr "\n" " " || echo "absent")"
echo "VS Code:        $([ -f .vscode/settings.json ] && echo "PRESENT" || echo "absent")"
echo ""
echo "=== current labels (gh) ==="
gh label list --limit 100 --json name --jq ".[].name" | sort | tr "\n" " "
echo ""
echo "=== current milestones (gh) ==="
gh api "repos/:owner/:repo/milestones?state=all" --jq ".[].title" 2>/dev/null | tr "\n" " "
echo ""

cat > "/tmp/setup-issues-vars-$(basename "$REPO").sh" <<EOF
REPO="$REPO"
REPO_FULL="$REPO_FULL"
BASELINE_SRC="$BASELINE_SRC"
TEMPLATE_SRC="$TEMPLATE_SRC"
CONFIG_SRC="$CONFIG_SRC"
EOF
'
```

## Step 1: Decide initialise vs re-sync

If `.github/issue-baseline.json` exists already, this project has been initialised before.

Use `AskUserQuestion`:
- Header: `Already initialised`
- Question: `This project already has .github/issue-baseline.json. Re-sync from the dotfiles master?`
- Options:
  - `Re-sync`: overwrite `.github/issue-baseline.json` with the current dotfiles master, then proceed with idempotent label/milestone/template/vscode setup.
  - `Project only`: skip the baseline copy, proceed with idempotent setup using the existing project baseline.
  - `Cancel`: stop. No changes.

If `.github/issue-baseline.json` does NOT exist, copy the dotfiles master into it without prompting:

```bash
bash -c '
source "/tmp/setup-issues-vars-$(basename "$(git rev-parse --show-toplevel)").sh"
cd "$REPO"
mkdir -p .github
cp "$BASELINE_SRC" .github/issue-baseline.json
echo "WROTE: .github/issue-baseline.json"
'
```

## Step 2: Sync labels

For each label in `.github/issue-baseline.json`, ensure it exists with the right colour and description. Do NOT delete labels that are not in the baseline (the user may have added project-specific ones).

```bash
bash -c '
source "/tmp/setup-issues-vars-$(basename "$(git rev-parse --show-toplevel)").sh"
cd "$REPO"

# Counts are tallied by the summary (Step 6) from the CREATED/UPDATED/OK lines below.
# Do NOT keep shell counters here: the jq | while loop runs in a subshell, so any
# increments would be lost when it exits.
EXISTING=$(gh label list --limit 200 --json name,color,description)

jq -c ".labels[]" .github/issue-baseline.json | while read -r row; do
  NAME=$(echo "$row" | jq -r .name)
  COLOR=$(echo "$row" | jq -r .color)
  DESC=$(echo "$row" | jq -r .description)
  CUR=$(echo "$EXISTING" | jq -c --arg n "$NAME" ".[] | select(.name == \$n)")
  if [ -z "$CUR" ]; then
    gh label create "$NAME" --color "$COLOR" --description "$DESC" >/dev/null && echo "CREATED label: $NAME"
  else
    CUR_COLOR=$(echo "$CUR" | jq -r .color)
    CUR_DESC=$(echo "$CUR" | jq -r .description)
    if [ "$CUR_COLOR" != "$COLOR" ] || [ "$CUR_DESC" != "$DESC" ]; then
      gh label edit "$NAME" --color "$COLOR" --description "$DESC" >/dev/null && echo "UPDATED label: $NAME (colour or description drift)"
    else
      echo "OK label: $NAME"
    fi
  fi
done
'
```

If a label edit changes a colour the user picked deliberately, that is annoying. The baseline is the source of truth here, but flag prominent colour changes in the Step 5 summary so the user can revert.

## Step 2.5: Prune non-baseline labels (opt-in)

Sync (Step 2) only adds and updates; it never deletes. So GitHub's stock defaults (`duplicate`, `wontfix`, `invalid`, `question`, `good first issue`, `help wanted`) linger alongside the baseline set as unused noise. This step offers to remove them. **Deleting a label also strips it from any issue that uses it**, safe on a fresh repo, potentially lossy on an established one, so it is always confirmed and defaults to the conservative option.

Compute what is present but not in the baseline, and split it into "known stock defaults" vs "other" (labels the user likely added deliberately):

```bash
bash -c '
source "/tmp/setup-issues-vars-$(basename "$(git rev-parse --show-toplevel)").sh"
cd "$REPO"

STOCK=$(printf "%s\n" "duplicate" "wontfix" "invalid" "question" "good first issue" "help wanted")
gh label list --limit 200 --json name --jq ".[].name" | sort -u > /tmp/_repo_labels.$$
jq -r ".labels[].name" .github/issue-baseline.json | sort -u > /tmp/_base_labels.$$
printf "%s\n" "$STOCK" | sort -u > /tmp/_stock_labels.$$

echo "=== stock defaults present (prune candidates) ==="
comm -12 /tmp/_repo_labels.$$ /tmp/_stock_labels.$$ | sed "s/^/  /"

echo "=== other non-baseline labels (NOT auto-pruned; deliberate?) ==="
# repo labels that are neither in the baseline nor a known stock default
cat /tmp/_base_labels.$$ /tmp/_stock_labels.$$ | sort -u > /tmp/_known_labels.$$
comm -23 /tmp/_repo_labels.$$ /tmp/_known_labels.$$ | sed "s/^/  /"

rm -f /tmp/_repo_labels.$$ /tmp/_base_labels.$$ /tmp/_stock_labels.$$ /tmp/_known_labels.$$
'
```

Then `AskUserQuestion`:
- Header: `Prune labels?`
- Question: `Remove non-baseline labels so the set matches the baseline exactly?`
- Options:
  - `Prune stock defaults` (recommended): delete only the GitHub stock defaults listed above. Leaves any deliberate custom labels alone.
  - `Prune all non-baseline`: also delete the "other" labels. Use only if you are sure none are in deliberate use (each deletion strips the label from its issues).
  - `Keep all`: delete nothing.

Execute the chosen deletions (skip entirely on `Keep all`). Stock-defaults example:

```bash
bash -c '
cd "$(git rev-parse --show-toplevel)"
for L in duplicate wontfix invalid question "good first issue" "help wanted"; do
  if gh label list --limit 200 --json name --jq ".[].name" | grep -qxF "$L"; then
    gh label delete "$L" --yes && echo "DELETED label: $L"
  fi
done
'
```

For `Prune all non-baseline`, additionally delete each label from the "other" list the same way. Report the deletions in the Step 6 summary.

## Step 3: Sync milestones

Create any baseline milestones not already present. Do NOT modify existing milestones (they may have descriptions or due dates the user added).

```bash
bash -c '
source "/tmp/setup-issues-vars-$(basename "$(git rev-parse --show-toplevel)").sh"
cd "$REPO"

EXISTING=$(gh api "repos/:owner/:repo/milestones?state=all" --jq ".[].title")

jq -c ".milestones[]" .github/issue-baseline.json | while read -r row; do
  TITLE=$(echo "$row" | jq -r .title)
  DESC=$(echo "$row" | jq -r .description)
  if echo "$EXISTING" | grep -Fxq "$TITLE"; then
    echo "OK milestone: $TITLE"
  else
    gh api repos/:owner/:repo/milestones -f title="$TITLE" -f description="$DESC" -f state=open >/dev/null && echo "CREATED milestone: $TITLE"
  fi
done
'
```

## Step 4: Scaffold the issue form template + chooser config

```bash
bash -c '
source "/tmp/setup-issues-vars-$(basename "$(git rev-parse --show-toplevel)").sh"
cd "$REPO"
mkdir -p .github/ISSUE_TEMPLATE

DEST=.github/ISSUE_TEMPLATE/issue.yml
if [ -f "$DEST" ]; then
  echo "EXISTS: $DEST"
else
  cp "$TEMPLATE_SRC" "$DEST"
  echo "WROTE: $DEST"
fi

# config.yml controls the web chooser (blank_issues_enabled: false forces the form;
# the CLI still bypasses it). Additive: written only if absent.
CFG=.github/ISSUE_TEMPLATE/config.yml
if [ -f "$CFG" ]; then
  echo "EXISTS: $CFG"
else
  cp "$CONFIG_SRC" "$CFG"
  echo "WROTE: $CFG"
fi
'
```

If `$DEST` already existed, do NOT overwrite silently. Use `AskUserQuestion`:
- Header: `Overwrite issue template?`
- Question: `.github/ISSUE_TEMPLATE/issue.yml already exists. Overwrite with dotfiles master?`
- Options:
  - `Overwrite`: run `cp "$TEMPLATE_SRC" "$DEST"` (paths from the sourced vars file) to replace it with the dotfiles master.
  - `Keep existing`: leave the current file untouched.

Same rule for `config.yml`: if it already existed, mention it but do not clobber a project's deliberate chooser settings (e.g. a project that added `contact_links` or re-enabled blank issues).

## Step 5: Merge VS Code tray queries (union, not replace)

Read `vscode_queries` from the project baseline, substitute `{REPO}` with the actual `nameWithOwner`, and **merge** into `.vscode/settings.json`. Baseline queries take precedence and come first; any existing query whose label is NOT in the baseline is preserved at the end. Preserves all other settings.json keys.

```bash
bash -c '
source "/tmp/setup-issues-vars-$(basename "$(git rev-parse --show-toplevel)").sh"
cd "$REPO"
mkdir -p .vscode
[ -f .vscode/settings.json ] || echo "{}" > .vscode/settings.json

TMP=$(mktemp)
jq --arg repo "$REPO_FULL" --slurpfile bl .github/issue-baseline.json "
  (\$bl[0].vscode_queries | map({label, query: (.query | gsub(\"{REPO}\"; \$repo))})) as \$base |
  (\$base | map(.label)) as \$base_labels |
  ((.[\"githubIssues.queries\"] // []) | map(select(.label as \$l | \$base_labels | index(\$l) | not))) as \$custom |
  .[\"githubIssues.queries\"] = (\$base + \$custom)
" .vscode/settings.json > "$TMP" && mv "$TMP" .vscode/settings.json

BASE_COUNT=$(jq ".vscode_queries | length" .github/issue-baseline.json)
TOTAL_COUNT=$(jq ".[\"githubIssues.queries\"] | length" .vscode/settings.json)
PRESERVED_COUNT=$((TOTAL_COUNT - BASE_COUNT))
echo "WROTE: .vscode/settings.json githubIssues.queries ($BASE_COUNT from baseline + $PRESERVED_COUNT preserved custom = $TOTAL_COUNT total)"
'
```

Custom trays the user hand-added (eg an `area:dashboard` query) are preserved across re-runs. To make a custom tray a permanent part of the project baseline (so it survives future re-syncs from dotfiles), edit `.github/issue-baseline.json` to add it to `vscode_queries`.

## Step 5.7: Offer to commit the bootstrap files

This command writes tracked files into the working tree (`.github/issue-baseline.json`, `.github/ISSUE_TEMPLATE/issue.yml`, `.github/ISSUE_TEMPLATE/config.yml`, `.vscode/settings.json`). Offer to commit them so they are not left dangling as uncommitted changes.

Use `AskUserQuestion`:
- Header: `Commit setup files?`
- Question: `Commit the GitHub Issues bootstrap files (.github/issue-baseline.json, .github/ISSUE_TEMPLATE/*, .vscode/settings.json)?`
- Options:
  - `Yes`: commit them (see below).
  - `No`: leave them staged/unstaged for the user to handle.

If `Yes`, follow global branch discipline. For anything beyond a trivial repo, create a descriptive feature branch first (e.g. `chore/setup-issues`) and open a PR rather than committing straight to the default branch; for a solo docs-only repo a direct commit is acceptable. Stage ONLY the files this command wrote:

```bash
cd "$(git rev-parse --show-toplevel)"
git add .github/issue-baseline.json .github/ISSUE_TEMPLATE/issue.yml .github/ISSUE_TEMPLATE/config.yml .vscode/settings.json
git commit -m "chore(setup-issues): bootstrap GitHub Issues baseline"
```

Do NOT stage unrelated modified files. Never force-push. Never `--squash` the eventual PR merge (regular merge or rebase only, per global working-style).

## Step 6: Summary

Report (tally the counts from the step output, not from shell variables):
- Labels: count the `CREATED label:` / `UPDATED label:` / `OK label:` lines Step 2 printed and report as created N, updated N, skipped (already correct) N
- Labels pruned: count the `DELETED label:` lines from Step 2.5 (0 if the user chose Keep all)
- Milestones: count the `CREATED milestone:` / `OK milestone:` lines Step 3 printed and report as created N, skipped N
- Issue form + config: written / kept existing / overwritten (report `issue.yml` and `config.yml` separately)
- VS Code: queries merged (count); flag if previous custom queries were replaced
- Project baseline file: `.github/issue-baseline.json` written or kept

End with: "**Next steps:**" section listing:
1. **Label on create.** The trays are label-driven and the web form does not auto-apply labels, so give every issue a type label at creation: `gh issue create --label <type> ...`. Unlabelled issues land in the "Untriaged" tray (which `/session-end` flags). See the `conventions.labeling` note in the baseline.
2. Edit `.github/issue-baseline.json` to add project-specific labels or trays. Re-run `/setup-issues` to apply.
3. The `/session-end` command will compare actual repo state against this baseline and flag drift.
4. To migrate from the legacy `Phase N:` title prefix or `phase-N` labels, ask Claude to script the rename inline (one-shot per project).

## Guardrails

- NEVER delete labels that are not in the baseline. The user may have project-specific ones.
- NEVER modify existing milestones (could erase user-added descriptions or due dates). Only create missing ones.
- NEVER overwrite the issue form template without confirmation.
- ALWAYS merge `.vscode/settings.json`, never overwrite (preserve other keys).
- If `gh` returns an auth error, STOP and tell the user to run `gh auth login` (or `flatpak-spawn --host gh auth refresh` on Bazzite/Flatpak).
- All output in Australian English. No em-dashes. Confidence labels on summary claims.
