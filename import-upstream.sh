#!/usr/bin/env bash
#
# Import a commit from an upstream vibe.d checkout that touches the MongoDB
# driver, translating its paths to this repository's layout.
#
#   ./import-upstream.sh <upstream-sha> [<path-to-vibe.d-checkout>]

set -euo pipefail

sha="${1:?usage: import-upstream.sh <upstream-sha> [<vibe.d-checkout>]}"
vibed="${2:-$HOME/src/vibe.d}"

git -C "$vibed" format-patch -1 --stdout "$sha" \
    | sed -E -e 's#\bmongodb/vibe/db/mongo/#source/vibe/db/mongo/#g' \
             -e 's#\btests/mongodb/#tests/#g' \
    | git am -3
