#!/bin/sh
# Exercises the xcodegen gate need through its public make targets, on a host
# where mise is absent and its official release is served from local fixtures.
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "xcodegen-need-test: $*" >&2; exit 1; }

version=$(sed -n 's/^MISE_VERSION := //p' Makefile)
[ -n "$version" ] || fail "MISE_VERSION is not pinned in the Makefile"
case $(uname -m) in
	arm64) arch=arm64 ;;
	x86_64) arch=x64 ;;
	*) fail "unsupported test architecture: $(uname -m)" ;;
esac
asset="mise-v$version-macos-$arch.tar.gz"
release="$tmp/release"
home="$tmp/home"
mkdir -p "$release/package/mise/bin" "$home" "$tmp/bin"

cat >"$release/package/mise/bin/mise" <<'EOF'
#!/bin/sh
set -eu
case ${1:-} in
	install)
		[ "${2:-}" = "xcodegen@2.46.0" ] || exit 1
		touch "$HOME/fake-xcodegen-installed"
		;;
	exec)
		[ "${2:-}" = "xcodegen@2.46.0" ] || exit 1
		[ "${3:-}" = "--" ] && [ "${4:-}" = "xcodegen" ] && [ "${5:-}" = "--version" ] || exit 1
		echo "2.46.0"
		;;
	*) exit 1 ;;
esac
EOF
chmod +x "$release/package/mise/bin/mise"
tar -czf "$release/$asset" -C "$release/package" mise
(cd "$release" && shasum -a 256 "$asset" >SHASUMS256.txt)

cat >"$tmp/bin/curl" <<'EOF'
#!/bin/sh
set -eu
out=
url=
while [ $# -gt 0 ]; do
	case $1 in
		-o) out=$2; shift 2 ;;
		-*) shift ;;
		*) url=$1; shift ;;
	esac
done
[ -n "$out" ] && [ -n "$url" ] || exit 2
case $url in
	*/SHASUMS256.txt) cp "$FAKE_RELEASE/SHASUMS256.txt" "$out" ;;
	*/mise-v*-macos-*.tar.gz) cp "$FAKE_RELEASE/${url##*/}" "$out" ;;
	*) exit 22 ;;
esac
EOF
chmod +x "$tmp/bin/curl"

export HOME="$home" PATH="$tmp/bin:/usr/bin:/bin" FAKE_RELEASE="$release"
! command -v mise >/dev/null 2>&1 || fail "the test host already has mise"
make -s xcodegen-install >"$tmp/install.out" 2>"$tmp/install.err" \
	|| fail "install did not repair a missing mise: $(cat "$tmp/install.err")"
make -s xcodegen-check >"$tmp/check.out" 2>"$tmp/check.err" \
	|| fail "check still fails after install: $(cat "$tmp/check.err")"
[ -x "$home/.local/bin/mise" ] || fail "install did not put mise under the test HOME"
[ -f "$home/fake-xcodegen-installed" ] || fail "install did not install the pinned XcodeGen"
grep -qF "2.46.0" "$tmp/check.out" || fail "check did not run the pinned XcodeGen"

rm "$home/.local/bin/mise" "$home/fake-xcodegen-installed"
printf 'tampered\n' >>"$release/$asset"
! make -s xcodegen-install >"$tmp/tampered.out" 2>"$tmp/tampered.err" \
	|| fail "install accepted an archive whose checksum did not match"
grep -qF "failed SHA-256 verification" "$tmp/tampered.err" \
	|| fail "checksum failure was not named: $(cat "$tmp/tampered.err")"
[ ! -e "$home/.local/bin/mise" ] || fail "a failed checksum still installed mise"

echo "xcodegen-need-test: ok"
