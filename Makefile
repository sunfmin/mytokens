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

# Release signing/notarization creds — App Store Connect API key (.p8). Set these
# in the environment (CI passes them from secrets); `dist` fails clearly if unset.
ASC_KEY      ?=
ASC_KEY_ID   ?=
ASC_ISSUER   ?=

.PHONY: project build test install selftest verify dist release clean

project:
	xcodegen generate

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
		-allowProvisioningUpdates \
		-authenticationKeyID $(ASC_KEY_ID) -authenticationKeyIssuerID $(ASC_ISSUER) -authenticationKeyPath $(ASC_KEY) \
		archive
	xcodebuild -exportArchive -archivePath $(ARCHIVE) \
		-exportOptionsPlist ExportOptions.plist -exportPath $(EXPORT) \
		-allowProvisioningUpdates \
		-authenticationKeyID $(ASC_KEY_ID) -authenticationKeyIssuerID $(ASC_ISSUER) -authenticationKeyPath $(ASC_KEY)
	ditto -c -k --keepParent "$(EXPORT)/$(BUNDLE)" "$(DIST_ZIP)"
	xcrun notarytool submit "$(DIST_ZIP)" \
		--key $(ASC_KEY) --key-id $(ASC_KEY_ID) --issuer $(ASC_ISSUER) --wait
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
