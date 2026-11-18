# The gate

`factorium.toml` runs `./gate.sh`. It generates the Xcode project with the pinned
XcodeGen and runs `make test`: the asc-key, release-wait, xcodegen-need and
test-runner script checks and the unit tests.

`make test` builds the tests with `xcodebuild build-for-testing` and runs the
bundle with `xcrun xctest` (`tools/xctest-run.sh`), not `xcodebuild test`: that
needs launchd's `com.apple.testmanagerd`, which the gate's session (over SSH)
cannot reach, and fails before any test runs. The runner is red on a missing
bundle, a failing test, or a run of no tests (`tools/xctest-run-test.sh`).

## What the gate needs on a host

- **Xcode**: `xcodebuild -version` must work. Install Xcode, select it with
  `xcode-select`, and agree to its license (`sudo xcodebuild -license accept`,
  an admin's hands).
- **XcodeGen**: `make -s xcodegen-check` checks it; `make -s xcodegen-install`
  installs it. The XcodeGen and mise versions live in the `Makefile`
  (`XCODEGEN_VERSION` and `MISE_VERSION`) alone. `xcodegen-install` installs a
  missing mise into `~/.local/bin` from its official release after verifying its
  SHA-256, then installs the pinned XcodeGen.

## Cutting a version

`factorium.toml` declares no `[cut]`. A Release is made by GitHub Actions on a
pushed `v*` tag (`.github/workflows/release.yml`, ADR-0017), and the tag must
carry the version in `MARKETING_VERSION` of `project.yml` (`make set-version
VERSION=x.y.z`). By hand: set the version, commit, tag, push the tag, then
`make release-wait TAG=vx.y.z` (`tools/release-wait.sh`), `bash
skills/mytokens/scripts/install.sh`, and `make -s installed-version-check
VERSION=x.y.z`. `make release-check-gh` checks a host has `gh` logged in with
push rights.

factorium's cut runs its `steps` before it tags, so the waiting and installing
part, which needs the tag pushed first, has no place to run; the gap is filed
on mytokens#3.
