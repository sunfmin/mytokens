#!/bin/sh
# Checks tools/asc-key.sh: the key from the environment (GitHub Actions) and
# from mytokens (by hand, mytokens faked), written readable by this user alone,
# and nothing of it printed. `make test` runs it.
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "asc-key-test: $*" >&2; exit 1; }
p8='-----BEGIN PRIVATE KEY-----
not-a-real-key
-----END PRIVATE KEY-----'
b64=$(printf '%s' "$p8" | base64 | tr -d '\n')

check() { # dir, how
	[ "$(cat "$1/AuthKey.p8")" = "$p8" ] || fail "$2: the .p8 is not the key"
	[ "$(cat "$1/key-id")" = KEYID123 ] || fail "$2: key-id is $(cat "$1/key-id")"
	[ "$(cat "$1/issuer-id")" = issuer-uuid ] || fail "$2: issuer-id is $(cat "$1/issuer-id")"
	[ "$(stat -f %Lp "$1/AuthKey.p8")" = 600 ] || fail "$2: the .p8 is mode $(stat -f %Lp "$1/AuthKey.p8")"
	[ ! -s "$tmp/out" ] || fail "$2: printed $(cat "$tmp/out")"
}

mkdir "$tmp/env"
env -u ASC_SECRET ASC_KEY_P8_BASE64="$b64" ASC_KEY_ID=KEYID123 ASC_ISSUER_ID=issuer-uuid \
	tools/asc-key.sh "$tmp/env" >"$tmp/out" 2>&1 || fail "from the environment: $(cat "$tmp/out")"
check "$tmp/env" "from the environment"

mkdir "$tmp/half"
! env ASC_KEY_P8_BASE64="$b64" ASC_KEY_ID= ASC_ISSUER_ID=x tools/asc-key.sh "$tmp/half" 2>/dev/null \
	|| fail "a key without its ID passed"

# A fake mytokens holding the Secret "ci-key".
mkdir "$tmp/bin" "$tmp/mine"
cat >"$tmp/bin/mytokens" <<EOF
#!/bin/sh
[ "\$1 \$2 \$3" = "get ci-key --field" ] || { echo "no such secret" >&2; exit 1; }
case "\$4" in
"Key (base64 .p8)") echo "$b64" ;;
"Key ID") echo KEYID123 ;;
"Issuer ID") echo issuer-uuid ;;
*) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/mytokens"
env -u ASC_KEY_P8_BASE64 PATH="$tmp/bin:$PATH" ASC_SECRET=ci-key \
	tools/asc-key.sh "$tmp/mine" >"$tmp/out" 2>&1 || fail "from mytokens: $(cat "$tmp/out")"
check "$tmp/mine" "from mytokens"

mkdir "$tmp/none"
! env -u ASC_KEY_P8_BASE64 PATH="$tmp/bin:$PATH" ASC_SECRET=other tools/asc-key.sh "$tmp/none" 2>/dev/null \
	|| fail "a missing Secret passed"

echo "asc-key-test: ok"
