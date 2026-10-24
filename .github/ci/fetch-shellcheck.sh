#!/usr/bin/env bash
# .github/ci/fetch-shellcheck.sh — a pinned shellcheck into ~/.local/bin, its
# checksum verified before anything is unpacked, so CI never runs `apt-get` on
# the hot path and never runs a binary it did not ask for (#756). The cache
# step in ci-shell.yml keys on SHELLCHECK_VERSION; a bump here is a cache miss.
set -euo pipefail
SHELLCHECK_VERSION="${SHELLCHECK_VERSION:-v0.10.0}"
SHELLCHECK_SHA256="${SHELLCHECK_SHA256:-6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87}"
dest="${1:-$HOME/.local/bin}"
asset="shellcheck-$SHELLCHECK_VERSION.linux.x86_64.tar.xz"
url="https://github.com/koalaman/shellcheck/releases/download/$SHELLCHECK_VERSION/$asset"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
curl -fsSL -o "$tmp/$asset" "$url"
echo "$SHELLCHECK_SHA256  $tmp/$asset" | sha256sum -c - >/dev/null
tar -xJf "$tmp/$asset" -C "$tmp"
mkdir -p "$dest"
install -m 0755 "$tmp/shellcheck-$SHELLCHECK_VERSION/shellcheck" "$dest/shellcheck"
"$dest/shellcheck" --version | head -2
