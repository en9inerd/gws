#!/bin/bash
set -euo pipefail

DIST_DIR="dist"
VERSION=${VERSION:-dev}
TARGET_FILTER=${TARGET_FILTER:-}       # e.g. "darwin_arm64" — empty = all

mkdir -p "$DIST_DIR" odin-out

# odin target : artifact target. macOS only: open, split and tab drive Ghostty
# through AppleScript.
targets=(
  "darwin_arm64:aarch64-macos"
  "darwin_amd64:x86_64-macos"
)

for entry in "${targets[@]}"; do
  IFS=':' read -r odin_target artifact_target <<< "$entry"

  if [[ -n "$TARGET_FILTER" && "$odin_target" != *"$TARGET_FILTER"* ]]; then
    continue
  fi

  echo "Building gws for $odin_target (v$VERSION)"
  odin build src -out:odin-out/gws -target:$odin_target \
    -define:GWS_VERSION="$VERSION" -o:size
  strip odin-out/gws

  staging=$(mktemp -d)
  cp odin-out/gws "$staging/gws"
  tar -czf "$DIST_DIR/gws_${artifact_target}.tar.gz" -C "$staging" gws
  rm -rf "$staging"
done

echo ""
echo "Built artifacts:"
ls -lh "$DIST_DIR/"
