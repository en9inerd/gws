#!/bin/bash
set -euo pipefail

VERSION="${1:?version required}"
DIST="${2:?dist dir required}"
TAP_REPO="${3:?tap repo URL required}"

sha_of() { shasum -a 256 "${DIST}/$1" | awk '{print $1}'; }

SHA_MACOS_ARM64=$(sha_of gws_aarch64-macos.tar.gz)

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

git clone "$TAP_REPO" "$TMPDIR/tap"
cp packaging/homebrew/gws.rb "$TMPDIR/tap/Formula/gws.rb"

sed -i.bak \
  -e "s/VERSION_PLACEHOLDER/${VERSION}/g" \
  -e "s/SHA256_MACOS_ARM64/${SHA_MACOS_ARM64}/g" \
  "$TMPDIR/tap/Formula/gws.rb"
rm -f "$TMPDIR/tap/Formula/gws.rb.bak"

cd "$TMPDIR/tap"
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add Formula/gws.rb
git commit -m "gws ${VERSION}" || true
git push

echo "Updated homebrew-tap Formula/gws.rb to v${VERSION}"
