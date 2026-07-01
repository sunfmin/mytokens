# mytokens

A Claude Code skill + signed macOS Helper that stores **machine-usable secrets** (API
tokens, keys, connection strings) in the **iCloud Keychain** and auto-supplies them when
Claude calls an external API — without the values living in dotfiles or being re-pasted.

- Domain glossary: [`CONTEXT.md`](./CONTEXT.md)
- Decisions: [`docs/adr/`](./docs/adr/) — why iCloud Keychain via a signed helper (0001),
  why `get` returns the raw value (0002), why a `.app` (0003), how minting works (0004),
  multi-field Secrets (0005), per-Secret description (0006)
- Skill behavior for Claude: [`SKILL.md`](./SKILL.md)

The Helper is **service-agnostic** — it only stores and returns secrets. Service-specific
behavior (e.g. Cloudflare token minting) is a runtime pattern documented in `SKILL.md`, not
code in the Helper.

## Install

### Recommended — install the skill, let Claude install the app

```sh
npx skills add sunfmin/mytokens     # or your skill manager's equivalent
```

The skill lives at `skills/mytokens/SKILL.md`. On first use Claude runs the bundled
`scripts/install.sh`, which downloads the latest **notarized** `MyTokens.app` from this
repo's [Releases](https://github.com/sunfmin/mytokens/releases), installs it to
`~/Applications`, symlinks `~/.local/bin/mytokens`, and runs `selftest`. Run it yourself
any time:

```sh
bash ~/.claude/skills/mytokens/scripts/install.sh
```

macOS only; put `~/.local/bin` on your `PATH`.

### Build from source (your own signing identity)

Prefer to build and sign it yourself — recommended if you'd rather not run someone else's
signed binary holding your secrets:

- macOS with **Xcode** and a **paid Apple Developer** signing identity (the iCloud
  data-protection keychain needs an entitlement only a signed app can carry — ADR-0001).
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make install      # xcodegen → signed xcodebuild → ~/Applications/MyTokens.app + ~/.local/bin/mytokens
make verify       # show the signature + keychain-access-group
mytokens selftest # real-keychain round-trip — should print SELFTEST PASS
```

`project.yml` is the source of truth; the `.xcodeproj` is generated and git-ignored. The
team and bundle id live in `project.yml` (`DEVELOPMENT_TEAM`, `com.sunfmin.mytokens`) and the
access group in `mytokens.entitlements` — change all three together if you fork this.

### Releasing (maintainers)

Built and published locally — no CI. Produce the notarized artifact and upload it to a
GitHub Release:

```sh
export ASC_KEY=~/keys/AuthKey_XXXX.p8 ASC_KEY_ID=XXXXXXXX ASC_ISSUER=<issuer-uuid>
make dist                  # → build/MyTokens.zip (Developer ID-signed, notarized, stapled)
make release TAG=v0.1.0    # → gh release create + upload MyTokens.zip
```

`scripts/install.sh` downloads `MyTokens.zip` from the **latest** Release, so bump `TAG`
each time. `make dist` needs an App Store Connect API key (Developer / App-Manager role) so
xcodebuild can fetch a Developer ID profile with Keychain Sharing and `notarytool` can
submit; `make release` needs `gh` authenticated.

## Usage

```sh
mytokens add cloudflare --description "purge CDN cache after deploy"  # secure popup → stores the value
mytokens add cloudflare --account work --kind parent --meta '{"account_id":"<id>"}'
mytokens get cloudflare              # raw value to stdout; non-zero exit if absent
mytokens list                        # services / accounts / kind / description / fields / meta — never values
mytokens rm cloudflare               # delete; re-add to rotate

# Multi-field credentials (ADR-0005): several values, one popup, one Secret.
mytokens add aws --description "CI deploy: S3 uploads" \
                 --fields "Access Key ID","Secret Access Key" --show "Access Key ID"
mytokens get aws --field "Secret Access Key"   # one field's raw value (label is the key)
mytokens get aws --json                        # the whole {label: value} object
```

`--description` (ADR-0006) is a short note of what a Secret is for; the skill has the agent
set it on every `add` so a later run reading `list` knows each Secret's purpose.

Run tests with `make test` (23 tests: command behavior driven through the `Dependencies`
seam with in-memory fakes, plus offscreen renders of the input dialog — no real keychain,
no app launch).

## End-to-end demo: Cloudflare least-privilege minting

```sh
# 1. Store a Cloudflare PARENT token (one that can create tokens) via the popup:
mytokens add cloudflare --kind parent

# 2. Claude mints a short-lived, narrowly-scoped CHILD for a task, uses it, and revokes it.
#    Full recipe (verify → permission_groups → POST /user/tokens with 24h expiry → DELETE)
#    is in SKILL.md. The powerful parent never leaves the keychain except to mint.
```

A minted Child lacks the Parent's token-creation permission, so even a broad 24-hour Child
can't escalate by minting more tokens (ADR-0004).

## What this is not

- **Not** a web-login manager — browser passwords stay in Passwords.app (out of scope).
- **Not** visible in the Passwords.app UI and **not** usable on iPhone — secrets live in
  *our* keychain access group (ADR-0001). `mytokens list` / Keychain Access.app show them.
- Secrets sync via iCloud Keychain only to **other Macs where MyTokens.app is installed**
  under the same team.

## Maintenance

- Development provisioning profiles expire roughly yearly — re-run `make install` to refresh.
- Security posture assumes a trusted, single-user, FileVault-on Mac (ADR-0002): `get` returns
  the raw value and it may appear in transcripts/shell history. Revisit for shared machines.
