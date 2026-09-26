#!/bin/bash
# Alfred Script Filter backing the `tile` keyword.
#
# Reads the single source of truth, arrangements.json (shared with the Raycast
# extension's src/arrangements.ts), and prints Alfred's Script Filter JSON, filtered
# by Alfred's own `{query}` so typing narrows the list. `arg` carries the raw value
# that the Run Script action turns into `open "cmdtab://tile/{query}"`.
set -euo pipefail

# Alfred runs scripts with PATH=/usr/bin:/bin:/usr/sbin:/sbin, which holds no
# Homebrew prefix — so the `brew install jq` the README asks for was invisible
# here on any macOS without its own /usr/bin/jq (macOS 14 and earlier).
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Beside this script in an imported workflow — make-workflow.sh packs it there,
# because Alfred copies a workflow into its own preferences folder, where
# ../arrangements.json names nothing. One level up when run from the repo.
arrangements_file="$script_dir/arrangements.json"
[[ -f "$arrangements_file" ]] || arrangements_file="$script_dir/../arrangements.json"
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
