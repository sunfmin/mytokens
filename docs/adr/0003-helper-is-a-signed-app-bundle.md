# The Helper is a signed `.app` bundle, not a bare CLI

The Helper is built as a macOS `.app` bundle in Xcode (automatic signing, team
`HL27PWAKDF`, **Keychain Sharing** capability), even though it is used like a CLI
(`MyTokens.app/Contents/MacOS/mytokens get cloudflare`). It also hosts the native
secure-input window used when adding a Secret.

## Context

Accessing the data-protection (iCloud) keychain requires the `application-identifier` +
`keychain-access-groups` entitlements to be honored at runtime, which in practice needs an
**embedded provisioning profile**. A `.app` bundle can carry one (Xcode generates and embeds
it via the Keychain Sharing capability); a standalone Mach-O CLI cannot do so cleanly.

## Considered Options

- **Bare signed CLI** (`swiftc` + `codesign --entitlements`). Lighter and more CLI-idiomatic,
  but with no provisioning profile the `application-identifier` entitlement is unlikely to be
  honored — the same `errSecMissingEntitlement` (-34018) wall the probe already hit. Rejected.

## Consequences

- Distribution is a one-time local `xcodebuild` into `/Applications`; `npx skills` installs
  only the skill files, which then invoke the app's inner binary by absolute path.
- Before writing the full Helper, build a ~20-line signed skeleton and re-run the add/read
  probe to confirm the entitlement is honored for synchronizable data-protection items.
