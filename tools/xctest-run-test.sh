#!/bin/sh
# Checks tools/xctest-run.sh with xctest faked (XCRUN): green only when the
# bundle exists, xctest passes and it ran at least one test. `make test` runs it.
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "xctest-run-test: $*" >&2; exit 1; }

bundle="$tmp/Fake.xctest"
mkdir "$bundle"
# The fake xcrun prints FAKE_OUT and exits FAKE_EXIT; it insists on `xctest <bundle>`.
cat >"$tmp/xcrun" <<'FAKE'
#!/bin/sh
[ "$1" = xctest ] && [ -d "$2" ] || exit 99
printf '%s\n' "$FAKE_OUT"
exit "$FAKE_EXIT"
FAKE
chmod +x "$tmp/xcrun"
run() { XCRUN="$tmp/xcrun" FAKE_OUT="$1" FAKE_EXIT="$2" tools/xctest-run.sh "$3" >"$tmp/out" 2>&1; }

passed="Test Suite 'All tests' passed.
	 Executed 111 tests, with 0 failures (0 unexpected) in 6.0 (6.1) seconds"
run "$passed" 0 "$bundle" || fail "a passing run with tests is red: $(cat "$tmp/out")"
grep -q 'Executed 111 tests' "$tmp/out" || fail "xctest's output is not shown"

run "	 Executed 111 tests, with 2 failures (0 unexpected) in 6.0 (6.1) seconds" 1 "$bundle" \
	&& fail "a run with failures is green"
grep -q 'xctest failed (exit 1)' "$tmp/out" || fail "a failing run does not say so: $(cat "$tmp/out")"

run "	 Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds" 0 "$bundle" \
	&& fail "a run of no tests is green"
grep -q 'ran no tests' "$tmp/out" || fail "an empty run does not say so: $(cat "$tmp/out")"

run "" 0 "$bundle" && fail "a run without XCTest's summary is green"

run "$passed" 0 "$tmp/Missing.xctest" && fail "a missing bundle is green"
grep -q 'no test bundle at' "$tmp/out" || fail "a missing bundle does not say so: $(cat "$tmp/out")"

# The gate itself must not go through `xcodebuild test`, which needs testmanagerd.
grep -n 'xcodebuild.* test$' Makefile && fail "make test runs xcodebuild test, which needs testmanagerd"
echo "xctest-run-test: ok"
