#!/usr/bin/env bash
# Builds the wasm game into build/web, ready to serve or zip for itch.io.
set -euo pipefail
cd "$(dirname "$0")"
ODIN=${ODIN:-odin}
OUT=build/web
mkdir -p "$OUT"
"$ODIN" build src -target:js_wasm32 -out:"$OUT/game.wasm" -o:speed "$@"
cp web/index.html "$OUT/"
cp "$("$ODIN" root)/core/sys/wasm/js/odin.js" "$OUT/"
cp assets/tileset.png "$OUT/"
