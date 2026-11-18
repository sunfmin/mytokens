#!/bin/sh
# Every ADR has its own number: fails, naming them, when two files in the
# ADR directory (default docs/adr) start with the same NNNN- prefix.
# gate.sh runs it; tools/adr-numbers-test.sh checks it.
set -eu
dir=${1:-docs/adr}
dups=$(ls "$dir" | sed -n 's/^\([0-9][0-9]*\)-.*/\1/p' | sort | uniq -d)
[ -z "$dups" ] && exit 0
for n in $dups; do
	echo "adr-numbers: ADR $n is used by more than one file:" >&2
	ls "$dir" | grep "^$n-" | sed 's/^/  /' >&2
done
echo "adr-numbers: give the later one the next free number and update its references" >&2
exit 1
