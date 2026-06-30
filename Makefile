APP          := MyTokens
BUNDLE       := MyTokens.app
PROJECT      := MyTokens.xcodeproj
INSTALL_DIR  := $(HOME)/Applications
BIN_DIR      := $(HOME)/.local/bin
BIN          := $(BIN_DIR)/mytokens
DERIVED      := build
PRODUCT      := $(DERIVED)/Build/Products/Release/$(BUNDLE)

.PHONY: project build install selftest verify clean

project:
	xcodegen generate

build: project
	xcodebuild -project $(PROJECT) -scheme $(APP) -configuration Release \
		-derivedDataPath $(DERIVED) -allowProvisioningUpdates build

install: build
	rm -rf "$(INSTALL_DIR)/$(BUNDLE)"
	mkdir -p "$(INSTALL_DIR)" "$(BIN_DIR)"
	cp -R "$(PRODUCT)" "$(INSTALL_DIR)/"
	ln -sf "$(INSTALL_DIR)/$(BUNDLE)/Contents/MacOS/$(APP)" "$(BIN)"
	@echo "installed: $(BIN) -> $(INSTALL_DIR)/$(BUNDLE)"

verify:
	codesign -dv --entitlements - "$(INSTALL_DIR)/$(BUNDLE)" 2>&1 | rg 'Identifier|TeamIdentifier|keychain-access-groups' || true

selftest:
	"$(BIN)" selftest

clean:
	rm -rf $(DERIVED) $(PROJECT)
