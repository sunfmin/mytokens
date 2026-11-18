#!/bin/sh
# The real `op` check of the vault sync (mytokens#15), against the scratch vault only.
# Production vaults are never a test target. Not part of the gate: `make op-real-check` runs it.
#
# It reads the scratch service account's token (the Secret 1password-scratch-service-account,
# read+write on the vault mytokens-scratch alone), refuses unless `op vault list` with that
# token shows exactly mytokens-scratch, then runs OnePasswordRealCheck in the test bundle: the
# sync writes, reads back and empties that vault from an in-memory store, never the keychain's
# Secrets. Usable inside a factorium worker.
set -eu
bundle=${1:?usage: op-real-check.sh <path/to/Tests.xctest>}
vault=mytokens-scratch
secret=1password-scratch-service-account
fail() { echo "op-real-check: $*" >&2; exit 1; }

[ -d "$bundle" ] || fail "no test bundle at $bundle: make op-real-check builds it"
command -v op >/dev/null 2>&1 || fail "op (1Password CLI) is not on PATH"
token=$(mytokens get "$secret" --field token) || fail "no scratch token: mytokens put $secret --fields token"
[ -n "$token" ] || fail "the Secret $secret has an empty token"

# Only the scratch token reaches op: no other account, session or token from this environment.
unset OP_SESSION OP_ACCOUNT OP_CONNECT_HOST OP_CONNECT_TOKEN
seen=$(OP_SERVICE_ACCOUNT_TOKEN=$token op vault list --format json | jq -r '.[].name' | sort | tr '\n' ' ')
[ "$seen" = "$vault " ] || fail "the scratch token must see the vault $vault alone; it sees: ${seen:-nothing}"

MYTOKENS_OP_REAL_CHECK_TOKEN=$token exec xcrun xctest -XCTest MyTokensTests.OnePasswordRealCheck "$bundle"
