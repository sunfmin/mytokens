#!/bin/sh
# Installs the pinned jq from its official release after verifying SHA-256.
set -eu
[ $# -eq 2 ] || { echo "usage: tools/install-jq.sh VERSION DESTINATION" >&2; exit 2; }
version=$1
destination=$2
case $(uname -s)-$(uname -m) in
	Darwin-arm64) asset=jq-macos-arm64 ;;
	Darwin-x86_64) asset=jq-macos-amd64 ;;
	Linux-x86_64) asset=jq-linux-amd64 ;;
	Linux-aarch64) asset=jq-linux-arm64 ;;
	*) echo "jq has no release for $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac
base="https://github.com/jqlang/jq/releases/download/jq-$version"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$base/$asset" -o "$tmp/$asset"
curl -fsSL "$base/sha256sum.txt" -o "$tmp/sha256sum.txt"
expected=$(awk -v asset="$asset" '$2 == asset { print $1 }' "$tmp/sha256sum.txt")
[ -n "$expected" ] || { echo "jq release $asset has no SHA-256 in $base/sha256sum.txt" >&2; exit 1; }
actual=$(shasum -a 256 "$tmp/$asset" | awk '{ print $1 }')
[ "$actual" = "$expected" ] || { echo "jq release $asset failed SHA-256 verification; nothing was installed" >&2; exit 1; }
mkdir -p "$(dirname "$destination")"
install -m 755 "$tmp/$asset" "$destination"
echo "installed jq $version at $destination"
