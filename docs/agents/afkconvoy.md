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
the Xcode project with the pinned XcodeGen and runs `make test`: the asc-key,
release-wait, xcodegen-need and test-runner script checks and 113 tests, 6 s on macs-Mac-Mini (12 cores) on
2026-11-03.

`make test` builds the tests with `xcodebuild build-for-testing` and runs the
bundle with `xcrun xctest` (`tools/xctest-run.sh`), not `xcodebuild test`: that
needs launchd's `com.apple.testmanagerd`, which the gate's session (over SSH)
cannot reach, and fails before any test runs. The runner is red on a missing
bundle, a failing test, or a run of no tests (`tools/xctest-run-test.sh`).

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

The XcodeGen and mise versions live in the `Makefile` (`XCODEGEN_VERSION` and
`MISE_VERSION`) alone. `xcodegen-install` installs a missing mise into
`~/.local/bin` from its official release after verifying its SHA-256, then
installs the pinned XcodeGen.

## Cutting a version

The fleet cuts: once landed work is past the newest `v*` tag and the fleet is
idle, it sets the version, tags it and pushes the tag (`afkconvoy cut --help`).
GitHub Actions builds, signs, notarizes, verifies and publishes that tag's
Release (`.github/workflows/release.yml`, ADR-0017); the cut waits for that run
and installs the Release on this host. No `initial`: the tags (v0.1.4 and
earlier) pick the next version.

```yaml cut
set: make set-version VERSION="$VERSION"
publish: |
  make release-wait TAG="v$VERSION"
  bash skills/mytokens/scripts/install.sh
  make -s installed-version-check VERSION="$VERSION"
```

- `set` writes the version into its one home, `MARKETING_VERSION` in
  `project.yml`, which the build turns into the app's `CFBundleShortVersionString`.
  The workflow refuses a tag whose version `project.yml` does not carry.
- `publish` first runs `make release-wait` (`tools/release-wait.sh`). It pushes
  the tag, a no-op after the cut's `tag` step, finds the `release` workflow's run
  on the tag's commit, and follows it with `gh run watch --exit-status`. A red
  run fails the cut: re-run it (`gh run rerun <id>`), then go on with
  `afkconvoy cut --from publish`. The run is `make release`, the one release
  path, the same as by hand: Developer ID-signed with the App Store Connect
  API key in the repo secrets, notarized, stapled, checked by `make
  release-verify`, and uploaded with `gh release create`. The cut then installs
  with `scripts/install.sh`, so it installs the very notarized zip the Release
  serves, as every other Mac gets it, and proves it downloads and passes
  `selftest`. Last, the installed app must report `$VERSION`.

A cut needs only `gh` on a host, checked before a cut is claimed. Nothing is
built or signed there, so a locked console, a locked keychain or no Apple
account does not stop a cut.

```yaml cut-needs
checks:
  - name: gh
    command: make -s release-check-gh
    seconds: 30
```
