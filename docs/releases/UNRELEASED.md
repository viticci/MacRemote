# Unreleased Changes

Changes on `main` that are not in a released build yet. When a release ships,
these notes move to `docs/releases/<version>.md` and the user docs are updated
to match. See "Docs describe the latest release" in AGENTS.md.

## Result cards are now a setting, and off by default

Apps that can draw them, such as Claude and ChatGPT, used to show every tool
result as a card. Cards are now off unless you turn them on in
**Settings › General ▸ Result Cards**. With **Show result cards** on, each tool
family (an MCP server such as RemCTL, a catalog CLI such as PocketCTL, File
Transfer, or a command-line tool) has its own switch, so you can keep cards for
reminders and turn them off for searches. With a card off, the app gets the
same result as plain text. Apps pick up a change the next time they reload
MacRemote's tools. The Tools inspector shows each tool's **Result Card** state.

## Cards are readable in dark themes

In Claude's dark theme, a card's title and its "Completed" line were pale gray
on white and hard to read. Cards now follow the app's theme, and their text
meets WCAG AA contrast in light and dark. The fixed card has a new address, so
apps don't keep showing a saved copy of the old one.
