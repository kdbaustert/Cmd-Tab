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

echo "Wrote $output"
