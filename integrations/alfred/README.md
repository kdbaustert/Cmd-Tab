# Cmd-Tab for Alfred

An Alfred workflow, kept here as source rather than a zipped
`.alfredworkflow`, that drives Cmd-Tab's global actions through its
`cmdtab://` URL scheme — see the main repo's README, "Driving it from a
script", for the grammar.

- **`tile`** — a Script Filter (`tile.sh`) that lists every `WindowArrangement`
  by title, filtered as you type, and applies the selected one via
  `open "cmdtab://tile/{query}"`.
- **`hideall`** / **`showall`** — plain keywords that run
  `open "cmdtab://windows/hideAll"` / `showAll"`.

`tile.sh` reads `../arrangements.json`, the single source of truth shared with
the Raycast extension in `integrations/raycast/`. Adding an arrangement — or a
future verb such as `restore` or `layout` — means editing that one file, not
this workflow.

## Installing

Either:

1. Run `./make-workflow.sh` to produce `Cmd-Tab.alfredworkflow` in this
   directory, then double-click it — Alfred imports it directly.
2. Or open Alfred Preferences > Workflows, and drag this `alfred/` folder's
   contents (or the folder itself) in, since Alfred can import an unpacked
   workflow directory too.

Requires `jq` (`brew install jq`) for `tile.sh` to parse `arrangements.json`.
