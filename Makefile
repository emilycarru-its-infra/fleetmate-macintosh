# FleetMate Makefile
# Builds, signs, and notarizes the FleetMate CLI and macOS app

# Load configuration from .env if it exists
ifneq (,$(wildcard ./.env))
	include .env
	export
endif

# Configuration
BINARY_NAME := fleetmate
BUILD_DIR := .build
RELEASE_DIR := $(BUILD_DIR)/release
INSTALL_DIR := /usr/local/bin
PRODUCT_NAME := FleetMate
VERSION := 1.0.0

# Signing Configuration
SIGNING_IDENTITY ?= Developer ID Application: Example Organisation (TEAMID0000)
KEYCHAIN ?=
NOTARIZATION_PROFILE ?= notarization_credentials

# App Configuration
APP_PRODUCT_NAME := FleetMateApp
APP_BUNDLE_NAME := FleetMate.app
APP_BUNDLE_EXECUTABLE := FleetMate
APP_INFO_PLIST := Sources/FleetMateApp/Info.plist
APP_ENTITLEMENTS := Sources/FleetMateApp/FleetMateApp.entitlements
APP_ICON_PNG := Sources/FleetMateApp/Assets/AppIcon.icon/Assets/FleetMate.png
APP_DIR := $(BUILD_DIR)/app
APP_BUNDLE := $(APP_DIR)/$(APP_BUNDLE_NAME)

# Build Paths
BUILD_BIN_PATH := $(shell swift build -c release --show-bin-path 2>/dev/null || echo "$(BUILD_DIR)/release")
BINARY_PATH := $(BUILD_BIN_PATH)/$(BINARY_NAME)
SIGNED_BINARY := $(BUILD_DIR)/$(BINARY_NAME)-signed
PKG_NAME := $(PRODUCT_NAME)-$(VERSION).pkg
DMG_NAME := $(PRODUCT_NAME)-$(VERSION).dmg
APP_DMG_NAME := $(PRODUCT_NAME)-App-$(VERSION).dmg

# Colors for output
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[1;33m
BLUE := \033[0;34m
NC := \033[0m # No Color

.PHONY: all build clean install uninstall sign notarize package help test debug release \
       build-app release-app sign-app notarize-app release-app-signed app-dmg

# Default target
all: release

help:
	@echo "$(BLUE)FleetMate Build System$(NC)"
	@echo ""
	@echo "$(GREEN)Available targets:$(NC)"
	@echo "  $(YELLOW)build$(NC)           - Build debug binary"
	@echo "  $(YELLOW)release$(NC)         - Build release binary (optimized)"
	@echo "  $(YELLOW)sign$(NC)            - Sign the release binary"
	@echo "  $(YELLOW)notarize$(NC)        - Notarize the signed binary"
	@echo "  $(YELLOW)package$(NC)         - Create installer package (.pkg)"
	@echo "  $(YELLOW)dmg$(NC)             - Create DMG installer"
	@echo "  $(YELLOW)install$(NC)         - Install binary to $(INSTALL_DIR)"
	@echo "  $(YELLOW)uninstall$(NC)       - Remove installed binary"
	@echo "  $(YELLOW)clean$(NC)           - Clean build artifacts"
	@echo "  $(YELLOW)test$(NC)            - Run tests"
	@echo "  $(YELLOW)all$(NC)             - Build release (default)"
	@echo ""
	@echo ""
	@echo "$(GREEN)App targets:$(NC)"
	@echo "  $(YELLOW)build-app$(NC)        - Build debug app binary"
	@echo "  $(YELLOW)release-app$(NC)      - Build release .app bundle"
	@echo "  $(YELLOW)sign-app$(NC)         - Sign the .app bundle"
	@echo "  $(YELLOW)notarize-app$(NC)     - Notarize the signed .app bundle"
	@echo "  $(YELLOW)app-dmg$(NC)          - Create DMG with the signed .app"
	@echo ""
	@echo "$(GREEN)Full workflows:$(NC)"
	@echo "  $(YELLOW)make release-signed$(NC)     - Build, sign, and notarize CLI"
	@echo "  $(YELLOW)make release-app-signed$(NC) - Build, sign, and notarize .app"
	@echo ""

# Build debug binary
build:
	@echo "$(BLUE)Building debug binary...$(NC)"
	swift build --target FleetMate
	@echo "$(GREEN)✓ Debug build complete$(NC)"

# Build release binary (optimized)
release:
	@echo "$(BLUE)Building release binary...$(NC)"
	swift build -c release --product fleetmate
	@REAL_BIN_PATH=$$(swift build -c release --show-bin-path)/$(BINARY_NAME); \
	echo "$(GREEN)✓ Release build complete: $$REAL_BIN_PATH$(NC)"; \
	file "$$REAL_BIN_PATH"

# Build and sign
release-signed: release sign notarize
	@echo "$(GREEN)✓ Release binary signed and notarized!$(NC)"

# Sign the binary
sign: release
	@echo "$(BLUE)Signing binary...$(NC)"
	@REAL_BIN_PATH=$$(swift build -c release --show-bin-path)/$(BINARY_NAME); \
	if [ ! -f "$$REAL_BIN_PATH" ]; then \
		echo "$(RED)Error: Binary not found at $$REAL_BIN_PATH$(NC)"; \
		exit 1; \
	fi; \
	if [ -n "$(KEYCHAIN)" ]; then \
		security unlock-keychain "$(KEYCHAIN)" || true; \
		codesign --force --sign "$(SIGNING_IDENTITY)" \
			--options runtime \
			--timestamp \
			--keychain "$(KEYCHAIN)" \
			"$$REAL_BIN_PATH"; \
	else \
		codesign --force --sign "$(SIGNING_IDENTITY)" \
			--options runtime \
			--timestamp \
			"$$REAL_BIN_PATH"; \
	fi; \
	codesign --verify --verbose "$$REAL_BIN_PATH"
	@echo "$(GREEN)✓ Binary signed successfully$(NC)"
	@REAL_BIN_PATH=$$(swift build -c release --show-bin-path)/$(BINARY_NAME); \
	codesign -dvvv "$$REAL_BIN_PATH" 2>&1 | grep -E "Authority|TeamIdentifier|Timestamp"

# Notarize the binary
notarize: sign
	@echo "$(BLUE)Notarizing binary...$(NC)"
	@if [ -z "$(NOTARIZATION_PROFILE)" ]; then \
		echo "$(RED)Error: NOTARIZATION_PROFILE not set$(NC)"; \
		echo "Set up notarization profile with:"; \
		echo "  xcrun notarytool store-credentials"; \
		exit 1; \
	fi
	@REAL_BIN_PATH=$$(swift build -c release --show-bin-path)/$(BINARY_NAME); \
	echo "Creating notarization archive..."; \
	mkdir -p $(BUILD_DIR)/notarize; \
	cp "$$REAL_BIN_PATH" "$(BUILD_DIR)/notarize/$(BINARY_NAME)"; \
	ditto -c -k --keepParent "$(BUILD_DIR)/notarize/$(BINARY_NAME)" "$(BUILD_DIR)/$(BINARY_NAME)-notarize.zip"; \
	echo "Submitting to Apple notary service..."; \
	xcrun notarytool submit "$(BUILD_DIR)/$(BINARY_NAME)-notarize.zip" \
		--keychain-profile "$(NOTARIZATION_PROFILE)" \
		--wait; \
	echo "Stapling notarization ticket..."; \
	xcrun stapler staple "$$REAL_BIN_PATH" || echo "$(YELLOW)Note: Stapling may not work for executables$(NC)"; \
	rm -rf "$(BUILD_DIR)/notarize" "$(BUILD_DIR)/$(BINARY_NAME)-notarize.zip"
	@echo "$(GREEN)✓ Binary notarized successfully$(NC)"

# ==============================================================================
# App Bundle Targets
# ==============================================================================

# Build debug app binary
build-app:
	@echo "$(BLUE)Building debug app binary...$(NC)"
	swift build --product $(APP_PRODUCT_NAME)
	@echo "$(GREEN)✓ Debug app build complete$(NC)"

# Build release app and assemble .app bundle
release-app:
	@echo "$(BLUE)Building release app binary...$(NC)"
	swift build -c release --product $(APP_PRODUCT_NAME)
	@REAL_BIN_PATH=$$(swift build -c release --show-bin-path)/$(APP_PRODUCT_NAME); \
	echo "$(GREEN)✓ App binary built: $$REAL_BIN_PATH$(NC)"; \
	echo "$(BLUE)Assembling .app bundle...$(NC)"; \
	rm -rf "$(APP_BUNDLE)"; \
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"; \
	mkdir -p "$(APP_BUNDLE)/Contents/Resources"; \
	cp "$$REAL_BIN_PATH" "$(APP_BUNDLE)/Contents/MacOS/$(APP_BUNDLE_EXECUTABLE)"; \
	cp "$(APP_INFO_PLIST)" "$(APP_BUNDLE)/Contents/Info.plist"; \
	echo "$(BLUE)Generating .icns from icon PNG...$(NC)"; \
	ICONSET_DIR=$$(mktemp -d)/AppIcon.iconset; \
	mkdir -p "$$ICONSET_DIR"; \
	sips -z 16 16     "$(APP_ICON_PNG)" --out "$$ICONSET_DIR/icon_16x16.png"      > /dev/null 2>&1; \
	sips -z 32 32     "$(APP_ICON_PNG)" --out "$$ICONSET_DIR/icon_16x16@2x.png"   > /dev/null 2>&1; \
	sips -z 32 32     "$(APP_ICON_PNG)" --out "$$ICONSET_DIR/icon_32x32.png"      > /dev/null 2>&1; \
	sips -z 64 64     "$(APP_ICON_PNG)" --out "$$ICONSET_DIR/icon_32x32@2x.png"   > /dev/null 2>&1; \
	sips -z 128 128   "$(APP_ICON_PNG)" --out "$$ICONSET_DIR/icon_128x128.png"    > /dev/null 2>&1; \
	sips -z 256 256   "$(APP_ICON_PNG)" --out "$$ICONSET_DIR/icon_128x128@2x.png" > /dev/null 2>&1; \
	sips -z 256 256   "$(APP_ICON_PNG)" --out "$$ICONSET_DIR/icon_256x256.png"    > /dev/null 2>&1; \
	sips -z 512 512   "$(APP_ICON_PNG)" --out "$$ICONSET_DIR/icon_256x256@2x.png" > /dev/null 2>&1; \
	sips -z 512 512   "$(APP_ICON_PNG)" --out "$$ICONSET_DIR/icon_512x512.png"    > /dev/null 2>&1; \
	sips -z 1024 1024 "$(APP_ICON_PNG)" --out "$$ICONSET_DIR/icon_512x512@2x.png" > /dev/null 2>&1; \
	iconutil -c icns "$$ICONSET_DIR" -o "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"; \
	rm -rf "$$(dirname $$ICONSET_DIR)"
	@echo "$(GREEN)✓ App bundle assembled: $(APP_BUNDLE)$(NC)"

# Sign the .app bundle
sign-app: release-app
	@echo "$(BLUE)Signing .app bundle...$(NC)"
	@if [ ! -d "$(APP_BUNDLE)" ]; then \
		echo "$(RED)Error: App bundle not found at $(APP_BUNDLE)$(NC)"; \
		exit 1; \
	fi; \
	if [ -n "$(KEYCHAIN)" ]; then \
		security unlock-keychain "$(KEYCHAIN)" || true; \
		codesign --force --deep --sign "$(SIGNING_IDENTITY)" \
			--options runtime \
			--timestamp \
			--entitlements "$(APP_ENTITLEMENTS)" \
			--keychain "$(KEYCHAIN)" \
			"$(APP_BUNDLE)"; \
	else \
		codesign --force --deep --sign "$(SIGNING_IDENTITY)" \
			--options runtime \
			--timestamp \
			--entitlements "$(APP_ENTITLEMENTS)" \
			"$(APP_BUNDLE)"; \
	fi; \
	codesign --verify --verbose "$(APP_BUNDLE)"
	@echo "$(GREEN)✓ App bundle signed successfully$(NC)"
	@codesign -dvvv "$(APP_BUNDLE)" 2>&1 | grep -E "Authority|TeamIdentifier|Timestamp"

# Notarize the .app bundle
notarize-app: sign-app
	@echo "$(BLUE)Notarizing .app bundle...$(NC)"
	@if [ -z "$(NOTARIZATION_PROFILE)" ]; then \
		echo "$(RED)Error: NOTARIZATION_PROFILE not set$(NC)"; \
		echo "Set up notarization profile with:"; \
		echo "  xcrun notarytool store-credentials"; \
		exit 1; \
	fi
	@echo "Creating notarization archive..."; \
	ditto -c -k --keepParent "$(APP_BUNDLE)" "$(BUILD_DIR)/$(PRODUCT_NAME)-App-notarize.zip"; \
	echo "Submitting to Apple notary service..."; \
	xcrun notarytool submit "$(BUILD_DIR)/$(PRODUCT_NAME)-App-notarize.zip" \
		--keychain-profile "$(NOTARIZATION_PROFILE)" \
		--wait; \
	echo "Stapling notarization ticket..."; \
	xcrun stapler staple "$(APP_BUNDLE)"; \
	rm -f "$(BUILD_DIR)/$(PRODUCT_NAME)-App-notarize.zip"
	@echo "$(GREEN)✓ App bundle notarized successfully$(NC)"

# Build, sign, and notarize the .app
release-app-signed: release-app sign-app notarize-app
	@echo "$(GREEN)✓ App bundle signed and notarized: $(APP_BUNDLE)$(NC)"

# Create DMG with the signed .app
app-dmg: sign-app
	@echo "$(BLUE)Creating app DMG...$(NC)"
	@mkdir -p $(BUILD_DIR)/app-dmg
	@cp -R "$(APP_BUNDLE)" "$(BUILD_DIR)/app-dmg/"
	@ln -sf /Applications "$(BUILD_DIR)/app-dmg/Applications"
	hdiutil create -volname "$(PRODUCT_NAME) $(VERSION)" \
		-srcfolder "$(BUILD_DIR)/app-dmg" \
		-ov -format UDZO \
		"$(BUILD_DIR)/$(APP_DMG_NAME)"
	@rm -rf "$(BUILD_DIR)/app-dmg"
	@echo "$(GREEN)✓ App DMG created: $(BUILD_DIR)/$(APP_DMG_NAME)$(NC)"

# ==============================================================================
# CLI Packaging Targets
# ==============================================================================

# Create installer package
package: sign
	@echo "$(BLUE)Creating installer package...$(NC)"
	@mkdir -p $(BUILD_DIR)/pkg/root$(INSTALL_DIR)
	@mkdir -p $(BUILD_DIR)/pkg/scripts
	@cp "$(BINARY_PATH)" "$(BUILD_DIR)/pkg/root$(INSTALL_DIR)/$(BINARY_NAME)"
	@# Create postinstall script
	@echo '#!/bin/bash' > $(BUILD_DIR)/pkg/scripts/postinstall
	@echo 'chmod +x $(INSTALL_DIR)/$(BINARY_NAME)' >> $(BUILD_DIR)/pkg/scripts/postinstall
	@echo 'echo "FleetMate installed to $(INSTALL_DIR)/$(BINARY_NAME)"' >> $(BUILD_DIR)/pkg/scripts/postinstall
	@chmod +x $(BUILD_DIR)/pkg/scripts/postinstall
	@# Build the package
	pkgbuild --root "$(BUILD_DIR)/pkg/root" \
		--scripts "$(BUILD_DIR)/pkg/scripts" \
		--identifier "ca.ecuad.its.fleetmate" \
		--version "$(VERSION)" \
		--install-location "/" \
		"$(BUILD_DIR)/$(BINARY_NAME)-unsigned.pkg"
	@# Sign the package
	productsign --sign "$(SIGNING_IDENTITY)" \
		--keychain "$(KEYCHAIN)" \
		"$(BUILD_DIR)/$(BINARY_NAME)-unsigned.pkg" \
		"$(BUILD_DIR)/$(PKG_NAME)"
	@rm "$(BUILD_DIR)/$(BINARY_NAME)-unsigned.pkg"
	@echo "$(GREEN)✓ Package created: $(BUILD_DIR)/$(PKG_NAME)$(NC)"

# Notarize the package
notarize-package: package
	@echo "$(BLUE)Notarizing package...$(NC)"
	xcrun notarytool submit "$(BUILD_DIR)/$(PKG_NAME)" \
		--keychain-profile "$(NOTARIZATION_PROFILE)" \
		--wait
	@# Staple the notarization
	xcrun stapler staple "$(BUILD_DIR)/$(PKG_NAME)"
	@echo "$(GREEN)✓ Package notarized: $(BUILD_DIR)/$(PKG_NAME)$(NC)"

# Create DMG installer
dmg: package
	@echo "$(BLUE)Creating DMG installer...$(NC)"
	@mkdir -p $(BUILD_DIR)/dmg
	@cp "$(BUILD_DIR)/$(PKG_NAME)" "$(BUILD_DIR)/dmg/"
	@# Create README
	@echo "# FleetMate v$(VERSION)" > $(BUILD_DIR)/dmg/README.txt
	@echo "" >> $(BUILD_DIR)/dmg/README.txt
	@echo "Installation:" >> $(BUILD_DIR)/dmg/README.txt
	@echo "Double-click $(PKG_NAME) to install" >> $(BUILD_DIR)/dmg/README.txt
	@echo "" >> $(BUILD_DIR)/dmg/README.txt
	@echo "Manual installation:" >> $(BUILD_DIR)/dmg/README.txt
	@echo "sudo installer -pkg $(PKG_NAME) -target /" >> $(BUILD_DIR)/dmg/README.txt
	@# Create DMG
	hdiutil create -volname "$(PRODUCT_NAME) $(VERSION)" \
		-srcfolder "$(BUILD_DIR)/dmg" \
		-ov -format UDZO \
		"$(BUILD_DIR)/$(DMG_NAME)"
	@echo "$(GREEN)✓ DMG created: $(BUILD_DIR)/$(DMG_NAME)$(NC)"

# Install binary locally
install: release
	@echo "$(BLUE)Installing FleetMate...$(NC)"
	@sudo mkdir -p $(INSTALL_DIR)
	@sudo cp "$(BINARY_PATH)" "$(INSTALL_DIR)/$(BINARY_NAME)"
	@REAL_BIN_PATH=$$(swift build -c release --show-bin-path)/$(BINARY_NAME); \
	sudo mkdir -p $(INSTALL_DIR); \
	sudo cp "$$REAL_BIN_PATH" "$(INSTALL_DIR)/$(BINARY_NAME)"; \
	$(INSTALL_DIR)/$(BINARY_NAME) --version

# Uninstall binary
uninstall:
	@echo "$(BLUE)Uninstalling FleetMate...$(NC)"
	@sudo rm -f "$(INSTALL_DIR)/$(BINARY_NAME)"
	@echo "$(GREEN)✓ Uninstalled$(NC)"

# Run tests
test:
	@echo "$(BLUE)Running tests...$(NC)"
	swift test

# Clean build artifacts
clean:
	@echo "$(BLUE)Cleaning build artifacts...$(NC)"
	@swift package clean
	@rm -rf $(BUILD_DIR)
	@rm -rf $(APP_DIR)
	@echo "$(GREEN)✓ Clean complete$(NC)"

# Show current configuration
config:
	@echo "$(BLUE)Current Configuration:$(NC)"
	@echo "  Product Name:      $(PRODUCT_NAME)"
	@echo "  Version:           $(VERSION)"
	@echo "  Binary Name:       $(BINARY_NAME)"
	@echo "  Install Directory: $(INSTALL_DIR)"
	@echo ""
	@echo "$(BLUE)Signing Configuration:$(NC)"
	@echo "  Identity:          $(SIGNING_IDENTITY)"
	@echo "  Keychain:          $(KEYCHAIN)"
	@echo "  Notary Profile:    $(NOTARIZATION_PROFILE)"
	@echo ""
	@echo "$(BLUE)Build Paths:$(NC)"
	@echo "  CLI Binary:        $(BINARY_PATH)"
	@echo "  App Bundle:        $(APP_BUNDLE)"
	@echo "  Package:           $(BUILD_DIR)/$(PKG_NAME)"
	@echo "  CLI DMG:           $(BUILD_DIR)/$(DMG_NAME)"
	@echo "  App DMG:           $(BUILD_DIR)/$(APP_DMG_NAME)"

# Verify signing setup
verify-signing:
	@echo "$(BLUE)Verifying signing configuration...$(NC)"
	@echo ""
	@echo "Checking for signing identity..."
	@security find-identity -v -p codesigning "$(KEYCHAIN)" | grep "$(SIGNING_IDENTITY)" && \
		echo "$(GREEN)✓ Signing identity found$(NC)" || \
		echo "$(RED)✗ Signing identity not found$(NC)"
	@echo ""
	@echo "Checking notarization profile..."
	@xcrun notarytool history --keychain-profile "$(NOTARIZATION_PROFILE)" 2>/dev/null && \
		echo "$(GREEN)✓ Notarization profile configured$(NC)" || \
		echo "$(RED)✗ Notarization profile not found$(NC)"

# Quick development build and run
run: build
	@echo "$(BLUE)Running FleetMate...$(NC)"
	@swift run $(BINARY_NAME) $(ARGS)

# Development workflow
dev: build
	@echo "$(GREEN)✓ Development build ready$(NC)"
	@echo "Run with: swift run $(BINARY_NAME) [args]"

.DEFAULT_GOAL := help
