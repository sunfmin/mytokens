#!/bin/sh
# The Developer ID Application identity for signing on a GitHub runner
# (ADR-0017): imports the .p12 in DEVELOPER_ID_P12_BASE64 (password
# DEVELOPER_ID_P12_PASSWORD) into a new keychain DIR/signing.keychain-db, unlocked
# with a random password, readable by codesign without a prompt, and puts it on
# this user's keychain search list. The caller removes it:
#   tools/signing-keychain.sh --remove DIR
# Nothing of the identity or either password is printed.
# tools/signing-keychain-test.sh checks both.
set -eu
if [ "${1:-}" = --remove ]; then
	dir=${2:?usage: tools/signing-keychain.sh --remove DIR}
	kc="$dir/signing.keychain-db"
	[ -e "$kc" ] && security delete-keychain "$kc" 2>/dev/null || true
	# Off the search list too, even where the file had already gone.
	eval "security list-keychains -d user -s $(security list-keychains -d user | grep -vF "$kc" | tr '\n' ' ')"
	exit 0
fi
dir=${1:?usage: tools/signing-keychain.sh DIR}
: "${DEVELOPER_ID_P12_BASE64:?DEVELOPER_ID_P12_BASE64 is not set}"
: "${DEVELOPER_ID_P12_PASSWORD:?DEVELOPER_ID_P12_PASSWORD is not set}"
umask 077
kc="$dir/signing.keychain-db"
p12="$dir/identity.p12"
pw=$(openssl rand -hex 24)
trap 'rm -f "$p12"' EXIT
printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 -d >"$p12"
security create-keychain -p "$pw" "$kc"
security set-keychain-settings -lut 21600 "$kc"
security unlock-keychain -p "$pw" "$kc"
security import "$p12" -k "$kc" -f pkcs12 -P "$DEVELOPER_ID_P12_PASSWORD" \
	-T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pw" "$kc" >/dev/null
# shellcheck disable=SC2046 # the search list's entries are quoted paths
eval "security list-keychains -d user -s \"\$kc\" $(security list-keychains -d user | tr '\n' ' ')"
security find-identity -p codesigning "$kc" | grep -q 'Developer ID Application' \
	|| { echo "signing-keychain: no Developer ID Application identity in the .p12" >&2; exit 1; }
echo "signing-keychain: a Developer ID Application identity is in $kc"
