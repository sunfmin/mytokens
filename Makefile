APP          := MyTokens
BUNDLE       := MyTokens.app
PROJECT      := MyTokens.xcodeproj
INSTALL_DIR  := $(HOME)/Applications
BIN_DIR      := $(HOME)/.local/bin
BIN          := $(BIN_DIR)/mytokens
DERIVED      := build
PRODUCT      := $(DERIVED)/Build/Products/Release/$(BUNDLE)
TEAM_ID      := HL27PWAKDF
ARCHIVE      := $(DERIVED)/$(APP).xcarchive
EXPORT       := $(DERIVED)/export
DIST_ZIP     := $(DERIVED)/$(APP).zip

# Notarization uses a stored notarytool keychain profile — created once with
# `xcrun notarytool store-credentials <name>`. Signing just uses the Developer ID
# cert already in your keychain and your Xcode-logged-in account (for the profile).
NOTARY_PROFILE ?= mytokens

.PHONY: project build test install selftest verify dist release icon screenshots clean

project:
	xcodegen generate

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
	xcodebuild -project $(PROJECT) -scheme $(APP) -derivedDataPath $(DERIVED) test

install: build
	rm -rf "$(INSTALL_DIR)/$(BUNDLE)"
	mkdir -p "$(INSTALL_DIR)" "$(BIN_DIR)"
	cp -R "$(PRODUCT)" "$(INSTALL_DIR)/"
	ln -sf "$(INSTALL_DIR)/$(BUNDLE)/Contents/MacOS/$(APP)" "$(BIN)"
	@echo "installed: $(BIN) -> $(INSTALL_DIR)/$(BUNDLE)"

verify:
	codesign -dv --entitlements - "$(INSTALL_DIR)/$(BUNDLE)" 2>&1 | rg 'Identifier|TeamIdentifier|keychain-access-groups' || true

# Release build: Developer ID-signed, notarized, stapled .app zipped for GitHub
# Releases. Single source of truth for the release artifact — CI just calls this.
# The export re-signs with "Developer ID Application" and (via -allowProvisioningUpdates
# + the API key) fetches a Developer ID profile carrying the Keychain Sharing capability.
dist: project
	xcodebuild -project $(PROJECT) -scheme $(APP) -configuration Release \
		-derivedDataPath $(DERIVED) -archivePath $(ARCHIVE) \
		-allowProvisioningUpdates archive
	xcodebuild -exportArchive -archivePath $(ARCHIVE) \
		-exportOptionsPlist ExportOptions.plist -exportPath $(EXPORT) \
		-allowProvisioningUpdates
	ditto -c -k --keepParent "$(EXPORT)/$(BUNDLE)" "$(DIST_ZIP)"
	xcrun notarytool submit "$(DIST_ZIP)" --keychain-profile "$(NOTARY_PROFILE)" --wait
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

clean:
	rm -rf $(DERIVED) $(PROJECT)
