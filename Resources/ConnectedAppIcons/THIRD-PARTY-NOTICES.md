# Third-party notices — connected app icons

MacRemote draws a small mark next to each connected app. The mark is a visual
hint only: it is chosen from strings the app supplied about itself and it
grants no privilege (see `Models/ConnectedAppIdentity.swift`).

A mark can reach the screen four ways, in this order:

1. **Bundled artwork** committed to this directory, only where published brand
   terms permit redistribution.
2. **Local extraction** from a copy of the vendor's own app already installed
   on this Mac. Nothing is copied into the repository.
3. **The app's own `clientInfo.icons`**, `data:` URIs only.
4. **An SF Symbol fallback**, which every brand keeps.

MacRemote never fetches favicons or brand assets at runtime, and never ships
community re-drawings.

Machine-readable provenance for each bundled file — source URL, retrieval date,
source hash, transformations, and the committed hash — is in `MANIFEST.json`
next to this file.

## Bundled artwork

### T3 Code — `t3code.png`

Source: <https://github.com/pingdotgg/t3code> at commit
`1b4830ff06bf80e505dbf669deef189af85f77d7`, file
`assets/prod/black-macos-1024.png`.

Transformation: downscaled to 512×512 with `/usr/bin/sips`. No recolor, crop,
or re-drawing. `assets/prod` publishes only black marks at this commit, so the
one file serves both light and dark appearances.

```
MIT License

Copyright (c) 2026 T3 Tools Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Grok (xAI) — `grok-light.png`, `grok-dark.png`

Source: the official asset bundle linked from xAI's brand guidelines,
<https://data.x.ai/logos/SpaceXAI_Grok_Assets.zip>, retrieved 2026-07-30
(archive SHA-256 `db9129ac…`). Members `Grok_Logomark_Dark.png` (near-black
mark → MacRemote's light appearance) and `Grok_Logomark_Light.png` (white mark
→ dark appearance).

Transformation: **none**. xAI requires that its logos be used "exactly as
provided … without any alteration or adjustment", so both files are the archive
members byte-for-byte. Renaming the file is not a change to the artwork.

xAI Brand Guidelines, <https://x.ai/legal/brand-guidelines>, Usage Terms — do:

> Use our Marks only to accurately refer to us or our services.

and don't: use the marks in a way unrelated to xAI or that implies endorsement,
use them in an app title or in the name of a product xAI did not make, place
anything next to them that creates the impression of a new mark, or use them as
part of your own marks. MacRemote does none of those: the mark appears only to
name the app that connected to this Mac.

Note on naming: xAI names its files after the mark's own colour. Raycast, below,
names its files after the background the mark sits on. The two conventions are
opposites, so each file was decoded and checked rather than trusted by name.

### Raycast — `raycast-light.png`, `raycast-dark.png`

Source: the press kit at <https://www.raycast.com/press>, files
`press/images/logo/raycast-logo-light.png` and `…/raycast-logo-dark.png`,
retrieved 2026-07-30.

Transformation: **none** — byte-for-byte, colours unaltered.

Raycast press kit:

> Use the logo whenever you're referring to Raycast. The dark logo is used
> exclusively on dark backgrounds, and the light logo is used exclusively on
> light backgrounds.

and, of the app icon:

> Do not alter its colors.

MacRemote refers to Raycast when Raycast is the app that connected, uses each
variant on the background Raycast specifies, and alters nothing.

## Read from the installed app, not bundled

These brands ship no asset MacRemote may redistribute, so nothing here is
committed. When the vendor's own app is installed on this Mac, MacRemote reads
the mark out of that bundle at display time; when it is not, the SF Symbol
fallback applies. This is nominative use of software already licensed onto the
machine, not redistribution.

| Brand | Bundle ID | Preferred resources |
| --- | --- | --- |
| Claude | `com.anthropic.claudefordesktop` | `TrayIconTemplate` / `TrayIconTemplate-Dark` (@1x/@2x/@3x, 24–72 px) |
| ChatGPT | `com.openai.codex` | `icon-chatgpt` (2048 px) |
| Codex | `com.openai.codex` | `icon-codex-light` / `icon-codex-dark-color` (1024 px) |
| Notion | `notion.id` | app icon |
| Raycast | `com.raycast.macos` | app icon (the bundled press logo wins) |
| T3 Code | `com.t3tools.t3code` | app icon (the bundled MIT mark wins) |

A named variant is only used when its raster is at least twice the point size it
will be drawn at. Claude's tray art is 72 px, which is right for the 24 pt and
28 pt sites and too soft for the 64 pt approval ring — so the ring uses Claude's
own app icon instead of a blurry glyph.

A locally extracted mark is not stronger evidence of who the app is than any
other tier — it is still chosen from the name the app supplied.

## Held back — SF Symbol fallback only

Each of these has a documented blocker for *bundling*. Local extraction above
may still find the mark on this Mac.

| Brand | Blocker | Fallback symbol |
| --- | --- | --- |
| Notion | Unverifiable terms — Notion's brand-asset page is sign-in-gated, so its terms cannot be read or quoted. | `square.grid.2x2` |
| ChatGPT | Conditional grant, no distributable asset — OpenAI's published guidelines permit unaltered third-party use, but OpenAI publishes no downloadable logo pack. | `sparkles` |
| Codex | Same OpenAI guidelines, same absence of a published file. | `terminal` |
| Claude | No published terms — Anthropic publishes no brand-asset license covering third-party app bundling, so redistribution is unproven. | `bubble.left.and.bubble.right` |

Trademark note: brand names appear in this app only to identify the app that
connected. All trademarks belong to their respective owners. No vendor listed
here sponsors or endorses MacRemote.
