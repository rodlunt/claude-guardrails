## Session Discipline

- **Every project should have a session-end protocol.** Before ending a session: run tests, review changed code for quality issues, audit TODO/task tracking for drift, verify .gitignore covers sensitive files, and commit clean. Run `/session-end` to fire the generic user-scope command at `~/.claude/commands/session-end.md` (stack-detecting: Node, Python, Go, Rust, Hugo, Vite). A project-scoped override at `.claude/commands/session-end.md` wins over the generic one when a specific repo needs tailoring.
- **Code review before committing major changes.** Run `/code-review` on the working diff, or `security-review` when the change touches auth, secrets, input handling or network exposure. Don't self-certify large diffs.
- **E2E test coverage check.** Before running a test suite, audit whether existing tests actually cover the features changed this session. Stale tests that pass give false confidence. Write missing tests before declaring the suite green.
