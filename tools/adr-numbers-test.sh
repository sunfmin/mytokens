#!/bin/sh
# Checks tools/adr-numbers.sh: green on distinct numbers, red naming both
# files on a shared one. `make test` runs it.
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "adr-numbers-test: $*" >&2; exit 1; }

touch "$tmp/0001-a.md" "$tmp/0002-b.md" "$tmp/0010-c.md"
tools/adr-numbers.sh "$tmp" >"$tmp.out" 2>&1 || fail "distinct numbers are red: $(cat "$tmp.out")"

touch "$tmp/0002-d.md"
tools/adr-numbers.sh "$tmp" >"$tmp.out" 2>&1 && fail "a shared number is green"
grep -q '0002-b.md' "$tmp.out" && grep -q '0002-d.md' "$tmp.out" \
	|| fail "a shared number does not name both files: $(cat "$tmp.out")"
rm -f "$tmp.out"

tools/adr-numbers.sh || fail "docs/adr has a shared number"
echo "adr-numbers-test: ok"
