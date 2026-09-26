# Cmd-Tab for Alfred

An Alfred workflow, kept here as source rather than a zipped
`.alfredworkflow`, that drives Cmd-Tab's global actions through its
`cmdtab://` URL scheme — see the main repo's docs/DOCUMENTATION.md, "Driving it from a
script", for the grammar.

- **`tile`** — a Script Filter (`tile.sh`) that lists every `WindowArrangement`
  by title, filtered as you type, and applies the selected one via
  `open "cmdtab://tile/{query}"`.
- **`hideall`** / **`showall`** — plain keywords that run
  `open "cmdtab://windows/hideAll"` / `showAll"`.

`tile.sh` reads `../arrangements.json`, the single source of truth shared with
the Raycast extension in `integrations/raycast/`. Adding an arrangement — or a
future verb such as `restore` or `layout` — means editing that one file, not
this workflow (then rebuilding it, below).

## Installing

Run `./make-workflow.sh` to produce `Cmd-Tab.alfredworkflow` in this
directory, then double-click it — Alfred imports it directly.

Use the script rather than dragging this folder into Alfred Preferences.
Alfred copies an imported workflow into its own preferences folder, where
`../arrangements.json` no longer exists, so `tile` would list nothing; the
script packs a copy of `arrangements.json` beside `tile.sh`, which is where
`tile.sh` looks first.

Requires `jq` (`brew install jq`) for `tile.sh` to parse `arrangements.json`.
`tile.sh` finds it under `/opt/homebrew/bin` or `/usr/local/bin` even though
Alfred runs scripts without either on its `PATH`.
