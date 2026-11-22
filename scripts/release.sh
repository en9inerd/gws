#!/bin/bash
set -euo pipefail

DIST_DIR="dist"
VERSION=${VERSION:-dev}
TARGET_FILTER=${TARGET_FILTER:-}       # e.g. "linux_amd64" or "darwin_arm64" — empty = all
DESCRIPTION="Persistent Ghostty workspaces on top of zmx"
MAINTAINER="en9inerd"
URL="https://github.com/en9inerd/gws"

mkdir -p "$DIST_DIR" odin-out

targets=(
  "darwin_arm64:aarch64-macos:"
)

for entry in "${targets[@]}"; do
  IFS=':' read -r odin_target artifact_target deb_arch <<< "$entry"

  if [[ -n "$TARGET_FILTER" && "$odin_target" != *"$TARGET_FILTER"* ]]; then
    continue
  fi

  echo "Building gws for $odin_target (v$VERSION)"
  odin build odin/ -out:odin-out/gws -target:$odin_target \
    -define:CTYPE_VERSION="$VERSION" -o:size
  strip odin-out/gws

  staging=$(mktemp -d)
  cp odin-out/gws "$staging/gws"

  tar -czf "$DIST_DIR/ctype_${artifact_target}.tar.gz" -C "$staging" gws
  rm -rf "$staging"
done

echo ""
echo "Built artifacts:"
ls -lh "$DIST_DIR/"
