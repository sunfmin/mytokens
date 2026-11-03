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
the Xcode project with the pinned XcodeGen and runs `make test`: 80 tests,
9 s on macs-Mac-Mini (12 cores) on 2026-11-03.

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

Not configured. A release is Developer ID-signed and notarized (`make
release`), which needs the signing identity and the App Store Connect key held
in mytokens itself; the fleet does not cut.
