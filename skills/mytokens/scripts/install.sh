#!/usr/bin/env bash
# Install the MyTokens Helper from the latest GitHub Release.
#
# Downloads the notarized MyTokens.app, drops it in ~/Applications, symlinks the
# `mytokens` CLI into ~/.local/bin, and runs selftest. Location-independent — it
# pulls from GitHub, so it works no matter the current directory. Idempotent:
# re-running upgrades in place. To build from source instead (your own signing
# identity), see the repo README.
set -euo pipefail

REPO="${MYTOKENS_REPO:-sunfmin/mytokens}"
ASSET="MyTokens.zip"
APP="MyTokens.app"
INSTALL_DIR="$HOME/Applications"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/mytokens"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "mytokens is macOS-only (needs the iCloud Keychain via a signed Helper)." >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR" "$BIN_DIR"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

url="https://github.com/$REPO/releases/latest/download/$ASSET"
echo "downloading $url"
curl -fL --retry 3 -o "$tmp/$ASSET" "$url"

# The release archive is made with `ditto -c -k --keepParent`, so it holds the
# .app at the top level; extract it the same way.
ditto -x -k "$tmp/$ASSET" "$tmp/out"
app_src="$tmp/out/$APP"
if [[ ! -d "$app_src" ]]; then
  app_src="$(/usr/bin/find "$tmp/out" -maxdepth 2 -name "$APP" -type d | head -1)"
fi
[[ -d "$app_src" ]] || { echo "could not find $APP in $ASSET" >&2; exit 1; }

rm -rf "$INSTALL_DIR/$APP"
cp -R "$app_src" "$INSTALL_DIR/"
# It's downloaded, so it carries the quarantine bit; the app is notarized, but
# clear it so the CLI-launched binary starts without a Gatekeeper prompt.
xattr -dr com.apple.quarantine "$INSTALL_DIR/$APP" 2>/dev/null || true

ln -sf "$INSTALL_DIR/$APP/Contents/MacOS/MyTokens" "$BIN"
echo "installed: $BIN -> $INSTALL_DIR/$APP"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: add $BIN_DIR to your PATH (e.g. in ~/.zshrc): export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

# Prove the entitlement + keychain path actually work on this machine.
echo "verifying…"
"$BIN" selftest
