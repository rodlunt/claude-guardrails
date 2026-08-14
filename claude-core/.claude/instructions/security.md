## Security / Privacy

- **Browser automation: confirm WHICH browser before the first action, every session.**
  When using any browser automation, list the connected browsers FIRST. If more than one
  is connected, ask the user to pick before sending a single action; never accept the
  extension's default silently. This rule was written after an extension quietly defaulted
  to a work machine and sent navigations through a corporate proxy before anyone noticed.
- **Work and corporate machines are permanently off limits for automation.** Any connected
  browser that is not clearly a personal machine (unfamiliar platform, corporate proxy,
  `isLocal: false`) gets ZERO actions, not even a navigation: name it to the user and use
  the local browser only. If in doubt, ask. Recommend disconnecting the extension from any
  work machine it appears on.
- **Never read `.env` files** for diagnostic checks. Check for file existence or use `grep -c` (count only), never `grep` that would print matching lines containing secrets.
- **Never commit secrets.** Check for `.env`, credentials, API keys before staging.
- **Never use npm.** npm is banned due to active supply-chain worm risk. Use `pnpm` for package management and `uvx` or direct binaries for MCP servers. Do not suggest `npm install`, `npx`, or `npm ci` anywhere. When a Node-only tool or MCP server must be run one-off (the case `npx` would normally cover), use `pnpm dlx <pkg>` as the sanctioned replacement: it fetches and runs through pnpm's store rather than npm's.
