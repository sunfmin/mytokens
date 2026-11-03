#!/bin/sh
# Says on stderr, and exits 0, when this user's console session is locked —
# the cause a release need's failure names first (docs/agents/afkconvoy.md).
# Exits 1, silent, when it is not locked or there is no reading.
#
# While the screen is locked, Xcode's cloud-managed Developer ID signing
# reports "No Accounts", and keychain reads can fail: only a person logging in
# fixes that, so no other advice applies.
#
# The reading is IOConsoleUsers from `ioreg`; CONSOLE_USERS_PLIST names a file
# holding that output instead, and CONSOLE_LOCK_NOW the current epoch second
# (tests fake both: tools/console-locked-test.sh).
set -u
plist=$(mktemp) || exit 1
trap 'rm -f "$plist"' EXIT
if [ -n "${CONSOLE_USERS_PLIST:-}" ]; then
	cp "$CONSOLE_USERS_PLIST" "$plist" || exit 1
else
	ioreg -n Root -d1 -a >"$plist" 2>/dev/null || exit 1
fi
uid=$(id -u)
n=0
while plutil -extract "IOConsoleUsers.$n" xml1 -o /dev/null "$plist" 2>/dev/null; do
	key() { plutil -extract "IOConsoleUsers.$n.$1" raw -o - "$plist" 2>/dev/null; }
	if [ "$(key kCGSSessionUserIDKey)" = "$uid" ] && [ "$(key CGSSessionScreenIsLocked)" = true ]; then
		since=$(key CGSSessionScreenLockedTime)
		now=${CONSOLE_LOCK_NOW:-$(date +%s)}
		# A lock time later than now is no reading (seen on macs-Mac-Mini).
		if [ -n "$since" ] && [ "$since" -le "$now" ]; then
			at=$(date -u -r "$since" +%Y-%m-%dT%H:%M:%SZ)
			mins=$(( (now - since) / 60 ))
			when="since $at ($mins min)"
		else
			when="(since an unknown time)"
		fi
		echo "$(id -un)'s console session is locked $when: Xcode's Apple account and the keychain are unavailable until someone logs in, at the Mac or over Screen Sharing (a person's hands)" >&2
		exit 0
	fi
	n=$((n + 1))
done
exit 1
