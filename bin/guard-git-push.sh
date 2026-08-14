#!/usr/bin/env bash
#
# guard-git-push.sh
#
# PreToolUse(Bash) hook. Refuses a `git push` that does not name the branch it
# is pushing, because on a shared checkout that form pushes whatever branch
# happens to be current at the instant it runs.
#
# WHY THIS EXISTS
#
# Bit a real repository. Two Claude Code sessions shared one checkout. Session A read `git branch --show-current`, got `main`, and a
# few tool calls later ran:
#
#     git add nextsession.md && git commit -q -m "..." && git push origin HEAD
#
# Between the read and the push, session B had switched the tree to its own
# feature branch. HEAD followed, and A's main-bound commit landed on B's branch.
# The same class of failure had already happened once before in that repo.
#
# Claude Code does NOT detect or warn about two interactive sessions sharing a
# checkout (confirmed against the docs 2026-08-14; only BACKGROUND sessions get
# an automatic worktree, interactive ones need an explicit --worktree). So the
# repo's defence was an instruction telling Claude to re-check the branch, i.e.
# a memory-dependent control. It failed exactly as written. This script is the
# mechanism that replaces it.
#
# THE RULE: name the branch. `git push origin main` pushes the local `main` ref
# no matter what is checked out, so it is immune to the switch. `git push origin
# HEAD` and a bare `git push` are not.
#
# WHY IT MATCHES THE WHOLE COMMAND RATHER THAN USING THE HOOK'S `if` KEY
#
# The obvious config is `"if": "Bash(git push *)"`. It would NOT have caught the
# incident above: permission rules match the START of the command, and that one
# began with `git add`. A guard that looks installed and never fires is worse
# than none, so the filtering happens here, over every `&&`/`||`/`;`/pipe/newline
# separated segment of the command.
#
# EXIT / OUTPUT CONTRACT (see code.claude.com/docs/en/hooks.md)
#   exit 0, no output            -> no decision, normal permission flow
#   exit 0 + permissionDecision  -> deny, with a reason shown to Claude
#   exit 2                       -> hard block (not used; the JSON form carries
#                                   a better message back to the model)
#
# FAIL-OPEN, DELIBERATELY, AND LOUDLY. hardening.md rule 1 says fail closed by
# default and open only for a human. A PreToolUse hook is the interactive case:
# if jq is missing, blocking every Bash call would brick the session on that
# machine. So a machine that cannot run the check ALLOWS the call but says so on
# stderr and in a systemMessage, which is the same shape apply-settings.sh
# --heal already uses. Silence is the one thing it must never do.

set -u

emit_allow_with_warning() {
  # systemMessage surfaces to the user; permissionDecision allow keeps the
  # normal flow. Both, so a disabled guard is visible rather than merely absent.
  printf '{"systemMessage":"guard-git-push: NOT ENFORCED (%s). git push is unguarded on this machine.","hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n' "$1"
  echo "guard-git-push: NOT ENFORCED: $1" >&2
  exit 0
}

command -v jq >/dev/null 2>&1 || emit_allow_with_warning "jq is not installed"

PAYLOAD="$(cat)" || emit_allow_with_warning "could not read hook payload"
[ -n "${PAYLOAD}" ] || emit_allow_with_warning "empty hook payload"

CMD="$(printf '%s' "${PAYLOAD}" | jq -r '.tool_input.command // empty' 2>/dev/null)" \
  || emit_allow_with_warning "hook payload was not valid JSON"

# Not a Bash command with a command string: nothing to judge, stay silent.
[ -n "${CMD}" ] || exit 0

# Strip HEREDOC BODIES before anything else. They are data, not commands, and
# the very first commit that tried to document this guard was refused by it:
# the commit message quoted `git push origin HEAD` as the example of what not to
# do, that text arrived inside a `git commit -F - <<'MSG'` body, and the body is
# part of the Bash command string. A guard that cannot tell an invocation from a
# commit message describing an invocation would make the incident undocumentable.
# The heredoc START line is kept (it is a real command), only the body is
# dropped, and scanning resumes after the terminator so a push AFTER the heredoc
# is still caught.
STRIPPED="$(printf '%s\n' "${CMD}" | awk '
  BEGIN { inhd = 0 }
  inhd == 1 {
    if ($0 ~ "^[[:space:]]*" delim "[[:space:]]*$") inhd = 0
    next
  }
  {
    line = $0
    if (match(line, /<<-?[[:space:]]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
      d = substr(line, RSTART, RLENGTH)
      sub(/^<<-?[[:space:]]*/, "", d)
      gsub(/[\047"]/, "", d)
      delim = d
      inhd = 1
    }
    print line
  }
')"

# Split into invocation segments. Anything after && || ; | or a newline is a new
# command, and only the head of a segment is an invocation, which is what stops
# `echo "git push origin HEAD"` from being read as a push.
SEGMENTS="$(printf '%s' "${STRIPPED}" | sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/;/\n/g' -e 's/|/\n/g')"

VIOLATION=""
while IFS= read -r SEG; do
  # Trim leading whitespace and a leading `sudo `.
  SEG="$(printf '%s' "${SEG}" | sed -e 's/^[[:space:]]*//' -e 's/^sudo[[:space:]]\+//')"
  [ -n "${SEG}" ] || continue

  # Is this segment a git push invocation? Allows `git -C /path push ...`.
  printf '%s' "${SEG}" | grep -qE '^git([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+push([[:space:]]|$)' || continue

  # Everything after the `push` verb.
  ARGS="$(printf '%s' "${SEG}" | sed -E 's/^git([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+push//')"

  # Drop flags and their obvious values so only positional args remain.
  POSITIONAL="$(printf '%s' "${ARGS}" \
    | tr ' \t' '\n\n' \
    | grep -v '^$' \
    | grep -v '^-' || true)"

  COUNT="$(printf '%s' "${POSITIONAL}" | grep -c . || true)"
  # grep -c on empty input returns 0 but with a non-zero exit; normalise.
  case "${COUNT}" in ''|*[!0-9]*) COUNT=0 ;; esac

  if [ "${COUNT}" -lt 2 ]; then
    # `git push`, `git push origin`, `git push -u origin` -- no refspec, so the
    # branch is whatever is checked out right now.
    VIOLATION="${SEG}"
    break
  fi

  REFSPEC="$(printf '%s' "${POSITIONAL}" | sed -n '2p')"
  case "${REFSPEC}" in
    HEAD|HEAD:*|@|@:*)
      VIOLATION="${SEG}"
      break
      ;;
  esac
done <<EOF
${SEGMENTS}
EOF

[ -n "${VIOLATION}" ] || exit 0

# The reason text lives in a QUOTED heredoc, not inline in the jq program. An
# earlier version inlined it and the apostrophe in "someone else's" closed the
# shell's single-quoted string, so the script died with a syntax error and
# exit 2. Because exit 2 BLOCKS, that broken guard did not fail open -- it
# blocked every Bash call in the session. Keep prose out of the jq program.
REASON="$(cat <<'MSG'
This pushes whatever branch is checked out at the instant it runs. On a checkout
shared with another Claude session the branch can change between your commands,
and a main-bound commit then lands on another session's feature branch. That has
happened twice in the repository this guard was written for.

Name the branch instead. `git push origin <branch>` pushes that ref no matter
what is checked out, so it is immune to the switch.

If you need the current branch, read it in the SAME command that pushes:
  B=$(git branch --show-current) && git push origin "$B"

If you have just verified the branch and genuinely mean to push HEAD, hand the
command to the user rather than working around this guard.
MSG
)"

jq -nc --arg seg "${VIOLATION}" --arg reason "${REASON}" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("guard-git-push: refusing `" + $seg + "`.\n\n" + $reason)
  }
}'
exit 0
