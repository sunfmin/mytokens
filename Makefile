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

# The App Store Connect API key (tools/asc-key.sh, ADR-0017): from the
# environment when ASC_KEY_P8_BASE64 is set (GitHub Actions, with ASC_KEY_ID and
# ASC_ISSUER_ID), else from mytokens itself (dogfooding): the Secret
# $(ASC_SECRET) with fields "Key ID", "Issuer ID", "Key (base64 .p8)". It
# notarizes; in Actions it also lets Xcode fetch the Developer ID profile, where
# by hand signing uses your Xcode-logged-in account.
export ASC_SECRET
ASC_SECRET ?= asc-api-key

# XcodeGen and mise, pinned: every build and the gate use these versions.
# `make xcodegen-install` installs both under $HOME when they are absent.
XCODEGEN_VERSION := 2.46.0
MISE_VERSION := 2026.10.15
MISE := $(shell command -v mise 2>/dev/null || printf '%s\n' '$(BIN_DIR)/mise')
XCODEGEN := "$(MISE)" exec xcodegen@$(XCODEGEN_VERSION) -- xcodegen

.PHONY: project build test install selftest verify signed dist release icon screenshots clean xcodegen-check xcodegen-install \
	release-verify release-wait set-version installed-version-check release-check-gh

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
	tools/asc-key-test.sh
	tools/release-wait-test.sh
	tools/signing-keychain-test.sh
	tools/xctest-run-test.sh
	xcodebuild -project $(PROJECT) -scheme $(APP) -derivedDataPath $(DERIVED) build-for-testing
	tools/xctest-run.sh $(TEST_BUNDLE)

install: build
	rm -rf "$(INSTALL_DIR)/$(BUNDLE)"
	mkdir -p "$(INSTALL_DIR)" "$(BIN_DIR)"
	cp -R "$(PRODUCT)" "$(INSTALL_DIR)/"
	ln -sf "$(INSTALL_DIR)/$(BUNDLE)/Contents/MacOS/$(APP)" "$(BIN)"
	@echo "installed: $(BIN) -> $(INSTALL_DIR)/$(BUNDLE)"
	"$(BIN)" server agent || echo "note: background sync agent not set up (run: mytokens server agent)"

verify:
	codesign -dv --entitlements - "$(INSTALL_DIR)/$(BUNDLE)" 2>&1 | rg 'Identifier|TeamIdentifier|keychain-access-groups' || true

# The Developer ID-signed .app, not yet notarized: archive, then export it
# re-signed with "Developer ID Application" (a local identity or Xcode's
# cloud-managed one), with -allowProvisioningUpdates fetching a Developer ID
# profile carrying the Keychain Sharing capability. By hand xcodebuild uses your
# Xcode-logged-in account; with ASC_KEY_P8_BASE64 set (GitHub Actions, where no
# account is signed in) it authenticates with the API key instead, its .p8 in a
# mktemp -d directory removed on exit. With SIGN_KEYCHAIN set (GitHub Actions:
# the keychain tools/signing-keychain.sh made from the Developer ID .p12), the
# archive is signed with that keychain's Developer ID Application identity
# rather than an Apple Development one Xcode would create through the key.
SIGN_KEYCHAIN ?=
signed: project
	@set -e; auth=; set --; \
	if [ -n "$(SIGN_KEYCHAIN)" ]; then \
		set -- CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Developer ID Application" "OTHER_CODE_SIGN_FLAGS=--keychain $(SIGN_KEYCHAIN)"; \
	fi; \
	if [ -n "$${ASC_KEY_P8_BASE64:-}" ]; then \
		key=$$(mktemp -d); trap 'rm -rf "$$key"' EXIT; tools/asc-key.sh "$$key"; \
		auth="-authenticationKeyPath $$key/AuthKey.p8 -authenticationKeyID $$(cat "$$key/key-id") -authenticationKeyIssuerID $$(cat "$$key/issuer-id")"; \
	fi; \
	xcodebuild -project $(PROJECT) -scheme $(APP) -configuration Release \
		-derivedDataPath $(DERIVED) -archivePath $(ARCHIVE) \
		-allowProvisioningUpdates $$auth "$$@" archive; \
	xcodebuild -exportArchive -archivePath $(ARCHIVE) \
		-exportOptionsPlist ExportOptions.plist -exportPath $(EXPORT) \
		-allowProvisioningUpdates $$auth

# Release build: Developer ID-signed, notarized, stapled and verified .app zipped
# for GitHub Releases. The one release path: the Actions workflow
# (.github/workflows/release.yml) and a person by hand both run it (ADR-0017).
dist: signed
	ditto -c -k --keepParent "$(EXPORT)/$(BUNDLE)" "$(DIST_ZIP)"
	@set -e; key=$$(mktemp -d); trap 'rm -rf "$$key"' EXIT; tools/asc-key.sh "$$key"; \
		xcrun notarytool submit "$(DIST_ZIP)" --key "$$key/AuthKey.p8" \
			--key-id "$$(cat "$$key/key-id")" --issuer "$$(cat "$$key/issuer-id")" --wait
	xcrun stapler staple "$(EXPORT)/$(BUNDLE)"
	$(MAKE) -s release-verify
	ditto -c -k --keepParent "$(EXPORT)/$(BUNDLE)" "$(DIST_ZIP)"
	@echo "dist: $(DIST_ZIP) (Developer ID-signed, notarized, stapled, verified)"

# What a Release may serve: the signature holds, Gatekeeper accepts the app as
# notarized Developer ID, its ticket is stapled, and it carries the
# keychain-access-groups entitlement the iCloud Keychain needs (ADR-0001).
RELEASE_APP ?= $(EXPORT)/$(BUNDLE)
release-verify:
	codesign --verify --deep --strict --verbose=2 "$(RELEASE_APP)"
	@spctl --assess --type execute --verbose=4 "$(RELEASE_APP)" 2>&1 | tee /dev/stderr | grep -q 'source=Notarized Developer ID' \
		|| { echo "release-verify: Gatekeeper does not accept $(RELEASE_APP) as notarized Developer ID" >&2; exit 1; }
	xcrun stapler validate "$(RELEASE_APP)"
	@codesign -d --entitlements - --xml "$(RELEASE_APP)" 2>/dev/null | grep -q keychain-access-groups \
		|| { echo "release-verify: $(RELEASE_APP) lacks the keychain-access-groups entitlement" >&2; exit 1; }
	@echo "release-verify: $(RELEASE_APP) is signed, notarized, stapled and entitled"

# Publish: build the verified zip and upload it to the Release of TAG, an
# existing tag. The release workflow runs it on a pushed v* tag; by hand it
# needs `gh` authenticated and the mytokens Secret above. `scripts/install.sh`
# downloads MyTokens.zip from the latest Release, so each version is a new TAG.
release:
	@test -n "$(TAG)" || { echo "usage: make release TAG=v0.1.0" >&2; exit 2; }
	$(MAKE) dist
	gh release create "$(TAG)" "$(DIST_ZIP)" --verify-tag --generate-notes \
		|| gh release upload "$(TAG)" "$(DIST_ZIP)" --clobber
	@echo "released $(TAG): $(DIST_ZIP)"

# A cut's `publish` (docs/agents/afkconvoy.md): the cut pushed the tag TAG; wait
# for the release workflow's run on it, failing when that run fails.
release-wait:
	@test -n "$(TAG)" || { echo "usage: make release-wait TAG=v0.1.0" >&2; exit 2; }
	tools/release-wait.sh "$(TAG)"

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

# What a cut needs on a host (docs/agents/afkconvoy.md, the cut-needs block):
# `gh`, logged in as a user who may push, to watch the tag's release run and
# download the Release. Building and signing are the workflow's (ADR-0017).
release-check-gh:
	@gh auth status >/dev/null 2>&1 || { echo "gh is not logged in: gh auth login" >&2; exit 1; }
	@test "$$(gh api 'repos/{owner}/{repo}' --jq .permissions.push)" = true \
		|| { echo "the gh user may not push to this repo, so cannot cut its Releases" >&2; exit 1; }

clean:
	rm -rf $(DERIVED) $(PROJECT)
