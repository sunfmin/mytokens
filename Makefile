APP          := MyTokens
BUNDLE       := MyTokens.app
PROJECT      := MyTokens.xcodeproj
INSTALL_DIR  := $(HOME)/Applications
BIN_DIR      := $(HOME)/.local/bin
BIN          := $(BIN_DIR)/mytokens
DERIVED      := build
PRODUCT      := $(DERIVED)/Build/Products/Release/$(BUNDLE)
# Built by `make test` (build-for-testing), run by tools/xctest-run.sh.
TEST_BUNDLE  := $(DERIVED)/Build/Products/Debug/$(APP)Tests.xctest
TEAM_ID      := HL27PWAKDF
ARCHIVE      := $(DERIVED)/$(APP).xcarchive
EXPORT       := $(DERIVED)/export
DIST_ZIP     := $(DERIVED)/$(APP).zip

# Notarization creds come from mytokens itself (dogfooding): a secret named
# $(ASC_SECRET) with fields "Key ID", "Issuer ID", "Key (base64 .p8)" — an App
# Store Connect API key. Signing uses the Developer ID cert already in your
# keychain + your Xcode-logged-in account.
ASC_SECRET ?= asc-api-key

# XcodeGen and mise, pinned: every build and the gate use these versions.
# `make xcodegen-install` installs both under $HOME when they are absent.
XCODEGEN_VERSION := 2.46.0
MISE_VERSION := 2026.10.15
MISE := $(shell command -v mise 2>/dev/null || printf '%s\n' '$(BIN_DIR)/mise')
XCODEGEN := "$(MISE)" exec xcodegen@$(XCODEGEN_VERSION) -- xcodegen

.PHONY: project build test install selftest verify signed dist release icon screenshots clean xcodegen-check xcodegen-install \
	set-version installed-version-check release-check-keychain release-check-signing release-check-asc release-check-gh

xcodegen-check:
	@command -v mise >/dev/null 2>&1 || [ -x "$(BIN_DIR)/mise" ] || { echo "mise is missing: run make -s xcodegen-install to install it from its official, checksum-verified release" >&2; exit 1; }
	$(XCODEGEN) --version

xcodegen-install:
	@if ! command -v mise >/dev/null 2>&1 && [ ! -x "$(BIN_DIR)/mise" ]; then \
		tools/install-mise.sh "$(MISE_VERSION)" "$(BIN_DIR)/mise"; \
	fi
	"$(MISE)" install xcodegen@$(XCODEGEN_VERSION)

project:
	$(XCODEGEN) generate

# Regenerate the app icon set from tools/makeicon.swift.
icon:
	swift tools/makeicon.swift Assets.xcassets/AppIcon.appiconset

# Regenerate the README screenshots: the dialog renders come straight from the
# render tests (same view the real popup hosts), plus a downscaled app icon.
screenshots: test
	mkdir -p docs/images
	cp out/secret-prompt-multi.png docs/images/popup-multi.png
	cp out/secret-prompt-description.png docs/images/popup-description.png
	sips -Z 256 Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png --out docs/images/icon.png >/dev/null
	@echo "screenshots → docs/images/"

build: project
	xcodebuild -project $(PROJECT) -scheme $(APP) -configuration Release \
		-derivedDataPath $(DERIVED) -allowProvisioningUpdates build

test: project
	tools/xcodegen-need-test.sh
	tools/console-locked-test.sh
	tools/xctest-run-test.sh
	xcodebuild -project $(PROJECT) -scheme $(APP) -derivedDataPath $(DERIVED) build-for-testing
	tools/xctest-run.sh $(TEST_BUNDLE)

install: build
	rm -rf "$(INSTALL_DIR)/$(BUNDLE)"
	mkdir -p "$(INSTALL_DIR)" "$(BIN_DIR)"
	cp -R "$(PRODUCT)" "$(INSTALL_DIR)/"
	ln -sf "$(INSTALL_DIR)/$(BUNDLE)/Contents/MacOS/$(APP)" "$(BIN)"
	@echo "installed: $(BIN) -> $(INSTALL_DIR)/$(BUNDLE)"

verify:
	codesign -dv --entitlements - "$(INSTALL_DIR)/$(BUNDLE)" 2>&1 | rg 'Identifier|TeamIdentifier|keychain-access-groups' || true

# The Developer ID-signed .app, not yet notarized: archive, then export it
# re-signed with "Developer ID Application" (a local identity or Xcode's
# cloud-managed one), with -allowProvisioningUpdates fetching a Developer ID
# profile carrying the Keychain Sharing capability. `dist` builds on it, and the
# cut's `release-check-signing` runs it to find signing broken before a cut.
signed: project
	xcodebuild -project $(PROJECT) -scheme $(APP) -configuration Release \
		-derivedDataPath $(DERIVED) -archivePath $(ARCHIVE) \
		-allowProvisioningUpdates archive
	xcodebuild -exportArchive -archivePath $(ARCHIVE) \
		-exportOptionsPlist ExportOptions.plist -exportPath $(EXPORT) \
		-allowProvisioningUpdates

# Release build: Developer ID-signed, notarized, stapled .app zipped for GitHub
# Releases. Single source of truth for the release artifact — CI just calls this.
dist: signed
	ditto -c -k --keepParent "$(EXPORT)/$(BUNDLE)" "$(DIST_ZIP)"
	@set -e; TMP=$$(mktemp -d); trap 'rm -rf "$$TMP"' EXIT; \
		mytokens get $(ASC_SECRET) --field "Key (base64 .p8)" | base64 -d > "$$TMP/asc.p8"; \
		xcrun notarytool submit "$(DIST_ZIP)" \
			--key "$$TMP/asc.p8" \
			--key-id "$$(mytokens get $(ASC_SECRET) --field 'Key ID')" \
			--issuer "$$(mytokens get $(ASC_SECRET) --field 'Issuer ID')" --wait
	xcrun stapler staple "$(EXPORT)/$(BUNDLE)"
	ditto -c -k --keepParent "$(EXPORT)/$(BUNDLE)" "$(DIST_ZIP)"
	@echo "dist: $(DIST_ZIP) (Developer ID-signed, notarized, stapled)"

# Local publish: build the notarized zip and upload it to a GitHub Release.
# `scripts/install.sh` downloads MyTokens.zip from the latest Release, so bump TAG
# each time. Needs `gh` authenticated (and the same ASC_* creds as `dist`).
release: dist
	@test -n "$(TAG)" || { echo "usage: make release TAG=v0.1.0"; exit 2; }
	gh release create "$(TAG)" "$(DIST_ZIP)" --generate-notes \
		|| gh release upload "$(TAG)" "$(DIST_ZIP)" --clobber
	@echo "released $(TAG): $(DIST_ZIP)"

selftest:
	"$(BIN)" selftest

# The app's version has one home: MARKETING_VERSION in project.yml, which becomes
# CFBundleShortVersionString. A cut's `set` step runs this (docs/agents/afkconvoy.md).
set-version:
	@test -n "$(VERSION)" || { echo "usage: make set-version VERSION=0.1.5" >&2; exit 2; }
	sed -i '' -E 's/^( *MARKETING_VERSION: )"[^"]*"/\1"$(VERSION)"/' project.yml
	@grep -q '^ *MARKETING_VERSION: "$(VERSION)"$$' project.yml \
		|| { echo "set-version: no MARKETING_VERSION line in project.yml took $(VERSION)" >&2; exit 1; }

# The installed app reports VERSION: what a cut's `publish` ends with.
installed-version-check:
	@test -n "$(VERSION)" || { echo "usage: make installed-version-check VERSION=0.1.5" >&2; exit 2; }
	@v=$$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$(INSTALL_DIR)/$(BUNDLE)/Contents/Info.plist"); \
		test "$$v" = "$(VERSION)" \
		|| { echo "installed $(INSTALL_DIR)/$(BUNDLE) reports $$v, not $(VERSION)" >&2; exit 1; }

# What `make release` needs on a host, checked before a cut is claimed
# (docs/agents/afkconvoy.md, the cut-needs block). Each says on stderr what is missing.
#
# The login keychain holds the signing keys. Locked, `security` fails at once
# over SSH ("interaction not allowed") and waits for a password in a desktop
# session, which the check's time limit ends.
#
# A need that fails while this user's console session is locked names that
# first (tools/console-locked.sh): it explains every failure below, and only
# logging in fixes it. Other advice is for a failure while unlocked.
CONSOLE_LOCKED := $(CURDIR)/tools/console-locked.sh

release-check-keychain:
	@security show-keychain-info "$(HOME)/Library/Keychains/login.keychain-db" >/dev/null 2>&1 \
		|| { $(CONSOLE_LOCKED) || echo "the login keychain is locked: unlock it (security unlock-keychain, a person's hands)" >&2; exit 1; }

# The signing path itself, run on a copy of this checkout's files in a
# directory of its own (mktemp -d), removed on exit: its project, archive and
# derived data are no other run's, so overlapping runs (a fleet tick,
# `afkconvoy plan`, a person) each give the true answer. It fails on an
# unaccepted Program License Agreement, a missing profile, no Developer ID
# identity (local or cloud-managed), or — "No Accounts" — a locked console
# session hiding Xcode's Apple account. xcodebuild prints its errors on stdout.
release-check-signing:
	@set -e; run=$$(mktemp -d -t mytokens-release-check); trap 'rm -rf "$$run"' EXIT; \
		mkdir "$$run/src"; \
		git ls-files -z --cached --others --exclude-standard | tar -cf - --null -T - | tar -xf - -C "$$run/src"; \
		$(MAKE) -s -C "$$run/src" signed >"$$run/log" 2>&1 || { \
			if $(CONSOLE_LOCKED); then locked=1; else locked=; fi; \
			grep -E 'error|PLA|agree|No profiles|No signing|No Accounts' "$$run/log" | tail -15 >&2; \
			test -n "$$locked" || echo "Developer ID signing fails on this host (see above): an account holder may have to accept the Program License Agreement at developer.apple.com, or install the Developer ID certificate" >&2; \
			exit 1; }

release-check-asc:
	@for f in "Key ID" "Issuer ID" "Key (base64 .p8)"; do \
		err=$$(mytokens get $(ASC_SECRET) --field "$$f" 2>&1 >/dev/null) \
		|| { if $(CONSOLE_LOCKED); then locked=1; else locked=; fi; \
			echo "$$err" >&2; \
			test -n "$$locked" || echo "mytokens has no '$$f' in $(ASC_SECRET) here (or its keychain is locked): store the App Store Connect key as the README says" >&2; exit 1; }; \
	done

release-check-gh:
	@gh auth status >/dev/null 2>&1 || { echo "gh is not logged in: gh auth login" >&2; exit 1; }
	@test "$$(gh api 'repos/{owner}/{repo}' --jq .permissions.push)" = true \
		|| { echo "the gh user may not push to this repo, so cannot create its Releases" >&2; exit 1; }

clean:
	rm -rf $(DERIVED) $(PROJECT)
