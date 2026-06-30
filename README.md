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

## Requirements

- macOS with **Xcode** and a **paid Apple Developer** signing identity (the iCloud
  data-protection keychain requires an entitlement only a signed app can carry — ADR-0001).
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- `~/.local/bin` on your `PATH`.

## Build & install

```sh
make install      # xcodegen → signed xcodebuild → ~/Applications/MyTokens.app + ~/.local/bin/mytokens
make verify       # show the signature + keychain-access-group
mytokens selftest # real-keychain add/get/list/delete round-trip — should print SELFTEST PASS
```

`project.yml` is the source of truth; the `.xcodeproj` is generated and git-ignored.
The team and bundle id are set in `project.yml` (`DEVELOPMENT_TEAM`, `com.sunfmin.mytokens`)
and the access group in `mytokens.entitlements` — change all three together if you fork this.

## Install the skill

Register this repo with your `skills` tooling so Claude auto-loads it (SKILL.md is at the
repo root):

```sh
npx skills add sunfmin/mytokens     # or your skill manager's equivalent; skillPath = SKILL.md
```

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
