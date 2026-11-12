#!/bin/sh
# Writes the App Store Connect API key into DIR, readable by this user alone:
# DIR/AuthKey.p8, DIR/key-id and DIR/issuer-id. The caller makes DIR (mktemp -d)
# and removes it. Nothing of the key is printed.
#
# From the environment when ASC_KEY_P8_BASE64 is set (GitHub Actions: the repo
# secrets ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8_BASE64), else from mytokens
# itself: the Secret ASC_SECRET (default asc-api-key) with fields "Key ID",
# "Issuer ID", "Key (base64 .p8)" (ADR-0017). tools/asc-key-test.sh checks both.
set -eu
dir=${1:?usage: tools/asc-key.sh DIR}
umask 077
if [ -n "${ASC_KEY_P8_BASE64:-}" ]; then
	: "${ASC_KEY_ID:?ASC_KEY_P8_BASE64 is set but ASC_KEY_ID is not}"
	: "${ASC_ISSUER_ID:?ASC_KEY_P8_BASE64 is set but ASC_ISSUER_ID is not}"
	printf '%s' "$ASC_KEY_P8_BASE64" | base64 -d >"$dir/AuthKey.p8"
	printf '%s' "$ASC_KEY_ID" >"$dir/key-id"
	printf '%s' "$ASC_ISSUER_ID" >"$dir/issuer-id"
else
	secret=${ASC_SECRET:-asc-api-key}
	mytokens get "$secret" --field "Key (base64 .p8)" | base64 -d >"$dir/AuthKey.p8"
	mytokens get "$secret" --field "Key ID" >"$dir/key-id"
	mytokens get "$secret" --field "Issuer ID" >"$dir/issuer-id"
fi
[ -s "$dir/AuthKey.p8" ] || { echo "asc-key: the App Store Connect key is empty" >&2; exit 1; }
