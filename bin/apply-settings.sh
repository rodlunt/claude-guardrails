#!/usr/bin/env bash
#
# apply-settings.sh
#
# Merges the policy keys in claude-core/settings-policy.json into this machine's
# live ~/.claude/settings.json.
#
# Usage:
#   bash ~/claude-guardrails/bin/apply-settings.sh            # apply (writes)
#   bash ~/claude-guardrails/bin/apply-settings.sh --check    # report only, exit 1 on drift
#   bash ~/claude-guardrails/bin/apply-settings.sh --diff     # show what would change, no write
#
# WHY THIS EXISTS
#
# settings.json is deliberately not stowed: Claude Code rewrites it at runtime,
# so a symlink into this repo would be clobbered or written through. The repo
# used to carry a full copy as a "shared baseline" for humans to consult. That
# baseline rotted silently and unobservably - by 2026-07-21 it was missing the
# `attribution` block entirely while still enabling 15 plugins that had long
# since been uninstalled. A new machine bootstrapped from it would have quietly
# re-added `Co-Authored-By: Claude` trailers to every commit, in direct breach
# of working-style.md, with nothing anywhere reporting a problem.
#
# That is the exact failure shape hardening.md exists to prevent: a protection
# that is off while everything looks healthy. A reference file a human is
# supposed to copy by hand is not a mechanism. This script is the mechanism, and
# --check (wired into check-setup.sh) is the liveness probe that proves it ran.
#
# EXIT CODES - a skipped check must never be representable as a pass:
#   0  in sync (--check) / policy applied (apply)
#   1  drift detected (--check / --diff only)
#   2  COULD NOT RUN - missing jq, missing/invalid policy file, unwritable target.
#      Distinct from 1 on purpose. A caller must be able to tell "checked and
#      clean" from "never actually checked".

set -u

DOTFILES_DIR="${DOTFILES_DIR:-${HOME}/claude-guardrails}"
POLICY_FILE="${DOTFILES_DIR}/claude-core/settings-policy.json"
TARGET_FILE="${CLAUDE_SETTINGS_FILE:-${HOME}/.claude/settings.json}"

MODE="apply"
case "${1:-}" in
  --check) MODE="check" ;;
  --diff)  MODE="diff" ;;
  --heal)  MODE="heal" ;;
  "")      MODE="apply" ;;
  -h|--help)
    sed -n '3,30p' "$0"
    exit 0
    ;;
  *)
    echo "apply-settings.sh: unknown argument '${1}'" >&2
    echo "Usage: apply-settings.sh [--check|--diff]" >&2
    exit 2
    ;;
esac

fail_cannot_run() {
  # Loud, and exit 2 rather than 0/1, so this can never be mistaken for a pass.
  #
  # --heal is the exception, and deliberately so. It runs from a SessionStart
  # hook, which is the interactive case in hardening.md rule 1: "fail closed by
  # default, fail open only for a human, never for a cron." A machine whose jq
  # is missing must still be usable, so --heal stays loud but non-blocking. The
  # unattended path (--check, called by check-setup.sh) still exits 2 and fails
  # closed. Both behaviours are correct; they just serve different callers.
  if [ "${MODE}" = "heal" ]; then
    echo "[claude-guardrails] SETTINGS POLICY NOT VERIFIED: $*" >&2
    exit 0
  fi
  echo "CANNOT RUN: $*" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || fail_cannot_run "jq is not installed. Install jq and re-run."

[ -f "${POLICY_FILE}" ] || fail_cannot_run "policy file not found: ${POLICY_FILE}"
jq empty "${POLICY_FILE}" 2>/dev/null || fail_cannot_run "policy file is not valid JSON: ${POLICY_FILE}"

# A missing target is normal on a fresh machine: treat it as an empty object,
# but only for apply. In --check mode a missing settings.json IS drift.
if [ ! -f "${TARGET_FILE}" ]; then
  if [ "${MODE}" = "apply" ] || [ "${MODE}" = "heal" ]; then
    mkdir -p "$(dirname "${TARGET_FILE}")" || fail_cannot_run "cannot create $(dirname "${TARGET_FILE}")"
    echo '{}' > "${TARGET_FILE}" || fail_cannot_run "cannot create ${TARGET_FILE}"
    echo "Created empty ${TARGET_FILE}."
  else
    echo "DRIFT: ${TARGET_FILE} does not exist; no policy is in effect on this machine."
    echo "  Fix: bash ${DOTFILES_DIR}/bin/apply-settings.sh"
    exit 1
  fi
fi

jq empty "${TARGET_FILE}" 2>/dev/null || fail_cannot_run \
  "${TARGET_FILE} is not valid JSON. Claude Code ignores an unparseable settings file wholesale. Repair it before applying policy."

# Strip _comment (documentation, not a setting) before merging.
POLICY_EFFECTIVE="$(jq 'del(._comment)' "${POLICY_FILE}")" \
  || fail_cannot_run "failed to read policy keys from ${POLICY_FILE}"

if [ "${POLICY_EFFECTIVE}" = "{}" ]; then
  fail_cannot_run "${POLICY_FILE} declares no policy keys. Refusing to report 'in sync' against an empty policy - that would be a check that cannot fail."
fi

# Merge semantics. jq's `*` was the obvious choice and is wrong here: it REPLACES
# arrays wholesale, so a policy carrying permissions.deny would silently delete
# any deny rule a machine had added locally. Silently removing a security rule
# while reporting success is the exact bug class this whole script exists to
# prevent, so arrays are UNIONed instead: policy entries are guaranteed present,
# the machine's own entries survive.
#
#   object + object -> recurse
#   array  + array  -> union, deduplicated
#   key absent from policy -> machine's value untouched (never sorted or rewritten)
#   otherwise -> policy wins
# jq gotcha: function parameters are CLOSURES re-evaluated against whatever the
# current input is, so the obvious `a[$k]` silently re-runs `.[0]` against the
# `{}` accumulator inside reduce and dies. Bind both sides to $a/$b immediately.
MERGE_PROGRAM='
def deepmerge(a; b):
  a as $a | b as $b |
  if $b == null then $a
  elif $a == null then $b
  elif ($a|type) == "object" and ($b|type) == "object" then
    reduce ((($a|keys_unsorted) + ($b|keys_unsorted)) | unique)[] as $k
      ({}; .[$k] = deepmerge($a[$k]; $b[$k]))
  elif ($a|type) == "array" and ($b|type) == "array" then
    (($a + $b) | unique)
  else $b
  end;

# Union alone cannot RETIRE a superseded entry, and that bit on 2026-08-14.
# Adding a second hook to a policy event left the OLD single-hook matcher entry
# beside the new two-hook one: to the union, a stale policy entry is
# indistinguishable from a machine\047s own addition, which union deliberately
# preserves. The result ran guard-git-push.sh TWICE on every Bash call and
# apply-settings.sh --heal TWICE on every session start, while --check still
# reported "in sync", because every policy entry genuinely WAS present. A drift
# check that cannot see a duplicate it created is the same shape of bug as a
# monitor that cannot see the host it is meant to watch.
#
# So after merging, entries within each hooks.<Event> that share a matcher are
# collapsed into one, unioning their hook lists. Entries with DIFFERENT matchers
# are never merged. Order is preserved by walking and appending rather than
# using `unique`, which sorts and would scramble hook execution order.
# Scoped to .hooks only: permissions.deny and friends keep plain union semantics.
def merge_hook_entries:
  reduce .[] as $e ([];
    (map(.matcher) | index($e.matcher)) as $i
    | if $i == null then . + [$e]
      else .[$i].hooks = (reduce ($e.hooks // [])[] as $h (.[$i].hooks // [];
             if any(.[]; . == $h) then . else . + [$h] end))
      end);

def collapse_hooks:
  if (.hooks? | type) == "object" then
    .hooks |= with_entries(
      if (.value | type) == "array" then .value |= merge_hook_entries else . end)
  else . end;

deepmerge(.[0]; .[1]) | collapse_hooks
'
MERGED="$(jq -s "${MERGE_PROGRAM}" "${TARGET_FILE}" <(printf '%s' "${POLICY_EFFECTIVE}"))" \
  || fail_cannot_run "merge failed"

CURRENT="$(jq -S . "${TARGET_FILE}")" || fail_cannot_run "cannot normalise ${TARGET_FILE}"
PROPOSED="$(printf '%s' "${MERGED}" | jq -S .)" || fail_cannot_run "cannot normalise merged result"

# Report drift per policy key so the output names what is actually wrong.
#
# "want" is the MERGED value, not the raw policy value. With union semantics a
# machine that carries extra local deny rules is compliant even though its array
# is not equal to the policy's, and comparing against raw policy would report
# that machine as permanently drifted - a check that cries wolf gets ignored,
# which is how you end up with no check at all.
report_drift() {
  echo "${1:-Policy keys out of sync in ${TARGET_FILE}:}"
  # Report at LEAF path (permissions.deny), not top-level key (permissions).
  # Reporting the whole parent object dumps every unrelated sibling - including
  # a machine's entire allow list - which buries the one line that changed.
  printf '%s' "${POLICY_EFFECTIVE}" \
    | jq -c '[paths as $p
               | select((getpath($p) | type) != "object")
               # An array is a LEAF, never a container to descend into. Testing
               # only the last element was not enough: hooks.SessionStart.0.hooks
               # ends in a string while still sitting inside an array, so the
               # report walked every hook object field by field.
               | select(all($p[]; type != "number"))
               | $p]' \
    | jq -c '.[]' \
    | while IFS= read -r PATH_JSON; do
        LABEL="$(printf '%s' "${PATH_JSON}" | jq -r 'join(".")')"
        LIVE="$(jq -S --argjson p "${PATH_JSON}" 'getpath($p)' "${TARGET_FILE}")"
        WANT="$(printf '%s' "${MERGED}" | jq -S --argjson p "${PATH_JSON}" 'getpath($p)')"
        if [ "${LIVE}" = "${WANT}" ]; then
          printf '  OK    %s\n' "${LABEL}"
        else
          printf '  DRIFT %s\n' "${LABEL}"
          printf '        want: %s\n' "$(printf '%s' "${WANT}" | tr -d '\n' | tr -s ' ')"
          printf '        live: %s\n' "$(printf '%s' "${LIVE}" | tr -d '\n' | tr -s ' ')"
        fi
      done
}

if [ "${CURRENT}" = "${PROPOSED}" ]; then
  # --heal runs from a SessionStart hook and its stdout is injected into the
  # session context, so the healthy path must be COMPLETELY silent. A hook that
  # prints a reassuring line every single session is a per-session token tax and
  # trains you to ignore its output, which is the one thing it must not do.
  [ "${MODE}" = "heal" ] && exit 0
  echo "In sync: every policy key in ${POLICY_FILE} is already set in ${TARGET_FILE}."
  exit 0
fi

case "${MODE}" in
  check)
    report_drift
    echo
    echo "Fix: bash ${DOTFILES_DIR}/bin/apply-settings.sh"
    exit 1
    ;;
  diff)
    report_drift
    echo
    echo "(--diff made no changes. Re-run without --diff to apply.)"
    exit 1
    ;;
esac

# Apply. Back up first; write via temp file so a failed write cannot truncate
# a valid settings.json.
BACKUP="${TARGET_FILE}.bak-$(date +%Y%m%d%H%M%S)"
cp "${TARGET_FILE}" "${BACKUP}" || fail_cannot_run "could not back up ${TARGET_FILE}"

TMP="$(mktemp)" || fail_cannot_run "mktemp failed"
printf '%s\n' "${MERGED}" > "${TMP}" || fail_cannot_run "could not write temp file"
jq empty "${TMP}" 2>/dev/null || fail_cannot_run "merged result is not valid JSON; ${TARGET_FILE} left untouched"
mv "${TMP}" "${TARGET_FILE}" || fail_cannot_run "could not move merged result into place"

# Preserve the restrictive mode Claude Code uses; settings.json can carry tokens.
chmod 600 "${TARGET_FILE}" 2>/dev/null || echo "WARN: could not chmod 600 ${TARGET_FILE}" >&2

if [ "${MODE}" = "heal" ]; then
  # Drift found and repaired. Say so LOUDLY: self-healing in silence would
  # recreate the exact bug this exists to catch, because a machine that has been
  # quietly repaired every session looks identical to one that was never broken.
  # This is the one case where --heal is allowed to speak.
  echo "[claude-guardrails] SETTINGS POLICY WAS MISSING ON THIS MACHINE AND HAS BEEN APPLIED."
  echo "[claude-guardrails] Backup of the previous settings: ${BACKUP}"
  report_drift "[claude-guardrails] Policy keys now in force:"
  echo "[claude-guardrails] If this keeps recurring, something is rewriting settings.json after the hook runs."
  exit 0
fi

echo "Applied policy from ${POLICY_FILE} to ${TARGET_FILE}."
echo "Backup: ${BACKUP}"

# Re-read from disk and report per key. This is deliberately a fresh read of the
# written file rather than an echo of what we intended to write: status derived
# from the work, not asserted by the wrapper (hardening.md rule 3).
report_drift "Policy keys now in ${TARGET_FILE}:"
exit 0
