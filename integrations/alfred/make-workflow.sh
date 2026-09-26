#!/bin/bash
# Zips this directory's contents into Cmd-Tab.alfredworkflow, the format Alfred's
# Workflows > Import expects (a zip whose root is info.plist and its scripts, not
# a zip containing this directory itself).
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
output="$script_dir/Cmd-Tab.alfredworkflow"

rm -f "$output"
cd "$script_dir"
zip -r "$output" info.plist tile.sh -x '*.DS_Store'
# The shared list lives one level up so the Raycast extension can read it too, but
# an imported workflow is copied into Alfred's own preferences folder, where
# nothing one level up is ours. So it travels inside the zip, at the root beside
# tile.sh, which looks there first. Added from the parent directory so it lands at
# the root rather than under a path.
(cd .. && zip "$output" arrangements.json)

echo "Wrote $output"
