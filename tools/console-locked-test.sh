#!/bin/sh
# Checks tools/console-locked.sh and the release needs that call it, with the
# console lock reading faked (CONSOLE_USERS_PLIST, CONSOLE_LOCK_NOW). `make test`
# runs it.
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
uid=$(id -u)
fail() { echo "console-locked-test: $*" >&2; exit 1; }

# One IOConsoleUsers entry per argument "uid:locked", locked since 07:52:47Z.
users() {
	{
		echo '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>IOConsoleUsers</key><array>'
		for u in "$@"; do
			echo "<dict><key>kCGSSessionUserIDKey</key><integer>${u%%:*}</integer>"
			[ "${u#*:}" = locked ] && echo '<key>CGSSessionScreenIsLocked</key><true/><key>CGSSessionScreenLockedTime</key><integer>1793692367</integer>'
			echo '</dict>'
		done
		echo '</array></dict></plist>'
	} >"$tmp/users.plist"
}
export CONSOLE_USERS_PLIST="$tmp/users.plist" CONSOLE_LOCK_NOW=1793692988
cause="console session is locked since 2026-11-03T07:52:47Z (10 min)"

# The script itself.
users 9999:unlocked "$uid:locked"
tools/console-locked.sh 2>"$tmp/err" || fail "a locked session of this user reads as unlocked"
grep -qF "$cause" "$tmp/err" || fail "locked message lacks its time: $(cat "$tmp/err")"
grep -qF "Screen Sharing" "$tmp/err" || fail "locked message lacks the fix: $(cat "$tmp/err")"
users 9999:locked "$uid:unlocked"
! tools/console-locked.sh 2>"$tmp/err" || fail "another user's locked session reads as this user's"
[ ! -s "$tmp/err" ] || fail "an unlocked session printed: $(cat "$tmp/err")"

# release-check-signing: the cause comes before Xcode's lines, and the PLA
# advice only while unlocked. A fake `make signed` fails as a locked host does.
printf '#!/bin/sh\necho "error: exportArchive No Accounts"\nexit 1\n' >"$tmp/signed"
chmod +x "$tmp/signed"
users "$uid:locked"
! make -s release-check-signing MAKE="$tmp/signed" 2>"$tmp/err" >/dev/null || fail "signing check passed"
head -1 "$tmp/err" | grep -qF "$cause" || fail "signing: the locked cause is not first: $(cat "$tmp/err")"
sed -n 2p "$tmp/err" | grep -qF "No Accounts" || fail "signing: Xcode's line does not follow: $(cat "$tmp/err")"
! grep -q "Program License Agreement" "$tmp/err" || fail "signing: PLA advice while locked"
users "$uid:unlocked"
! make -s release-check-signing MAKE="$tmp/signed" 2>"$tmp/err" >/dev/null || fail "signing check passed"
! grep -q "console session" "$tmp/err" || fail "signing: locked cause while unlocked"
grep -q "Program License Agreement" "$tmp/err" || fail "signing: no PLA advice while unlocked"

# release-check-signing: each run signs a copy of the checkout in a directory
# of its own and removes it, so overlapping runs cannot break each other. A
# fake `make` records the directory it was given (-C) and succeeds.
printf '#!/bin/sh\nwhile [ $# -gt 0 ] && [ "$1" != -C ]; do shift; done\ntest -f "$2/project.yml" && echo "$2" >>"%s"\n' "$tmp/dirs" >"$tmp/signed"
make -s release-check-signing MAKE="$tmp/signed" & a=$!
make -s release-check-signing MAKE="$tmp/signed" || fail "signing check failed"
wait $a || fail "signing check failed"
[ "$(sort -u "$tmp/dirs" | wc -l)" -eq 2 ] || fail "signing: two runs did not each get a copy of the checkout: $(cat "$tmp/dirs")"
while read -r d; do [ ! -e "$d" ] || fail "signing: left $d behind"; done <"$tmp/dirs"

# release-check-keychain: no login keychain under a fake HOME.
users "$uid:locked"
! make -s release-check-keychain HOME="$tmp" 2>"$tmp/err" || fail "keychain check passed"
head -1 "$tmp/err" | grep -qF "$cause" || fail "keychain: the locked cause is not first: $(cat "$tmp/err")"
! grep -q "security unlock-keychain" "$tmp/err" || fail "keychain: unlock advice while locked"
users "$uid:unlocked"
! make -s release-check-keychain HOME="$tmp" 2>"$tmp/err" || fail "keychain check passed"
grep -q "security unlock-keychain" "$tmp/err" || fail "keychain: no unlock advice while unlocked"

# release-check-asc: a fake mytokens that cannot read the keychain.
mkdir "$tmp/bin"
printf '#!/bin/sh\necho "mytokens: keychain read failed" >&2\nexit 1\n' >"$tmp/bin/mytokens"
chmod +x "$tmp/bin/mytokens"
users "$uid:locked"
! PATH="$tmp/bin:$PATH" make -s release-check-asc 2>"$tmp/err" || fail "asc check passed"
head -1 "$tmp/err" | grep -qF "$cause" || fail "asc: the locked cause is not first: $(cat "$tmp/err")"
sed -n 2p "$tmp/err" | grep -qF "keychain read failed" || fail "asc: mytokens' line does not follow: $(cat "$tmp/err")"
! grep -q "store the App Store Connect key" "$tmp/err" || fail "asc: store advice while locked"
users "$uid:unlocked"
! PATH="$tmp/bin:$PATH" make -s release-check-asc 2>"$tmp/err" || fail "asc check passed"
grep -q "store the App Store Connect key" "$tmp/err" || fail "asc: no store advice while unlocked"

echo "console-locked-test: ok"
