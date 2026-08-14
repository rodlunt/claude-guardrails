#!/usr/bin/env bash
#
# check-setup.sh
#
# Diagnoses (does NOT auto-fix) whether user-scope Claude commands shipped
# from this dotfiles repo are correctly symlinked into ~/.claude/commands/.
#
# Usage:
#   chmod +x ~/claude-guardrails/bin/check-setup.sh
#   ~/claude-guardrails/bin/check-setup.sh
#
# Exits 0 if every expected command file is correctly linked and the dotfiles
# repo is clean; non-zero otherwise. Read-only: only reports and suggests
# copy-paste fix commands.
#
# Intended for laptop / new-machine triage after a `git clone` + `stow` run.

set -u

DOTFILES_DIR="${HOME}/claude-guardrails"
COMMANDS_SRC="${DOTFILES_DIR}/claude-commands/.claude/commands"
COMMANDS_DST="${HOME}/.claude/commands"

EXIT_CODE=0
ROWS=()

note_problem() {
  EXIT_CODE=1
}

# Step 1: dotfiles repo presence and git status.
echo "Claude dotfiles setup check"
echo "==========================="
echo

if [ ! -d "${DOTFILES_DIR}" ]; then
  echo "FAIL: ${DOTFILES_DIR} does not exist."
  echo "  Suggested: git clone git@github.com:rodlunt/claude-guardrails.git ${DOTFILES_DIR}"
  exit 1
fi

if [ ! -d "${DOTFILES_DIR}/.git" ]; then
  echo "FAIL: ${DOTFILES_DIR} exists but is not a git repository."
  echo "  Suggested: rm -rf ${DOTFILES_DIR} && git clone git@github.com:rodlunt/claude-guardrails.git ${DOTFILES_DIR}"
  exit 1
fi

echo "Dotfiles repo: ${DOTFILES_DIR}"

# Run git fetch to learn ahead/behind state. Network failure is non-fatal.
if ! git -C "${DOTFILES_DIR}" fetch --quiet origin 2>/dev/null; then
  echo "  WARN: git fetch failed (offline?). Ahead/behind status may be stale."
fi

WORKING_TREE_STATE="$(git -C "${DOTFILES_DIR}" status --porcelain)"
if [ -n "${WORKING_TREE_STATE}" ]; then
  echo "  WARN: working tree is not clean."
  echo "        Run: git -C ${DOTFILES_DIR} status"
  note_problem
else
  echo "  OK: working tree clean."
fi

# Branch + ahead/behind vs origin/main.
CURRENT_BRANCH="$(git -C "${DOTFILES_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
echo "  Branch: ${CURRENT_BRANCH}"

if git -C "${DOTFILES_DIR}" rev-parse --verify --quiet origin/main >/dev/null; then
  AHEAD="$(git -C "${DOTFILES_DIR}" rev-list --count origin/main..HEAD 2>/dev/null || echo "?")"
  BEHIND="$(git -C "${DOTFILES_DIR}" rev-list --count HEAD..origin/main 2>/dev/null || echo "?")"
  echo "  vs origin/main: ${AHEAD} ahead, ${BEHIND} behind."
  if [ "${BEHIND}" != "0" ] && [ "${BEHIND}" != "?" ]; then
    echo "    Suggested: git -C ${DOTFILES_DIR} pull --ff-only"
    note_problem
  fi
else
  echo "  WARN: origin/main not found locally. Has the remote been fetched at least once?"
fi

echo

# Step 2: check ~/.claude/commands/ exists.
echo "User-scope commands directory: ${COMMANDS_DST}"
if [ ! -d "${COMMANDS_DST}" ]; then
  echo "  FAIL: directory does not exist."
  echo "  Suggested: mkdir -p ${COMMANDS_DST}"
  echo "             then re-run stow: cd ${DOTFILES_DIR} && stow --target=\$HOME claude-commands"
  exit 1
fi
echo "  OK: directory exists."
echo

# Step 3: source dir presence.
if [ ! -d "${COMMANDS_SRC}" ]; then
  echo "FAIL: source directory missing: ${COMMANDS_SRC}"
  echo "  This dotfiles checkout is incomplete. Suggested: git -C ${DOTFILES_DIR} status; git -C ${DOTFILES_DIR} pull --ff-only"
  exit 1
fi

# Step 4: enumerate expected command files and check each.
echo "Per-command status"
echo "------------------"

# Use find with -print0 to be safe around odd characters; pipe via while-read.
# Bash supports null delimiters; we avoid mapfile / readarray as agreed.
while IFS= read -r -d '' SRC_FILE; do
  NAME="$(basename "${SRC_FILE}")"
  DST_FILE="${COMMANDS_DST}/${NAME}"
  STATUS=""
  FIX=""

  if [ ! -e "${DST_FILE}" ] && [ ! -L "${DST_FILE}" ]; then
    STATUS="MISSING"
    FIX="cd ${DOTFILES_DIR} && stow --target=\$HOME claude-commands"
    note_problem
  elif [ -L "${DST_FILE}" ]; then
    # It's a symlink; check whether it resolves and where it points.
    if [ ! -e "${DST_FILE}" ]; then
      STATUS="DANGLING"
      FIX="rm ${DST_FILE} && cd ${DOTFILES_DIR} && stow --target=\$HOME claude-commands"
      note_problem
    else
      # Resolve both sides to canonical absolute paths.
      RESOLVED_DST="$(realpath "${DST_FILE}" 2>/dev/null || echo "")"
      RESOLVED_SRC="$(realpath "${SRC_FILE}" 2>/dev/null || echo "")"
      if [ "${RESOLVED_DST}" = "${RESOLVED_SRC}" ]; then
        STATUS="OK"
        FIX=""
      else
        STATUS="WRONG_TARGET"
        FIX="rm ${DST_FILE} && cd ${DOTFILES_DIR} && stow --target=\$HOME --restow claude-commands"
        note_problem
      fi
    fi
  else
    # Exists but is not a symlink, so it's a regular file (or dir). Stow won't
    # overwrite this; updates from the dotfiles repo will silently miss it.
    STATUS="NOT_SYMLINK"
    FIX="rm ${DST_FILE} && cd ${DOTFILES_DIR} && stow --target=\$HOME claude-commands"
    note_problem
  fi

  ROWS+=("${NAME}|${STATUS}|${FIX}")
done < <(find "${COMMANDS_SRC}" -maxdepth 1 -type f -name '*.md' -print0)

# Also catch dangling symlinks in DST that have no corresponding source file
# (most common case: stale name after a rename, e.g. a leftover
# session-end-generic.md symlink after the source was renamed to session-end.md).
while IFS= read -r -d '' DST_FILE; do
  NAME="$(basename "${DST_FILE}")"
  SRC_FILE="${COMMANDS_SRC}/${NAME}"
  # Skip if we already have a row for this name from the SRC walk.
  ALREADY=""
  for ROW in "${ROWS[@]}"; do
    [ "${ROW%%|*}" = "${NAME}" ] && ALREADY="yes" && break
  done
  [ -n "${ALREADY}" ] && continue

  if [ -L "${DST_FILE}" ] && [ ! -e "${DST_FILE}" ]; then
    ROWS+=("${NAME}|DANGLING|rm ${DST_FILE}  # stale symlink, source has been removed or renamed")
    note_problem
  elif [ -L "${DST_FILE}" ] && [ ! -f "${SRC_FILE}" ]; then
    # Symlink resolves, but to something outside the expected source tree.
    ROWS+=("${NAME}|WRONG_TARGET|rm ${DST_FILE}  # points outside ${COMMANDS_SRC}")
    note_problem
  fi
done < <(find "${COMMANDS_DST}" -maxdepth 1 -name '*.md' -print0 2>/dev/null)

# Step 5: collision check between ~/.claude/commands/ and ~/.claude/skills/.
# Claude Code reads slash commands from BOTH directories. A name that exists in
# both is a real bug: resolution order is undefined and may flip between
# Claude Code releases. We caught this on a laptop where /next-session loaded
# stale baton-writing content from skills/ instead of the symlinked commands/
# version. Whichever side wins, the other is silently shadowed.
SKILLS_DIR="${HOME}/.claude/skills"
echo
echo "Name collision check (commands/ vs skills/)"
echo "-------------------------------------------"
COLLISION_COUNT=0

if [ ! -d "${SKILLS_DIR}" ]; then
  echo "  ${SKILLS_DIR} does not exist; nothing to compare."
else
  # Glob, not find: under some sandboxes (Flatpak Claude Code on Bazzite
  # observed) find /home/.../.claude/skills returns only the parent path and
  # silently drops children, so -type d -print0 produces no records. Shell
  # glob expansion sees the children correctly.
  shopt -s nullglob
  for SKILL_PATH in "${SKILLS_DIR}"/*/; do
    SKILL_PATH="${SKILL_PATH%/}"
    SKILL_NAME="$(basename "${SKILL_PATH}")"
    CMD_PATH="${COMMANDS_DST}/${SKILL_NAME}.md"
    if [ -e "${CMD_PATH}" ] || [ -L "${CMD_PATH}" ]; then
      echo "  COLLISION: '${SKILL_NAME}' exists in both:"
      echo "    ${SKILL_PATH}"
      echo "    ${CMD_PATH}"
      echo "    Suggested fix (keeps the commands/ entry, removes the skills/ entry):"
      echo "    rm -rf ${SKILL_PATH}"
      COLLISION_COUNT=$((COLLISION_COUNT + 1))
      note_problem
    fi
  done
  shopt -u nullglob

  if [ "${COLLISION_COUNT}" -eq 0 ]; then
    echo "  OK: no name collisions between commands/ and skills/."
  fi
fi

# Step 5.5: per-skill symlink status (issue #15).
#
# Same silent-failure shape as the CLAUDE.md gap that motivated issue #1: a skill
# that is missing, dangling, or shadowed by a real directory simply never loads.
# Nothing errors, and before this step the script cheerfully printed "All checks
# passed" over it.
#
# Real directories in ~/.claude/skills that this repo does not ship are listed
# separately and are NOT failures: hand-installed skills are legitimate. Only the
# stow-managed ones are held to the symlink contract.
SKILLS_SRC="${DOTFILES_DIR}/claude-coding/.claude/skills"
SKILL_ROWS=()
echo
echo "Per-skill status (managed by claude-coding)"
echo "-------------------------------------------"

if [ ! -d "${SKILLS_SRC}" ]; then
  echo "  WARN: source directory missing: ${SKILLS_SRC}"
  echo "        This checkout is incomplete. Suggested: git -C ${DOTFILES_DIR} pull --ff-only"
  note_problem
else
  # Glob rather than find, for the same Flatpak/sandbox reason documented in the
  # collision check above.
  shopt -s nullglob
  for SRC_SKILL in "${SKILLS_SRC}"/*/; do
    SRC_SKILL="${SRC_SKILL%/}"
    NAME="$(basename "${SRC_SKILL}")"
    DST_SKILL="${SKILLS_DIR}/${NAME}"
    STATUS=""
    FIX=""

    if [ ! -e "${DST_SKILL}" ] && [ ! -L "${DST_SKILL}" ]; then
      STATUS="MISSING"
      FIX="cd ${DOTFILES_DIR} && stow --target=\$HOME claude-coding"
      note_problem
    elif [ -L "${DST_SKILL}" ]; then
      if [ ! -e "${DST_SKILL}" ]; then
        STATUS="DANGLING"
        FIX="rm ${DST_SKILL} && cd ${DOTFILES_DIR} && stow --target=\$HOME claude-coding"
        note_problem
      else
        RESOLVED_DST="$(realpath "${DST_SKILL}" 2>/dev/null || echo "")"
        RESOLVED_SRC="$(realpath "${SRC_SKILL}" 2>/dev/null || echo "")"
        if [ "${RESOLVED_DST}" = "${RESOLVED_SRC}" ]; then
          STATUS="OK"
        else
          STATUS="WRONG_TARGET"
          FIX="rm ${DST_SKILL} && cd ${DOTFILES_DIR} && stow --target=\$HOME --restow claude-coding"
          note_problem
        fi
      fi
    else
      # A real directory is shadowing the managed skill. Stow will not overwrite
      # it, so every future update to this skill silently misses the machine.
      STATUS="NOT_SYMLINK"
      FIX="rm -rf ${DST_SKILL} && cd ${DOTFILES_DIR} && stow --target=\$HOME claude-coding"
      note_problem
    fi

    SKILL_ROWS+=("${NAME}|${STATUS}|${FIX}")
  done
  shopt -u nullglob

  printf "%-32s  %-13s  %s\n" "SKILL" "STATUS" "SUGGESTED FIX"
  printf "%-32s  %-13s  %s\n" "--------------------------------" "-------------" "-----------------------------------"
  for ROW in "${SKILL_ROWS[@]}"; do
    NAME="${ROW%%|*}"
    REST="${ROW#*|}"
    STATUS="${REST%%|*}"
    FIX="${REST#*|}"
    printf "%-32s  %-13s  %s\n" "${NAME}" "${STATUS}" "${FIX:-(none)}"
  done

  # Informational only: skills present on this machine that this repo does not
  # manage. Not a failure, but worth seeing, because a managed skill replaced by
  # a real directory would otherwise be indistinguishable from these.
  UNMANAGED=()
  shopt -s nullglob
  for DST_SKILL in "${SKILLS_DIR}"/*/; do
    DST_SKILL="${DST_SKILL%/}"
    NAME="$(basename "${DST_SKILL}")"
    [ -d "${SKILLS_SRC}/${NAME}" ] && continue
    [ -L "${DST_SKILL}" ] || UNMANAGED+=("${NAME}")
  done
  shopt -u nullglob
  if [ "${#UNMANAGED[@]}" -gt 0 ]; then
    echo
    echo "  Unmanaged skills on this machine (informational, not a failure): ${#UNMANAGED[@]}"
    printf '    %s\n' "${UNMANAGED[@]}"
  fi
fi

# Step 6: summary table.
# Columns sized for typical command names (under 32 chars).
printf "\n%-32s  %-13s  %s\n" "COMMAND" "STATUS" "SUGGESTED FIX"
printf "%-32s  %-13s  %s\n" "--------------------------------" "-------------" "-----------------------------------"
for ROW in "${ROWS[@]}"; do
  NAME="${ROW%%|*}"
  REST="${ROW#*|}"
  STATUS="${REST%%|*}"
  FIX="${REST#*|}"
  printf "%-32s  %-13s  %s\n" "${NAME}" "${STATUS}" "${FIX:-(none)}"
done

# Step 7: CLAUDE.md symlink status.
# Without ~/.claude/CLAUDE.md symlinked to the dotfiles copy, the Five Laws and
# global instructions in claude-core are DORMANT: Claude Code reads only the
# user-scope ~/.claude/CLAUDE.md, never anywhere in the dotfiles tree. A missing
# or wrong-target symlink is a silent failure — everything looks fine, but the
# instructions never load. (Salvaged 2026-07-18 from an abandoned 2026-04-30
# agent branch that had diverged too far to merge.)
CLAUDEMD_SRC="${DOTFILES_DIR}/claude-core/.claude/CLAUDE.md"
CLAUDEMD_DST="${HOME}/.claude/CLAUDE.md"
echo
echo "Per-CLAUDE.md status"
echo "--------------------"
printf "%-32s  %-13s  %s\n" "FILE" "STATUS" "SUGGESTED FIX"
printf "%-32s  %-13s  %s\n" "--------------------------------" "-------------" "-----------------------------------"
CLAUDEMD_STATUS=""
CLAUDEMD_FIX=""
if [ ! -e "${CLAUDEMD_DST}" ] && [ ! -L "${CLAUDEMD_DST}" ]; then
  CLAUDEMD_STATUS="MISSING"
  CLAUDEMD_FIX="ln -sf ${CLAUDEMD_SRC} ${CLAUDEMD_DST}"
  note_problem
elif [ -L "${CLAUDEMD_DST}" ]; then
  if [ ! -e "${CLAUDEMD_DST}" ]; then
    CLAUDEMD_STATUS="DANGLING"
    CLAUDEMD_FIX="rm ${CLAUDEMD_DST} && ln -sf ${CLAUDEMD_SRC} ${CLAUDEMD_DST}"
    note_problem
  else
    RESOLVED_DST="$(readlink -f "${CLAUDEMD_DST}" 2>/dev/null || echo "")"
    RESOLVED_SRC="$(readlink -f "${CLAUDEMD_SRC}" 2>/dev/null || echo "")"
    if [ "${RESOLVED_DST}" = "${RESOLVED_SRC}" ]; then
      CLAUDEMD_STATUS="OK"
      CLAUDEMD_FIX=""
    else
      CLAUDEMD_STATUS="WRONG_TARGET"
      CLAUDEMD_FIX="rm ${CLAUDEMD_DST} && ln -sf ${CLAUDEMD_SRC} ${CLAUDEMD_DST}"
      note_problem
    fi
  fi
else
  # Exists but is not a symlink — a regular file shadowing the dotfiles copy.
  CLAUDEMD_STATUS="NOT_SYMLINK"
  CLAUDEMD_FIX="rm ${CLAUDEMD_DST} && ln -sf ${CLAUDEMD_SRC} ${CLAUDEMD_DST}"
  note_problem
fi
printf "%-32s  %-13s  %s\n" "CLAUDE.md" "${CLAUDEMD_STATUS}" "${CLAUDEMD_FIX:-(none)}"

# Step 8: settings.json policy drift.
# settings.json is deliberately NOT stowed (Claude Code rewrites it at runtime),
# so the symlink checks above can say nothing about it. That blind spot is how
# the old tracked baseline lost its `attribution` block without anyone noticing:
# every symlink was green, and the machine was quietly stamping Co-Authored-By
# trailers onto commits. This step closes it by asking apply-settings.sh whether
# the policy keys are actually in force on THIS machine.
#
# Exit codes are load-bearing: 1 means checked-and-drifted, 2 means could-not-run.
# They are reported differently on purpose - a check that could not run must
# never be indistinguishable from one that passed (hardening.md rule 2).
POLICY_SCRIPT="${DOTFILES_DIR}/bin/apply-settings.sh"
echo
echo "Settings policy (~/.claude/settings.json)"
echo "-----------------------------------------"
if [ ! -f "${POLICY_SCRIPT}" ]; then
  echo "  FAIL: ${POLICY_SCRIPT} is missing; policy drift is NOT being checked."
  echo "  Suggested: git -C ${DOTFILES_DIR} pull --ff-only"
  note_problem
else
  POLICY_OUTPUT="$(bash "${POLICY_SCRIPT}" --check 2>&1)"
  POLICY_RC=$?
  case "${POLICY_RC}" in
    0)
      echo "  OK: policy keys are in force on this machine."
      ;;
    1)
      echo "  DRIFT: this machine is missing policy from claude-core/settings-policy.json."
      printf '%s\n' "${POLICY_OUTPUT}" | sed 's/^/    /'
      note_problem
      ;;
    *)
      echo "  COULD NOT CHECK (exit ${POLICY_RC}) - treat as unknown, NOT as pass:"
      printf '%s\n' "${POLICY_OUTPUT}" | sed 's/^/    /'
      note_problem
      ;;
  esac
fi

# Step 8.5: pnpm visible to non-interactive shells (the .bashrc-guard trap).
# The pnpm standalone installer appends its PATH block to ~/.bashrc BELOW the
# "if not running interactively, return" guard, so interactive terminals see
# pnpm while every unattended shell (Claude Code Bash calls, cron, scripts)
# does not. Bit dads-thinkpad 2026-07-26: weeks of sessions believed pnpm was
# absent and routed around it while it sat installed the whole time. A tool
# invisible from the consumer's seat is a silent failure (hardening rule 7:
# prove liveness from where the work runs, not from config).
#
# The probe deliberately scrubs the caller's environment (env -i) and resolves
# through a fresh login shell, because running this script from an interactive
# terminal would otherwise inherit a PATH that masks the trap. Machines with no
# standalone pnpm at all pass silently: absence is not the trap, and the
# family machines (addies-laptop, arias-pc) legitimately carry no toolchain.
PNPM_STANDALONE="${HOME}/.local/share/pnpm/bin/pnpm"
echo
echo "pnpm non-interactive visibility"
echo "-------------------------------"
if [ ! -x "${PNPM_STANDALONE}" ]; then
  echo "  OK: no standalone pnpm install on this machine; nothing to check."
else
  PNPM_SEEN="$(env -i HOME="${HOME}" USER="${USER:-$(id -un)}" bash -lc 'command -v pnpm' 2>/dev/null || true)"
  if [ -n "${PNPM_SEEN}" ]; then
    echo "  OK: pnpm resolves in a clean non-interactive login shell (${PNPM_SEEN})."
  else
    echo "  TRAP: pnpm is installed (${PNPM_STANDALONE}) but a clean"
    echo "        non-interactive shell cannot see it. Its PATH block is almost"
    echo "        certainly below the interactive guard in ~/.bashrc."
    echo "  Suggested: append the block to ~/.profile:"
    echo "    printf '\\nexport PNPM_HOME=\"\$HOME/.local/share/pnpm\"\\ncase \":\$PATH:\" in *\":\$PNPM_HOME/bin:\"*) ;; *) export PATH=\"\$PNPM_HOME/bin:\$PATH\" ;; esac\\n' >> ~/.profile"
    note_problem
  fi
fi

# Step 8.6: git commit identity (the personal-email leak trap).
# Commits carry whatever user.email the committing machine has configured, and
# a machine that never had the noreply address set will quietly stamp the
# personal address into permanent history. This bit a real repository: a commit
# landed carrying a personal address as author AND committer, the day after a
# history rewrite had scrubbed that very address, because one machine in the
# fleet had never been configured. Nothing surfaced it until a later sweep. Post-hoc fixes need a
# history rewrite, so this is a check-before-commit invariant, not a cleanup.
#
# Stated gap (hardening rule 8): this checks the GLOBAL identity only. A
# per-repo `git config user.email` override still wins inside that repo, and
# enumerating every clone on the machine is not worth the noise; the global
# default is what the incident machine was missing.
# Set this to YOUR GitHub noreply address, either here or in the environment:
#   export EXPECTED_GIT_EMAIL='12345678+you@users.noreply.github.com'
# Leaving it empty is deliberately NOT a pass (hardening rule 2): a check that
# was never configured must be distinguishable from one that ran and was clean.
EXPECTED_GIT_EMAIL="${EXPECTED_GIT_EMAIL:-}"
echo
echo "git commit identity (global user.email)"
echo "---------------------------------------"
if [ -z "${EXPECTED_GIT_EMAIL}" ]; then
  echo "  COULD NOT RUN: EXPECTED_GIT_EMAIL is not set, so there is nothing to"
  echo "        compare against. Set it to your GitHub noreply address:"
  echo "          export EXPECTED_GIT_EMAIL='12345678+you@users.noreply.github.com'"
  echo "        Reported as a problem rather than a pass on purpose."
  note_problem
elif ! command -v git >/dev/null 2>&1; then
  echo "  OK: no git on this machine; nothing to check."
else
  CONFIGURED_EMAIL="$(git config --global --get user.email 2>/dev/null || true)"
  if [ -z "${CONFIGURED_EMAIL}" ]; then
    echo "  TRAP: global user.email is not set. Commits from this machine will"
    echo "        carry whatever git invents or a repo-local value, and the"
    echo "        personal address is one autoconfigured client away from"
    echo "        permanent history."
    echo "  Suggested: git config --global user.email '${EXPECTED_GIT_EMAIL}'"
    note_problem
  elif [ "${CONFIGURED_EMAIL}" != "${EXPECTED_GIT_EMAIL}" ]; then
    echo "  LEAK: global user.email is '${CONFIGURED_EMAIL}', not the noreply"
    echo "        address. Every commit from this machine writes it into"
    echo "        permanent history; scrubbing later needs a history rewrite."
    echo "  Suggested: git config --global user.email '${EXPECTED_GIT_EMAIL}'"
    note_problem
  else
    echo "  OK: global user.email is the noreply address."
  fi
fi

echo
if [ "${EXIT_CODE}" -eq 0 ]; then
  echo "All checks passed."
else
  echo "One or more checks reported problems. See suggested fixes above."
fi

exit "${EXIT_CODE}"
