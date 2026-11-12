# Releases are built, signed, notarized and published in GitHub Actions

Each version's Release is made by the `release` workflow on a GitHub-hosted Apple silicon
macOS runner, on the push of its `v*` tag. A cut on a fleet host only pushes the tag, waits for
that run, and installs the Release. This replaces "no CI" in the README's Releasing section.

## Context

Felix, 2026-11-12 (sunfmin/control#757): 「这个是开源项目，改成 GitHub 上面 CI 发吧。」mytokens
is public, and control ADR 0001 keeps Actions off private repos only. Until now `make release`
ran on the cutting host itself, so a cut needed an unlocked console session, an unlocked login
keychain, Xcode signed into the Apple account, and the `asc-api-key` Secret in mytokens. No host
could cut: Studio64's console is locked and it has neither MyTokens nor an Apple account, and
felixmbp14, where the last cuts ran, has been offline since 2026-11-08. v0.1.10 stayed the
newest Release while server add, Background Sync and the Bark miss landed.

## Decision

- **One release path.** The workflow (`.github/workflows/release.yml`) runs `make release
  TAG=<tag>`: archive, Developer ID export, notarize, staple, verify, zip, `gh release
  create`. A person can still run it by hand. Run by hand from the Actions tab
  (`workflow_dispatch`), it runs `make dist` and keeps the zip as the run's artifact, without
  publishing.
- **The App Store Connect API key** is the repo secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`,
  `ASC_KEY_P8_BASE64` (sunfmin/control#756), an Admin-role key. `tools/asc-key.sh` is the one
  reader. It reads the key from those variables when `ASC_KEY_P8_BASE64` is set, and from
  `mytokens get asc-api-key` otherwise. `make signed` passes the key to `xcodebuild` only when
  the variables are set. By hand, signing keeps using the Xcode-logged-in account and the key
  only notarizes.
- **The Developer ID identity is a `.p12` in the repo secrets** `DEVELOPER_ID_P12_BASE64` and
  `DEVELOPER_ID_P12_PASSWORD`: Felix's `Developer ID Application: FENGMIN SUN (HL27PWAKDF)`
  with its private key. The first try signed through the API key alone, with Xcode's
  cloud-managed Developer ID. On a runner that fails (`exportArchive Cloud signing permission
  error`), even with an Admin key. Only the Account Holder, or an Admin given that access, may
  use cloud-managed Developer ID certificates. Along the way the archive also made an
  `Apple Development: Created via API` certificate on each run. Now `tools/signing-keychain.sh`
  imports the `.p12` into a keychain of its own under the runner's temp dir, with a random
  password, and deletes it in an `if: always()` step. `tools/developer-id-profile.rb` uses the
  API key to find the active Developer ID (`MAC_APP_DIRECT`) profile holding that certificate,
  or makes one, which needs the Admin role. It then installs the profile. With
  `SIGN_KEYCHAIN` and `SIGN_PROFILE` set, `make signed` archives and exports with manual
  signing, using that identity and profile, so Xcode makes no certificate. When the certificate
  is renewed (it expires 2027-02-01), its `.p12` replaces the two secrets; the next run makes a
  profile for the new certificate.
- **The key stays out of sight.** Only the build step gets the secrets. The `.p8` is written
  mode 600 into a `mktemp -d` directory under that step's `TMPDIR` in the runner's temp dir. It
  is removed when its make recipe exits, and the whole directory is removed again in an
  `if: always()` step. Nothing prints the key. GitHub masks the secrets in logs.
- **Verified before published.** `make release-verify` runs inside `dist`, so it runs by hand
  too. It checks `codesign --verify --deep --strict`, `spctl --assess` reporting `Notarized
  Developer ID`, `stapler validate`, and the `keychain-access-groups` entitlement (ADR-0001).
  On a tag, the workflow also checks that `project.yml`'s `MARKETING_VERSION` is the tag's
  version.
- **The cut.** `publish` is `make release-wait TAG=v$VERSION` (`tools/release-wait.sh`). It
  pushes the tag, which is a no-op after the cut's tag step, and finds the workflow's run on
  the tag's commit. It follows that run with `gh run watch --exit-status` and fails the cut
  when the run fails. Then `scripts/install.sh` installs the Release, as on every other Mac,
  and `installed-version-check` checks the version, as before. A cut needs only `gh`, logged
  in as a user who may push. The Xcode, XcodeGen, keychain, signing and `asc-api-key` cut needs
  are gone, along with `tools/console-locked.sh`, which only they used. The gate keeps what the
  gate needs.

## Consequences

- Any host with `gh` can cut, whether its console is locked or not. Signing no longer depends
  on one person's Mac.
- A failed run fails the cut at `publish`. Re-run the workflow (`gh run rerun <id>`) and go on
  with `afkconvoy cut --from publish`. That watches the run again rather than starting another.
- The Admin-role key and the Developer ID identity sit in GitHub. Anyone who can change the
  workflow on a tag or `main` could use them. That is the repo's push access, the same people who can already publish
  Releases.
