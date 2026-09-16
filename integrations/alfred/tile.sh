#!/bin/bash
# Alfred Script Filter backing the `tile` keyword.
#
# Reads the single source of truth at ../arrangements.json (shared with the Raycast
# extension's src/arrangements.ts) and prints Alfred's Script Filter JSON, filtered
# by Alfred's own `{query}` so typing narrows the list. `arg` carries the raw value
# that the Run Script action turns into `open "cmdtab://tile/{query}"`.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
arrangements_file="$script_dir/../arrangements.json"
query="${1:-}"

jq --arg q "$query" '
  {
    items: (
      map(select(
        ($q | length) == 0
        or (.title | ascii_downcase | contains($q | ascii_downcase))
        or (.raw | ascii_downcase | contains($q | ascii_downcase))
      ))
      | map({
          uid: .raw,
          title: .title,
          subtitle: ("cmdtab://tile/" + .raw),
          arg: .raw,
          match: (.title + " " + .raw + " " + .family)
        })
    )
  }
' "$arrangements_file"
