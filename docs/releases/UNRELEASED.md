# Unreleased Changes

Changes on `main` that are not in a released build yet. When a release ships,
these notes move to `docs/releases/<version>.md` and the user docs are updated
to match. See "Docs describe the latest release" in AGENTS.md.

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
