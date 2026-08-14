---
description: Set up the house best-practice DEFENCES on the current project: .gitignore, GitHub repo security defaults (Dependabot alerts + security PRs, secret scanning + push protection, no-squash + auto-delete branches, branch protection), project-scoped MCP servers, and optionally git init + a GitHub remote. Offers to chain /setup-issues (labels, milestones, issue form, VS Code trays) when a GitHub remote exists. Idempotent and safe to re-run. Codifies the house repo-security and CI defaults (plus security.md). Complements /setup (CLAUDE.md wizard); it does NOT duplicate it.
disable-model-invocation: true
---

You are applying the house best-practice DEFENCES to the project in the current directory. This is the executable form of the house new-repo checklist (repo security defaults + CI scaffold); this file is now the single home for that content, alongside the always-loaded `security.md`.

**Scope boundary (do not drift):** this command owns repo hygiene and security defences plus project MCP wiring. It does NOT generate the CLAUDE.md or choose a tech stack: that is `/setup` (the claude-workflows wizard). It does NOT reimplement the GitHub Issues setup: that is `/setup-issues`, but Step 4.6 offers to CHAIN it (run its protocol verbatim) since the user has already invoked /new-repo and a fresh repo nearly always wants the issue baseline too. Never copy setup-issues logic into this file; the chain keeps `issue-baseline.json` as the single source of truth.

**Working rules:** Australian English. No em-dashes (use a comma, colon, semicolon, parentheses, or two sentences). Label non-trivial claims VERIFIED / LIKELY / GUESSING. Every step is idempotent and safe to re-run. Confirm before any outward-facing action (creating a GitHub repo, flipping repo settings). Never write a secret into a committed file. Show the command AND its output, do not just claim success.

---

## Step 0: Detect state

```bash
bash -c '
set -u
echo "cwd: $(pwd)"
if git rev-parse --show-toplevel >/dev/null 2>&1; then
  ROOT=$(git rev-parse --show-toplevel); echo "git repo: $ROOT"
  echo "branch: $(git symbolic-ref --short HEAD 2>/dev/null || echo "(detached)")"
else
  echo "git repo: NONE (offer git init)"
fi
if command -v gh >/dev/null 2>&1; then
  FULL=$(gh repo view --json nameWithOwner,visibility,defaultBranchRef --jq "{n:.nameWithOwner,v:.visibility,b:.defaultBranchRef.name}" 2>/dev/null) \
    && echo "github remote: $FULL" || echo "github remote: NONE (offer gh repo create)"
else
  echo "gh: NOT INSTALLED: GitHub steps will be skipped"
fi
'
```

Read the output, then:
- **Not a git repo** → ask whether to `git init`. Do it only on a yes.
- **No GitHub remote** → ask whether to `gh repo create`. Default **private** (`security.md`: never public unless it is a deliberate public deliverable, and a public repo needs a licence file first; GPL-3.0 is the house default for shipped tools, chosen deliberately per repo). Confirm name + visibility before running. If the user declines a remote, skip Step 2 (the GitHub API steps) and say so.

---

## Step 1: .gitignore (secrets guard)

If the repo root has no `.gitignore`, create it with the block below. If one exists, do NOT clobber it: read it, and offer to append only the secret patterns it is missing.

```gitignore
# ── Secrets & credentials: never commit plaintext secrets ──
.env
.env.*
!.env.example
!.env.sample
*.pem
*.key
*.p12
*.pfx
id_rsa
id_rsa.*
id_ed25519
id_ed25519.*
credentials.json
*-credentials.json
service-account*.json
*.secret
# SOPS/age-encrypted secrets ARE meant to be committed, never ignore them:
!*.sops.yaml
!*.sops.json
!*.sops.env
!*.enc.*

# ── OS / editor cruft ──
.DS_Store
Thumbs.db
*.swp
*~
```

---

## Step 2: GitHub repo security defaults (needs a gh remote)

Skip this whole step if there is no GitHub remote. Otherwise resolve `OWNER/REPO` and the default branch from Step 0, then apply each default idempotently. Show each command's result.

```bash
bash -c '
set -u
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner) || { echo "no gh remote"; exit 0; }
BR=$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name)
VIS=$(gh repo view --json visibility --jq .visibility)
echo "== $REPO (default: $BR, $VIS) =="

# 1. Dependabot vulnerability alerts (204 = on)
gh api --method PUT "/repos/$REPO/vulnerability-alerts" && echo "alerts: ON"

# 2. Dependabot security-update PRs
gh api --method PUT "/repos/$REPO/automated-security-fixes" && echo "security-updates: ON"

# 3. Secret scanning + push protection (free on PUBLIC; PRIVATE needs GitHub Advanced Security)
if [ "$VIS" = "PUBLIC" ]; then
  gh api --method PATCH "/repos/$REPO" \
    -f "security_and_analysis[secret_scanning][status]=enabled" \
    -f "security_and_analysis[secret_scanning_push_protection][status]=enabled" \
    --jq ".security_and_analysis" && echo "secret-scanning + push-protection: ON"
else
  echo "secret-scanning: SKIPPED (private repo needs GHAS: enable in Settings if licensed)"
fi

# 4. Merge hygiene: no squash, keep merge + rebase, auto-delete merged branches
gh api --method PATCH "/repos/$REPO" \
  -F allow_squash_merge=false -F allow_merge_commit=true \
  -F allow_rebase_merge=true -F delete_branch_on_merge=true \
  --jq "{allow_squash_merge,allow_merge_commit,allow_rebase_merge,delete_branch_on_merge}"

# 5. Branch protection on the default branch (solo profile): block force-push + deletion,
#    do NOT require external review or status checks (impractical for a solo dev).
echo "{\"required_status_checks\":null,\"enforce_admins\":false,\"required_pull_request_reviews\":null,\"restrictions\":null,\"allow_force_pushes\":false,\"allow_deletions\":false}" \
  | gh api --method PUT "/repos/$REPO/branches/$BR/protection" --input - \
    --jq "{force_push:.allow_force_pushes.enabled,deletion:.allow_deletions.enabled}" \
  && echo "branch protection: force-push + deletion BLOCKED on $BR"
'
```

If any call fails (missing scope, GHAS-gated, archived repo returns 422), record it and continue; never abort the whole step. Note that on a **team** repo the branch-protection profile should additionally require PR review: ask if this repo has more than one committer.

**Bulk-enable across ALL owned repos** (offer only if the user asks to sweep the whole account; archived repos return 422, expected and not actionable):

```bash
gh api /user/repos --paginate --jq '.[].full_name' | grep "^${GH_OWNER:-$(gh api user --jq .login)}/" | while read repo; do
  gh api --method PUT "/repos/$repo/vulnerability-alerts"
  gh api --method PUT "/repos/$repo/automated-security-fixes"
done
```

---

## Step 3: Project MCP servers

List the MCP servers already installed on this machine, ask the user which to attach to THIS project, and wire the chosen ones at project scope (a `.mcp.json` at the repo root, which Claude Code reads for anyone who clones the repo).

```bash
claude mcp list 2>/dev/null || echo "no MCP servers installed (or claude CLI unavailable)"
```

Present the list and ask: *"Which of these should this project connect to?"* Then, for each selected server, add it at **project** scope so the config is checked in:

```bash
# Preferred: let the CLI write .mcp.json at project scope.
#   claude mcp add --scope project <name> -- <command> [args...]
# For URL/SSE servers:
#   claude mcp add --scope project --transport sse <name> <url>
```

If `claude mcp add --scope project` is unavailable in this version, hand-write `.mcp.json` at the repo root instead:

```json
{
  "mcpServers": {
    "<name>": { "command": "<cmd>", "args": ["..."], "env": { "SOME_TOKEN": "${SOME_TOKEN}" } }
  }
}
```

**Secrets guard (critical):** `.mcp.json` is committed, so it must NOT contain literal API keys or tokens. If a selected server's config carries a secret in `env`, replace the literal with an `${ENV_VAR}` reference and tell the user to put the real value in their shell env or an untracked `.env` (already covered by Step 1's `.gitignore`). If a server cannot be expressed without an inline secret, keep it at **user scope** instead of the project `.mcp.json`, and say why. Never trade the secrets-guard for convenience.

---

## Step 4: CI security scaffold (optional)

Only offer this for a project that has (or is getting) CI. House CI defaults: for a pnpm project use `pnpm/action-setup@v4`, set `"packageManager": "pnpm@X.Y.Z"` in `package.json`, install with `pnpm install --frozen-lockfile` (never `npm ci`, which silently bypasses a pnpm lockfile), and add a `pnpm audit --audit-level=high` step BEFORE build. Pin third-party actions to a commit SHA. Offer to scaffold a minimal `.github/workflows/ci.yml` only if the user wants it; otherwise point them at the fuller `/setup` flow.

---

## Step 4.6: GitHub Issues baseline (chained /setup-issues, optional)

Only offer this when a GitHub remote exists (the issues setup needs `gh` against a real repo); otherwise skip silently and leave the pointer in Step 5.

Use `AskUserQuestion`:
- Header: `Issues setup?`
- Question: `Bootstrap the standard GitHub Issues baseline now (labels, milestones, issue form, VS Code trays)? Same as running /setup-issues.`
- Options:
  - `Yes (Recommended)`: chain it.
  - `Skip`: leave it; Step 5 will point at /setup-issues.

On `Yes`: read `~/.claude/commands/setup-issues.md` and execute that protocol end-to-end exactly as written (it has its own steps, prompts, and guardrails; honour them all, including its commit-offer step). Do not paraphrase or partially apply it. On `Skip`: continue.

---

## Step 5: Report + next steps

Print a compact before/after table of what this run changed (git, .gitignore, each GitHub default, MCP servers wired, issues baseline chained or skipped). Then tell the user what this command deliberately did NOT do, and where to go for it:
- **`/setup`** (claude-workflows): interactive CLAUDE.md + tech-stack + testing wizard.
- **`/setup-issues`**: only if Step 4.6 was skipped or there was no remote; GitHub labels, milestones, issue form, and VS Code trays.

Close with any items needing manual attention (private repo secret-scanning needs GHAS, a public repo needs a licence file before going public, a server left at user scope because it carried an inline secret).
