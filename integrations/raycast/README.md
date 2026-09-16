# Cmd-Tab for Raycast

An unpublished Raycast extension that drives Cmd-Tab's global actions through
its `cmdtab://` URL scheme — see the main repo's README, "Driving it from a
script", for the grammar. Nothing here talks to Cmd-Tab except `open`; there is
no IPC of its own.

Commands:

- **Tile Window** — search every `WindowArrangement` by its title and apply it.
- **Switch to App** — list installed/running apps (via `getApplications()`) and
  activate one.
- **Hide All Windows** / **Show All Windows** — no-view commands.

The arrangement list is not hard-coded here: `src/arrangements.ts` imports
`../../arrangements.json`, which is shared with the Alfred workflow in
`integrations/alfred/`. Adding an arrangement (or a future verb such as
`restore` or `layout`) means editing that one JSON file.

## Running it

```sh
npm install
npm run dev
```

`npm run dev` starts Raycast's development server and loads the extension
locally — nothing is published to the Raycast Store. `npm run build` produces
a distributable bundle if you want to share it directly.
