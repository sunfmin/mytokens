#!/bin/sh
# Installs the pinned mise from its official release after verifying SHA-256.
set -eu
[ $# -eq 2 ] || { echo "usage: tools/install-mise.sh VERSION DESTINATION" >&2; exit 2; }
version=$1
destination=$2
case $(uname -m) in
	arm64) arch=arm64 ;;
	x86_64) arch=x64 ;;
	*) echo "mise has no macOS release for $(uname -m)" >&2; exit 1 ;;
esac
asset="mise-v$version-macos-$arch.tar.gz"
base="https://github.com/jdx/mise/releases/download/v$version"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$base/$asset" -o "$tmp/$asset"
curl -fsSL "$base/SHASUMS256.txt" -o "$tmp/SHASUMS256.txt"
expected=$(awk -v asset="$asset" '$2 == asset { print $1 }' "$tmp/SHASUMS256.txt")
[ -n "$expected" ] || { echo "mise release $asset has no SHA-256 in $base/SHASUMS256.txt" >&2; exit 1; }
actual=$(shasum -a 256 "$tmp/$asset" | awk '{ print $1 }')
[ "$actual" = "$expected" ] || { echo "mise release $asset failed SHA-256 verification; nothing was installed" >&2; exit 1; }
tar -xzf "$tmp/$asset" -C "$tmp"
[ -f "$tmp/mise/bin/mise" ] || { echo "mise release $asset has no mise binary" >&2; exit 1; }
mkdir -p "$(dirname "$destination")"
install -m 755 "$tmp/mise/bin/mise" "$destination"
echo "installed mise $version at $destination"
