# Unreleased Changes

Changes on `main` that are not in a released build yet. When a release ships,
these notes move to `docs/releases/<version>.md` and the user docs are updated
to match. See "Docs describe the latest release" in AGENTS.md.

## Fixes

- MacRemote now finds command-line tools installed with `npm -g`, Volta,
  pnpm, or Yarn, including Wrangler. It looks in `~/.npm-global/bin`,
  `~/.volta/bin`, `~/Library/pnpm`, `~/.yarn/bin`, and the `bin` folder of the
  npm prefix set in `~/.npmrc`. Before, a tool in one of these folders looked
  missing, and setting up your own domain said Wrangler wasn't installed
  ([#11](https://github.com/viticci/MacRemote/issues/11)).
