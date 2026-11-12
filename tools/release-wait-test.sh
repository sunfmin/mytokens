#!/bin/sh
# Checks tools/release-wait.sh against a local bare remote, with gh faked: it
# pushes the tag, waits for the run on the tag's commit, and fails when that
# run fails or never starts. `make test` runs it.
set -eu
cd "$(dirname "$0")/.."
script=$PWD/tools/release-wait.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "release-wait-test: $*" >&2; exit 1; }

git init -q --bare "$tmp/remote.git"
git init -q "$tmp/repo"
git -C "$tmp/repo" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m one
git -C "$tmp/repo" -c user.name=t -c user.email=t@example.invalid tag -a v9.9.9 -m v9.9.9
git -C "$tmp/repo" remote add origin "$tmp/remote.git"
sha=$(git -C "$tmp/repo" rev-parse HEAD)

# The fake gh: `run list` answers no run for the first $tmp/empty calls, then
# run 42, and records the commit it was asked about; `run watch` exits with
# the status in $tmp/watch.
mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<EOF
#!/bin/sh
case "\$1 \$2" in
"run list")
	while [ \$# -gt 0 ]; do [ "\$1" = --commit ] && echo "\$2" >"$tmp/asked"; shift; done
	n=\$(cat "$tmp/empty"); echo \$((n - 1)) >"$tmp/empty"
	[ "\$n" -gt 0 ] || echo 42 ;;
"run watch") [ "\$3" = 42 ] || exit 9; exit \$(cat "$tmp/watch") ;;
*) exit 9 ;;
esac
EOF
chmod +x "$tmp/bin/gh"
run() { (cd "$tmp/repo" && PATH="$tmp/bin:$PATH" RELEASE_WAIT_POLL=0 RELEASE_WAIT_TRIES=3 "$script" "$@") >"$tmp/out" 2>&1; }

echo 2 >"$tmp/empty"; echo 0 >"$tmp/watch"
run v9.9.9 || fail "a green run failed: $(cat "$tmp/out")"
[ "$(cat "$tmp/asked")" = "$sha" ] || fail "looked for the run on $(cat "$tmp/asked"), not the tag's commit $sha"
git -C "$tmp/remote.git" rev-parse --verify --quiet refs/tags/v9.9.9 >/dev/null || fail "the tag was not pushed"
grep -q "v9.9.9 is released" "$tmp/out" || fail "no released line: $(cat "$tmp/out")"

echo 0 >"$tmp/empty"; echo 1 >"$tmp/watch"
! run v9.9.9 || fail "a red run passed"
grep -q "run 42 on v9.9.9 failed" "$tmp/out" || fail "a red run is not named: $(cat "$tmp/out")"

echo 5 >"$tmp/empty"; echo 0 >"$tmp/watch"
! run v9.9.9 || fail "a run that never started passed"
grep -q "no release.yml run on v9.9.9" "$tmp/out" || fail "a missing run is not named: $(cat "$tmp/out")"

! run v0.0.0 || fail "a missing tag passed"

echo "release-wait-test: ok"
