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

## Always-on Macs come back after a restart

For a Mac that stays on with nobody at it, such as a Mac mini, **Settings ›
General** has a new **Startup** group. Both settings start off.

- **Open at login** opens MacRemote when you log in to the Mac. After a
  restart, someone has to log in, or automatic login must be on. If macOS asks
  you to allow MacRemote first, the setting says so and **Open Login Items
  Settings** takes you there.
- **Go public at launch** works only with a deployed **Your Domain**, never
  with an Instant Link. When you turn it on, MacRemote shows the Go Public
  confirmation once. After that, each time MacRemote opens it starts the local
  server and makes your domain public, using the key saved in your Keychain.
  It waits up to two minutes for the network after a restart.

Each time MacRemote goes public by itself, **Activity** and a notification say
so. When the setting is on but can't run (you changed the domain, the saved
key is gone, the domain's port is taken, no tools are shared, or the server
didn't start), nothing goes public, and Activity and a notification say why.
The setting is tied to the address you confirmed: after you change the domain,
turn it off and on again to confirm the new one. New apps still need your
approval to connect, and tools that ask first still ask.
