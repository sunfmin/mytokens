# The gate

`factorium.toml` runs `./gate.sh`. It first refuses two ADRs that share a number
(`tools/adr-numbers.sh`), then generates the Xcode project with the pinned
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

`factorium.toml` declares `[cut]`. The cut runs its `steps` in a clone at the
base tip with `FACTORIUM_VERSION` set (e.g. `v0.1.14`, the next after the newest
`v*` tag): `make set-version VERSION=${FACTORIUM_VERSION#v}` writes
`MARKETING_VERSION` in `project.yml`, and a commit carries it. The cut then tags
that commit and pushes the tag. The pushed `v*` tag is what makes the Release:
`.github/workflows/release.yml` (ADR-0017) builds, signs, notarizes and
publishes it, and checks the tag against `MARKETING_VERSION`. The tagged commit
need not be on main. There is no `formula`.

Installing on this Mac is not part of the cut. By hand, once the Release is
published: `make release-wait TAG=vx.y.z` (`tools/release-wait.sh`), `bash
skills/mytokens/scripts/install.sh`, `make -s installed-version-check
VERSION=x.y.z`. `make release-check-gh` checks a host has `gh` logged in with
push rights. Self-upgrade is its own ticket.
