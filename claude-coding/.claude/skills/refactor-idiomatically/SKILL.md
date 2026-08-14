---
name: refactor-idiomatically
description: Use when the user asks to refactor, clean up, tidy, or modernise code in any language. Matches the project's existing idioms rather than imposing external conventions: surveys recent git history and sibling files to catalogue local patterns first, then proposes minimal diffs that conform to them.
---

# Refactor idiomatically

When the user asks for a refactor, do not reach for "best practice from outside the project". The codebase has its own idioms; matching them costs less context-switching for future readers and makes diffs smaller.

## Procedure

1. **Read recent code first.** Run `git log --oneline -20 -- <path>` and skim the 3-5 most recently modified sibling files (`git log --name-only -10 -- <dir>`). The patterns there are the local idiom. Do not read full diffs of the whole history: skimming the current state of a few recent siblings is cheaper and just as informative.

2. **Catalogue the idioms before changing anything.** Note the things you see: naming conventions, error handling shape, comment density, abstraction level, file organisation. Do not propose anything that breaks these without naming the cost.

3. **Propose minimal diffs.** Refactors should reduce surface area, not expand it. If the new shape is larger than the old shape, justify why before writing.

4. **Skip aesthetic-only changes.** Renaming a variable from `x` to `the_thing` is rarely worth the diff. Save edits for changes that improve readability or eliminate real complexity.

5. **Confirm before splitting files.** Adding new files crosses an organisational boundary the user already chose. Ask before doing it.

## When to break the rule

If the existing idiom is genuinely harmful (eg shared mutable global state, no error handling), name the conflict explicitly. Do not silently "fix" the idiom; surface the trade-off so the user can decide whether to keep the local convention or switch.

## Stop condition

If the user overrides a catalogued idiom (tells you to do it their way), treat their choice as the idiom for the rest of the session. Do not re-raise the trade-off on later edits: the decision is made.

## Output

Each refactor decision should answer:
- What pattern did I see?
- What pattern am I proposing?
- Why is the new pattern worth the diff cost?
