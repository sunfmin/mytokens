# afkconvoy config

What `afkconvoy` reads for this repo: the yaml blocks below. An unknown key or
a wrong type is an error, not a default.

```yaml
base_branch: main                 # workers cut from it, open their PR against it, land on it
gate_command: afkconvoy exclusive -- ./gate.sh  # what must pass before a PR lands, one at a time on the host
gate_seconds: 1200                # the gate limit, starting after its turn is granted
```

The rest default (`ready_label: ready-for-agent`, `escalate_label:
ready-for-human`, `lock_label: fleet-lock`). The gate (`gate.sh`) generates
the Xcode project with the pinned XcodeGen and runs `make test`: the release-need script check and 98 tests,
10 s on macs-Mac-Mini (12 cores) on 2026-11-03.

## What the gate needs on a host

```yaml gate-needs
checks:
  - name: xcode
    command: |
      xcodebuild -version >/dev/null 2>&1 || {
        echo "the gate runs xcodebuild, and it does not run here: install Xcode, select it with xcode-select, and agree to its license (sudo xcodebuild -license accept, an admin's hands)" >&2
        exit 1
      }
    seconds: 60
  - name: xcodegen
    command: make -s xcodegen-check
    seconds: 60
    install: make -s xcodegen-install
    install_seconds: 300
```

The XcodeGen version lives in the `Makefile` (`XCODEGEN_VERSION`) alone.

## Cutting a version

The fleet cuts: once landed work is past the newest `v*` tag and the fleet is
idle, it sets the version, lands that, tags it, publishes a GitHub Release and
installs it on this host (`afkconvoy cut --help`). No `initial`: the tags
(v0.1.4 and earlier) pick the next version.

```yaml cut
set: make set-version VERSION="$VERSION"
publish: |
  make release TAG="v$VERSION"
  bash skills/mytokens/scripts/install.sh
  make -s installed-version-check VERSION="$VERSION"
```

- `set` writes the version into its one home, `MARKETING_VERSION` in
  `project.yml`, which the build turns into the app's `CFBundleShortVersionString`.
- `publish` is `make release` — the one release path: Developer ID-signed,
  notarized, stapled, uploaded with `gh release create`. It then installs with
  `scripts/install.sh` rather than `make install`: that installs the very
  notarized zip the Release serves, as every other Mac gets it, and proves it
  downloads and passes `selftest`; `make install` would rebuild with the
  development identity, a different binary. Last, the installed app must report
  `$VERSION`.

What publishing needs on a host is checked before a cut is claimed. The
signing check runs the real archive and Developer ID export (`make signed`,
~20 s on macs-Mac-Mini, 2026-11-03; two at once 24 s), on a copy of the checkout in a directory of its own per run, so overlapping runs cannot break each other; not `security find-identity`: signing here
is Xcode's cloud-managed Developer ID, with no certificate in the keychain. It
names an unaccepted Program License Agreement or a missing profile or identity,
all of which need an account holder's hands.

While this user's console session is locked, Xcode's Apple account is out of
reach (`exportArchive` reports `No Accounts`) and keychain reads can fail. A
need that fails then says so first, with when the lock began
(`tools/console-locked.sh`), and gives no other advice: only someone logging in,
at the Mac or over Screen Sharing, fixes it. `make test` checks this with the
lock reading faked (`tools/console-locked-test.sh`).

```yaml cut-needs
checks:
  - name: xcode
    command: |
      xcodebuild -version >/dev/null 2>&1 && xcrun --find notarytool >/dev/null 2>&1 && xcrun --find stapler >/dev/null 2>&1 || {
        echo "publishing needs Xcode with notarytool and stapler: install Xcode and select it with xcode-select" >&2
        exit 1
      }
    seconds: 60
  - name: xcodegen
    command: make -s xcodegen-check
    seconds: 60
    install: make -s xcodegen-install
    install_seconds: 300
  - name: login-keychain-unlocked
    command: make -s release-check-keychain
    seconds: 15
  - name: asc-api-key
    command: make -s release-check-asc
    seconds: 30
  - name: gh
    command: make -s release-check-gh
    seconds: 30
  - name: developer-id-signing
    command: make -s release-check-signing
    seconds: 600
```
