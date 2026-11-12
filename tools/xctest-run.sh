#!/bin/sh
# Runs the unit-test bundle `make test` built (xcodebuild build-for-testing)
# with `xcrun xctest`, in this process's session. `xcodebuild test` instead asks
# launchd for com.apple.testmanagerd, which a session without one (the fleet's
# gate, run over SSH) cannot reach: it fails "Failed to establish communication
# with the test runner" before any test runs. MyTokensTests is not hosted in the
# app, so xctest runs it as it is.
#
# Red when the bundle is missing, when xctest fails, or when it ran no tests:
# a gate that ran nothing is not green. XCRUN overrides xcrun (for
# tools/xctest-run-test.sh).
set -eu
bundle=${1:?usage: xctest-run.sh <path/to/Tests.xctest>}
xcrun=${XCRUN:-xcrun}
fail() { echo "xctest-run: $*" >&2; exit 1; }

[ -d "$bundle" ] || fail "no test bundle at $bundle: build it with xcodebuild build-for-testing"
log=$(mktemp -t xctest-run)
trap 'rm -f "$log"' EXIT
status=0
"$xcrun" xctest "$bundle" >"$log" 2>&1 || status=$?
cat "$log"
[ "$status" -eq 0 ] || fail "xctest failed (exit $status)"
# XCTest's summary: "Executed 111 tests, with 0 failures ...".
executed=$(sed -n 's/.*Executed \([0-9][0-9]*\) tests\{0,1\}, with.*/\1/p' "$log" | tail -1)
[ -n "$executed" ] && [ "$executed" -gt 0 ] || fail "xctest ran no tests in $bundle"
