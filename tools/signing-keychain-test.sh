#!/bin/sh
# Checks tools/signing-keychain.sh with a throwaway self-signed "Developer ID
# Application" identity: it lands in its own keychain on the search list, where
# codesign finds it, nothing of it is printed, the .p12 does not stay on disk,
# and --remove takes the keychain off the list. `make test` runs it.
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
before=$(security list-keychains -d user)
cleanup() {
	tools/signing-keychain.sh --remove "$tmp/kc" || true
	eval "security list-keychains -d user -s $(printf '%s' "$before" | tr '\n' ' ')"
	rm -rf "$tmp"
}
trap cleanup EXIT
fail() { echo "signing-keychain-test: $*" >&2; exit 1; }

name='Developer ID Application: Signing Keychain Test (TEST000000)'
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$name" \
	-addext keyUsage=critical,digitalSignature -addext extendedKeyUsage=critical,codeSigning \
	-keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
pw=test-p12-password

openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -passout "pass:$pw" -out "$tmp/id.p12"
b64=$(base64 <"$tmp/id.p12" | tr -d '\n')

mkdir "$tmp/kc"
DEVELOPER_ID_P12_BASE64="$b64" DEVELOPER_ID_P12_PASSWORD="$pw" \
	tools/signing-keychain.sh "$tmp/kc" >"$tmp/out" 2>&1 || fail "import: $(cat "$tmp/out")"
! grep -q -e "$pw" -e "$(printf '%s' "$b64" | cut -c1-40)" "$tmp/out" || fail "printed the identity or its password"
[ ! -e "$tmp/kc/identity.p12" ] || fail "the .p12 stayed on disk"
security list-keychains -d user | grep -q "$tmp/kc/signing.keychain-db" || fail "the keychain is not on the search list"
security find-identity -p codesigning "$tmp/kc/signing.keychain-db" | grep -q "$name" || fail "the identity is not in the keychain"

mkdir "$tmp/bad"
! DEVELOPER_ID_P12_BASE64="$b64" DEVELOPER_ID_P12_PASSWORD=wrong tools/signing-keychain.sh "$tmp/bad" >/dev/null 2>&1 \
	|| fail "a wrong password passed"
tools/signing-keychain.sh --remove "$tmp/bad"

tools/signing-keychain.sh --remove "$tmp/kc"
! security list-keychains -d user | grep -q "$tmp/kc" || fail "--remove left the keychain on the search list"
[ ! -e "$tmp/kc/signing.keychain-db" ] || fail "--remove left the keychain on disk"
echo "signing-keychain-test: ok"
