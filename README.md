<p align="center">
  <img src="docs/images/icon.png" width="128" alt="mytokens icon" />
</p>

<h1 align="center">mytokens — User Guide</h1>

<p align="center">
  Keep your API tokens, keys, and connection strings in the macOS <b>iCloud Keychain</b>,
  and let Claude fetch them at the moment it calls an API — without you ever pasting a
  secret into a chat.
</p>

---

## What it is, in one minute

- You store a secret **once**, in a small secure popup. It goes straight into your Keychain.
- Later, when Claude needs that secret to run a command, it reads it from the Keychain
  itself and uses it **inline** — the value never appears in the conversation.
- The value is entered and read only by a **signed macOS Helper**; Claude sees *that a
  secret exists* and its purpose, never the value.

You interact with two things: a one-line command (`mytokens …`, usually run by Claude) and
an occasional **secure popup** when a new secret needs to be stored. This guide walks
through exactly what you'll see.

---

## 1. Install

### Add the skill

```sh
npx skills add sunfmin/mytokens
```

This makes Claude aware of `mytokens`. From now on, before Claude asks you for a credential,
it checks the Keychain first.

### The app installs itself on first use

The `mytokens` command is a small signed app. The first time Claude needs it, it runs the
bundled installer, which downloads the notarized app, puts it in `~/Applications`, links the
`mytokens` command into `~/.local/bin`, and runs a self-check. You can also run it yourself:

```sh
bash ~/.claude/skills/mytokens/scripts/install.sh
```

You'll see it finish with a self-test — this confirms the Keychain works on your Mac:

```
upsert+get=true · list=true · delete=true · gone=true
SELFTEST PASS
```

> macOS only. If the command isn't found afterwards, add `~/.local/bin` to your `PATH`
> (the installer prints the exact line).

---

## 2. Store your first secret — step by step

When a secret isn't stored yet, Claude runs a command like this (you can run it too):

```sh
mytokens put cloudflare --description "Purge the CDN cache after a deploy"
```

**What happens:** a secure window appears. Nothing is stored until you fill it in and click
**Store**.

<p align="center">
  <img src="docs/images/popup-description.png" width="460" alt="the secret popup" />
</p>

Reading the window top to bottom:

| What you see | What it means |
|---|---|
| 🔑 **brass key badge** | This is the mytokens Helper asking to store a secret. |
| **Store a secret** | The action. |
| `cloudflare / default` chip | **Which** secret you're storing — the service and account. Confirm it's the one you expect before pasting. |
| *"Purge the CDN cache after a deploy."* | **Why** the popup appeared — the note Claude wrote so you (and a later session) know what this secret is for. |
| the field with a 🔒 | Where you type or paste the value. It's **masked** — shown as dots. |
| *Written to your Keychain — never shown to the agent* | Where the value goes, and the promise: Claude never receives it. |
| **Cancel / Store** | **Store** stays greyed out until the field has a value. Cancel writes nothing. |

**Step 1 — paste or type the value.** Copy your Cloudflare token and paste it (⌘V) into the
field. It shows as dots.

**Step 2 — click Store.** The window closes and the command prints:

```
stored cloudflare/default
```

That's it. The token is now in your Keychain. It never touched the chat, your shell history,
or Claude.

---

## 3. Store a multi-part credential (e.g. key + secret)

Some credentials come in pieces — an AWS **Access Key ID** *and* **Secret Access Key**, or a
database **username** + **password**. Claude collects them in **one** popup:

```sh
mytokens put aws --description "CI deploy: S3 uploads" \
                 --fields "Access Key ID","Secret Access Key" --show "Access Key ID"
```

<p align="center">
  <img src="docs/images/popup-multi.png" width="460" alt="the multi-field popup" />
</p>

- One labelled row per field.
- **Access Key ID** is shown as plain text (it's an identifier, not a secret) so you can
  eyeball that you pasted the right one. It was marked with `--show`.
- **Secret Access Key** is masked.
- **Store** turns on only when **every** field is filled — you can't save half a credential.

The whole thing is saved as one credential and deletes as a unit. Later you can update just
one part — `mytokens put aws --fields "Secret Access Key"` re-pops only that field and leaves
the Access Key ID — or name both to rotate them together.

---

## 4. Use your secrets

You rarely run these yourself — Claude does — but here's what they do.

**See what's stored** (never shows values):

```sh
$ mytokens list
cloudflare/default	parent	personal
aws/default	static	server  — CI deploy: S3 uploads  fields: Access Key ID, Secret Access Key
```

Each line shows the service/account, its kind, its level (`personal`, or `server` when it
your servers may hold it — `put --level server`, then `sync`), the description, and (for multi-part
credentials) the field names — **never the secret itself**.

**Fetch a value** (Claude uses this inline, e.g. inside a `curl`):

```sh
mytokens get cloudflare                       # a single secret → the raw value
mytokens get aws --field "Secret Access Key"  # one field of a multi-part credential
```

For example, Claude runs things like:

```sh
curl -H "Authorization: Bearer $(mytokens get cloudflare)" https://api.cloudflare.com/...
```

so the token is used directly and never stored in a variable or printed.

---

## 5. Point a tool at another provider (Profiles)

A **Profile** is a named bundle of environment variables — an endpoint, a model, and a token —
that you load into a shell in one line. The motivating case: run **Claude Code** against a
different API provider (say GLM) without editing any config files.

Store it once — pass the non-secret config on the command line with `--set`, and only the
secret token pops a masked field (`--fields`):

```sh
mytokens put glm --kind profile --description "Claude Code → GLM" \
  --set "ANTHROPIC_BASE_URL=https://open.bigmodel.cn/api/anthropic" \
  --set "ANTHROPIC_MODEL=glm-4.6" \
  --fields "ANTHROPIC_AUTH_TOKEN"
```

Then load it and launch — `mytokens env` prints shell `export` lines, so `eval` them and run
your tool:

```sh
eval "$(mytokens env glm)" && claude       # …or aider, or anything that reads ANTHROPIC_*
```

Change one variable later without re-entering the rest — `put` merges: `mytokens put glm --set
"ANTHROPIC_MODEL=glm-4.6-pro"`, or `mytokens put glm --fields "ANTHROPIC_AUTH_TOKEN"` to rotate
just the token.

Name a Profile by **provider** (`glm`), not by tool — the same Profile works for any tool that
reads those variables. To keep the token out of your shell for the rest of the session, scope
it to a subshell: `(eval "$(mytokens env glm)"; claude)`.

---

## 6. Rotate or remove

```sh
mytokens put cloudflare                        # re-put to rotate a lone token: same popup, new value
mytokens put glm --set "ANTHROPIC_MODEL=…"     # update just one field of a multi-field secret
mytokens rm  cloudflare                        # delete it entirely
```

`put` updates the fields you name and keeps the rest; to rebuild from scratch (or drop a
field), `rm` then `put`.

### Over SSH

Run `put` in a terminal and it asks there instead of popping the dialog: each secret field
is read with no echo (fields named in `--show` echo), so it works on a Mac you reach only by
SSH:

```sh
ssh -t my-mac mytokens put cloudflare --description "DNS edits" --fields Token
```

### From your phone: the one-time link

With neither a terminal nor a desktop — an agent running `put` on a server — `put` serves
**one page** on the Mac's tailnet address and prints a link to it:

```text
mytokens: open this link to enter the secret for cloudflare / default (it works once, within 10 minutes):
  https://my-server.tailnet-name.ts.net:53765/a7c81fb048650e728fe85acf9a8f0892
```

Open it on any device on your tailnet (your phone), fill in the fields and press **Store**. The
value goes from your browser straight into mytokens and the keychain — never through the
agent, its transcript or a file. The link carries a fresh random token, works **once** for that
one secret, and expires after **10 minutes**; then the page closes and `put` exits (stored, or
not stored with a non-zero exit). Getting the link to your phone is the caller's job; `put`
only prints it.

- It is served on the tailnet address only, never on another interface.
- HTTPS uses the Mac's tailnet certificate (`tailscale cert`). Where this user may not get one,
  the link is plain HTTP on the tailnet (which WireGuard encrypts) and `put` says why. To allow
  HTTPS for a non-admin user, an admin runs `sudo tailscale set --operator=<user>` once, and
  HTTPS certificates must be on for the tailnet.
- The macOS firewall must let MyTokens accept connections: the signed release is allowed
  automatically (*Automatically allow downloaded signed software*); an unsigned local build is
  not, and the link then never answers.
- On a Mac set to `server` (below) `put` never shows the popup — nobody watches a server's
  screen, even a logged-in one — so there it is the terminal, else the link.

With no terminal, no desktop and no tailnet, `put` stores nothing and prints the command to run
in a terminal.

---

## Where do the secrets live?

In **your** iCloud Keychain, under mytokens' own private area, written only by the signed
Helper. That means:

- ✅ iCloud Keychain sync carries them to your **other Macs** that have MyTokens installed (same Apple ID).
- ✅ You can see them with `mytokens list` or in **Keychain Access.app**.
- ❌ They do **not** appear in the **Passwords app** — that only lists website logins, not
  third-party API tokens. This is expected, not a bug.
- ❌ `/usr/bin/security` and unsigned scripts can't read them — only the signed Helper can.
- ✅ They are readable while the **screen is locked** (from SSH, the fleet, background jobs),
  once the Mac has been unlocked since it booted (ADR-0011). Right after a reboot, log in
  once before jobs can read them. Secrets stored by an older version move over on their own
  the next time mytokens runs while the Mac is unlocked.

---

## Set up a server

A **server** is a Mac of yours that runs unattended — reached over SSH or the tailnet, its
screen locked whenever nobody sits at it — and that you do **not** sign into iCloud. It keeps
its secrets in **local, non-synchronizable items** in the macOS data-protection keychain instead
of the iCloud Keychain (ADR-0013). Once its user has logged in after boot, jobs can read them
over SSH, including Tailscale SSH, while the screen is locked. After a reboot, log in once at
the console or over Screen Sharing before jobs need the secrets.

On one of **your own** Macs, once per server:

```sh
mytokens server add my-server      # any host name ssh accepts
```

```
installed MyTokens 0.1.7
role server
selftest passed
added deploy/default
added my-server to the server list
```

Over SSH, `server add` does four things, each only once the one before it succeeded:

1. **Installs** MyTokens on the server when it is missing or older than this Mac's — the same
   signed, notarized release `install.sh` installs. It sends the installer itself, so the
   server needs nothing first (not even the skill).
2. Sets the server's **role** to `server` (`mytokens host server` there) and runs
   **`mytokens selftest`** there.
3. Runs a first **`sync`** (below).
4. Puts the host on the **server list**.

A failing step is named, and the host stays off the list. Run `server add` again on a listed
host to repair it: it upgrades, re-checks and syncs, and changes nothing else.

```sh
mytokens server list               # the hosts on the list — names only, nothing secret
mytokens server rm my-server       # sync it to hold no secrets, then take it off the list
```

The list is one item in your iCloud Keychain, so every one of your Macs sees the same list;
`mytokens list` does not show it. Only hosts you name with `server add` are on it — nothing is
discovered from your tailnet. `server rm` first adopts whatever was entered on the server (and
stops, leaving the host listed, on a conflict, as `sync` does), then removes every secret it
pushed there. All three commands are refused on a server.

### Background sync

Each of your own Macs keeps every listed server current by itself. `install.sh` sets up a
launchd agent (`com.sunfmin.mytokens.background-sync`) that runs `mytokens server sync`:

- every **15 minutes**, plus once on waking when the Mac slept through a run;
- right after `put` or `rm` here changes a `server`-level secret (adds, updates, raises to
  `server`, lowers to `personal`, removes). The command returns at once and the agent does the
  syncing.

Each run first upgrades MyTokens on a host where it is missing or older (as `server add`
does), then syncs it. Hosts are independent: one that is off or failing never stops the others.
Before the Mac's first unlock after boot a run does nothing and waits. Your two Macs may both
run at once; the second prints `no changes`.

```sh
mytokens server list      # each host: when this Mac last synced it, or why it fails and the fix
```

```
macstudio-jp	last synced 2026-11-12 10:15
mini-jp	last synced 2026-11-11 08:00; failed to sync at 2026-11-12 10:15 (failing since 2026-11-11 08:15): sync with mini-jp failed to adopt: — keychain is locked … — fix: log in once at mini-jp after its reboot (at the Mac or over Screen Sharing)
```

A host failing for 24 hours straight is also pushed through [Bark](https://bark.day.app) once a
day, when this Mac has a `bark` secret (the same device key or URL a server uses). The push
names the host, how long, the failed step and the fix. Without one, it shows only in `server list`.

```sh
mytokens server pause     # stop background sync on this Mac (the other Mac keeps its own)
mytokens server resume    # start it again, with a run right away
mytokens server sync      # run it now, by hand
```

The agent's log, `~/Library/Logs/mytokens/background-sync.log`, holds host names, secret names,
steps and errors, and never a value. A server never gets the agent: `server add` installs with
`MYTOKENS_AGENT=0`, and `mytokens host server` removes it. `mytokens server agent` re-creates it
on your own Mac (ADR-0016).

To set a server up by hand instead, on the server: `bash ~/.claude/skills/mytokens/scripts/install.sh`,
then `mytokens host server` (this Mac's role; default: personal; `mytokens host` prints it), then
`mytokens selftest`.

From then on `put`, `get`, `env`, `list` and `rm` act on the server's local store:

- Every secret stored there is `server`-level; `put --level personal` is refused.
- iCloud Keychain sync never reaches the server. What is on it was entered on it or came by
  `mytokens sync` from one of your own Macs — and what was entered on it is adopted by the
  next `sync`, so your own Macs become its home.
- Secrets in your iCloud Keychain stay on your own Macs. `mytokens host personal` switches
  back (the local secrets stay where they are until you set `server` again).

If the server used a release that stored secrets in its login keychain, sync **before**
upgrading so anything entered only on the server is adopted. Upgrading does not move or delete
those old items; sync after upgrading restores every `server`-level secret from your own Mac.

### Sync with a server

On one of your own Macs, mark the secrets a server needs `server`, then sync:

```sh
mytokens put deploy --level server        # an existing secret: only its level changes
mytokens sync my-server                   # any host name ssh accepts
```

```
adopted ci-hook/default
added deploy/default
```

`sync` does two things, over SSH:

1. **Adopt.** Each secret entered on the server itself (`put` over SSH, or through a one-time
   link) comes back to this Mac as a `server`-level secret, whole, its description noting
   `adopted from my-server on <date>`. From then on this Mac is its home: change, lower or
   remove it here, and the next `sync` carries that to the server. If this Mac already has a
   secret of the same name, at any level, `sync` changes **neither** side, prints
   `conflict <name>: …` and exits non-zero once the rest is done — a server can never
   overwrite a secret on your own Macs. Settle it by hand (e.g. `rm` one of them).
2. **Push.** The server then holds exactly your `server`-level secrets: `sync` adds and
   updates them, and removes ones it sent earlier that are now `personal` or gone.

A second run prints `no changes`. The values travel only in the SSH pipes, between
`mytokens get --unpushed` / `mytokens put --stdin` on the server and this Mac — never on a
command line, in the environment, in a file or in what `sync` prints. Both are refused on your
own Macs. (`push`, the old name, is gone: it prints a hint naming `sync`.)

### When a server lacks a secret

On a server, `get` or `env` for a secret it does not hold still exits non-zero, but says why
and what to run:

```
no secret for deploy/default: it is not on this server (my-server).
A server holds only server-level secrets, synced from your personal Macs.
On a personal Mac, run:
  mytokens put deploy --level server
(an existing secret: only its level changes; a new one: you enter it there),
and the next sync brings it here — to bring it now, on that Mac: mytokens sync my-server
```

With a `bark` secret on the server, it also sends that as one [Bark](https://bark.day.app)
push — at most one per secret per hour, however many jobs ask (the times are kept in
`~/Library/Application Support/mytokens/miss-pushes.json`). The `bark` secret is your device
key (`mytokens put bark --level server`, pasting the key), or a whole push URL such as
`https://api.day.app/<key>` for a self-hosted server. Without it the server only prints. Your
own Macs print the plain `no secret for …` as before.

The role is one small file, `~/Library/Application Support/mytokens/host-role`. Your own
Macs never need it: without it a Mac is `personal` and nothing changes.

---

## Is it safe?

The value is only ever typed into the Helper's secure field and written straight to the
Keychain; it's never sent to Claude. When Claude later *uses* a secret, the raw value does
pass through the command it runs (that's how it reaches the API) — mytokens assumes a
trusted, single-user Mac with FileVault on. See [`docs/adr/`](./docs/adr/) for the full
reasoning.

---

## Advanced

### Build & install from source

Prefer to build and sign it yourself (recommended if you'd rather not run someone else's
signed binary holding your secrets):

- macOS with **Xcode** and a **paid Apple Developer** signing identity (the iCloud
  data-protection keychain needs an entitlement only a signed app can carry — ADR-0001).
- The pinned [`xcodegen`](https://github.com/yonaskolb/XcodeGen); the install command below
  also installs mise from its official, checksum-verified release when it is absent.

```sh
make xcodegen-install
make install      # xcodegen → signed build → ~/Applications/MyTokens.app + ~/.local/bin/mytokens
make verify       # show the signature + keychain-access-group
mytokens selftest # real-keychain round-trip — should print SELFTEST PASS
```

`project.yml` is the source of truth; the `.xcodeproj` is generated and git-ignored. The team
and bundle id live in `project.yml` (`DEVELOPMENT_TEAM`, `com.sunfmin.mytokens`) and the
access group in `mytokens.entitlements` — change all three together if you fork this. The app
icon is generated from code (`make icon`).

### Releasing (maintainers)

The afkconvoy fleet cuts each version itself once landed work is past the newest tag: it
sets `MARKETING_VERSION` in `project.yml` (the version's one home), tags, runs `make release`
and installs the Release on its host — see the cut blocks in
[`docs/agents/afkconvoy.md`](./docs/agents/afkconvoy.md). By hand it is the same path, built
and published locally — no CI. Notarization creds live in **mytokens itself**
(dogfooding): a secret named `asc-api-key` with fields **Key ID**, **Issuer ID**, and
**Key (base64 .p8)** — an App Store Connect API key. Create the key in App Store Connect →
*Users and Access → Integrations → Team Keys* (role: Developer), then store it:

```sh
base64 -i ~/Downloads/AuthKey_XXXX.p8 | tr -d '\n' | pbcopy   # single-line .p8 → clipboard
mytokens put asc-api-key --description "App Store Connect API key — notarize MyTokens" \
  --fields "Key ID","Issuer ID","Key (base64 .p8)" --show "Key ID","Issuer ID"
```

Then build and publish:

```sh
make dist                # archive → Developer ID export → notarize → staple → zip
make release TAG=v0.1.0  # gh release create + upload build/MyTokens.zip
```

`make dist` reads the API key from mytokens into a temp file (deleted right after), signs
with your Developer ID cert (already in the keychain), and builds with the **Hardened
Runtime** (required for notarization). `scripts/install.sh` downloads `MyTokens.zip` from the
**latest** Release, so bump `TAG` each time. Screenshots are regenerated with
`make screenshots`.

### How it's built

- Domain glossary: [`CONTEXT.md`](./CONTEXT.md)
- Decisions: [`docs/adr/`](./docs/adr/) — iCloud Keychain via a signed helper (0001), `get`
  returns the raw value (0002), a `.app` bundle (0003), minting (0004), multi-field
  Secrets (0005), per-Secret description (0006),
  readable after first unlock (0011)
- Skill behavior for Claude: [`skills/mytokens/SKILL.md`](./skills/mytokens/SKILL.md)

## License

[MIT](./LICENSE)
