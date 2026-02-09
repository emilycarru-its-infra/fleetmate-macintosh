#!/usr/bin/make -f
#
# FleetMate macOS Build System
# Builds, signs, notarizes, and packages the FleetMate .app bundle
#

# Load environment variables from .env file if it exists
-include .env
export

# Version from environment or generate timestamp
VERSION ?= $(shell date '+%Y.%m.%d.%H%M')

# App Configuration
APP_NAME = FleetMate
BUNDLE_ID = ca.ecuad.macadmin.fleetmate
EXECUTABLE_NAME = FleetMateApp

# Paths
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS_DIR = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS_DIR)/MacOS
RESOURCES_DIR = $(CONTENTS_DIR)/Resources
ENTITLEMENTS = Sources/FleetMateApp/FleetMateApp.entitlements
INFO_PLIST = Sources/FleetMateApp/Info.plist

# Swift Build Configuration
SWIFT_BUILD_DIR_RELEASE = .build/apple/Products/Release
SWIFT_BUILD_DIR_DEBUG = .build/debug
SWIFT_BINARY_RELEASE = $(SWIFT_BUILD_DIR_RELEASE)/$(EXECUTABLE_NAME)
SWIFT_BINARY_DEBUG = $(SWIFT_BUILD_DIR_DEBUG)/$(EXECUTABLE_NAME)

# Package Configuration
PKG_NAME = $(APP_NAME)-$(VERSION).pkg
PKG_OUTPUT = $(BUILD_DIR)/$(PKG_NAME)
DMG_NAME = $(APP_NAME)-$(VERSION).dmg
DMG_OUTPUT = $(BUILD_DIR)/$(DMG_NAME)

# Signing Configuration (loaded from .env)
# SIGNING_IDENTITY_APP - Developer ID Application certificate
# SIGNING_IDENTITY_PKG - Developer ID Installer certificate
# NOTARIZATION_PROFILE - Notarytool keychain profile name
# NOTARIZATION_TEAM_ID - Apple Developer Team ID

# Colors
RED = \033[0;31m
GREEN = \033[0;32m
YELLOW = \033[1;33m
BLUE = \033[0;34m
NC = \033[0m

.PHONY: all build release debug run clean sign-app sign-debug notarize verify \
        build-pkg sign-pkg build-dmg help check-signing-config app-bundle \
        app-bundle-debug swift-build swift-build-debug

all: build

help:
	@echo "FleetMate macOS Build System"
	@echo ""
	@echo "Targets:"
	@echo "  build           - Build, sign, and notarize release .app (default)"
	@echo "  release         - Build universal release binary"
	@echo "  debug           - Build debug binary and sign with entitlements"
	@echo "  run             - Build debug, sign, and launch"
	@echo "  app-bundle      - Create release .app bundle (unsigned)"
	@echo "  sign-app        - Sign the release .app bundle"
	@echo "  notarize        - Notarize and staple the .app (zipped)"
	@echo "  verify          - Verify signature and notarization"
	@echo "  build-pkg       - Build signed installer .pkg"
	@echo "  build-dmg       - Build signed .dmg disk image"
	@echo "  clean           - Remove build artifacts"
	@echo ""
	@echo "Development:"
	@echo "  debug           - Build debug + sign with entitlements (for PSSO)"
	@echo "  run             - Build debug + sign + launch"
	@echo ""
	@echo "Configuration:"
	@echo "  Create a .env file with your signing credentials"
	@echo ""
	@echo "Required Variables (set in .env or environment):"
	@echo "  SIGNING_IDENTITY_APP    - Developer ID Application cert"
	@echo "  SIGNING_IDENTITY_PKG    - Developer ID Installer cert"
	@echo "  NOTARIZATION_PROFILE    - Notarytool profile name"
	@echo "  NOTARIZATION_TEAM_ID    - Apple Developer Team ID"
	@echo ""
	@echo "Optional Variables:"
	@echo "  VERSION                 - App version (default: timestamp)"

# ─── Validation ──────────────────────────────────────────────────────

check-signing-config:
	@if [ -z "$(SIGNING_IDENTITY_APP)" ]; then \
		echo "$(RED)✗ Error: SIGNING_IDENTITY_APP not set$(NC)"; \
		echo "$(YELLOW)Create a .env file with your signing credentials$(NC)"; \
		exit 1; \
	fi
	@echo "$(GREEN)✓ Signing identity: $(SIGNING_IDENTITY_APP)$(NC)"

check-notarize-config: check-signing-config
	@if [ -z "$(SIGNING_IDENTITY_PKG)" ]; then \
		echo "$(RED)✗ Error: SIGNING_IDENTITY_PKG not set$(NC)"; \
		exit 1; \
	fi
	@if [ -z "$(NOTARIZATION_PROFILE)" ]; then \
		echo "$(RED)✗ Error: NOTARIZATION_PROFILE not set$(NC)"; \
		exit 1; \
	fi
	@if [ -z "$(NOTARIZATION_TEAM_ID)" ]; then \
		echo "$(RED)✗ Error: NOTARIZATION_TEAM_ID not set$(NC)"; \
		exit 1; \
	fi
	@echo "$(GREEN)✓ Notarization configuration validated$(NC)"

# ─── Swift Build ─────────────────────────────────────────────────────

swift-build:
	@echo "$(BLUE)Building Swift binary (universal release)...$(NC)"
	swift build -c release --arch arm64 --arch x86_64
	@echo "$(GREEN)✓ Release build complete$(NC)"

swift-build-debug:
	@echo "$(BLUE)Building Swift binary (debug)...$(NC)"
	swift build
	@echo "$(GREEN)✓ Debug build complete$(NC)"

release: swift-build

# ─── App Bundle ──────────────────────────────────────────────────────

app-bundle: swift-build
	@echo "$(BLUE)Creating release app bundle...$(NC)"
	@mkdir -p "$(MACOS_DIR)" "$(RESOURCES_DIR)"
	@cp "$(SWIFT_BINARY_RELEASE)" "$(MACOS_DIR)/$(APP_NAME)"
	@chmod +x "$(MACOS_DIR)/$(APP_NAME)"
	@echo -n "APPL????" > "$(CONTENTS_DIR)/PkgInfo"
	@sed 's/<string>1.0.0<\/string>/<string>$(VERSION)<\/string>/' "$(INFO_PLIST)" \
		> "$(CONTENTS_DIR)/Info.plist"
	@if [ -f "FleetMate.app/Contents/Resources/AppIcon.icns" ]; then \
		cp "FleetMate.app/Contents/Resources/AppIcon.icns" "$(RESOURCES_DIR)/"; \
	fi
	@touch "$(APP_BUNDLE)"
	@echo "$(GREEN)✓ App bundle created: $(APP_BUNDLE)$(NC)"

app-bundle-debug: swift-build-debug
	@echo "$(BLUE)Creating debug app bundle...$(NC)"
	@mkdir -p "$(MACOS_DIR)" "$(RESOURCES_DIR)"
	@cp "$(SWIFT_BINARY_DEBUG)" "$(MACOS_DIR)/$(APP_NAME)"
	@chmod +x "$(MACOS_DIR)/$(APP_NAME)"
	@echo -n "APPL????" > "$(CONTENTS_DIR)/PkgInfo"
	@cp "$(INFO_PLIST)" "$(CONTENTS_DIR)/Info.plist"
	@if [ -f "FleetMate.app/Contents/Resources/AppIcon.icns" ]; then \
		cp "FleetMate.app/Contents/Resources/AppIcon.icns" "$(RESOURCES_DIR)/"; \
	fi
	@touch "$(APP_BUNDLE)"
	@echo "$(GREEN)✓ Debug app bundle created: $(APP_BUNDLE)$(NC)"

# ─── Signing ─────────────────────────────────────────────────────────

sign-app: check-signing-config app-bundle
	@echo "$(BLUE)Signing app bundle with entitlements...$(NC)"
	@codesign --force --sign "$(SIGNING_IDENTITY_APP)" \
		--options runtime \
		--timestamp \
		--deep \
		--entitlements "$(ENTITLEMENTS)" \
		"$(APP_BUNDLE)"
	@echo "$(GREEN)✓ App bundle signed$(NC)"
	@codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)" 2>&1 | tail -3

sign-debug: app-bundle-debug
	@echo "$(BLUE)Signing debug app bundle with ad-hoc signature...$(NC)"
	@codesign --force --sign - \
		--entitlements "$(ENTITLEMENTS)" \
		"$(APP_BUNDLE)"
	@echo "$(GREEN)✓ Debug app bundle signed (entitlements applied for SSO)$(NC)"
	@codesign --display --entitlements - "$(APP_BUNDLE)" 2>&1 | grep -A 5 "com.apple"

# ─── Development ─────────────────────────────────────────────────────

debug: sign-debug
	@echo ""
	@echo "$(GREEN)✓ Debug build ready: $(APP_BUNDLE)$(NC)"
	@echo "  Run with: open $(APP_BUNDLE)"
	@echo "  Or:       $(MACOS_DIR)/$(APP_NAME)"

run: sign-debug
	@echo "$(BLUE)Launching FleetMate...$(NC)"
	@open "$(APP_BUNDLE)"

# ─── Full Release Build ─────────────────────────────────────────────

build: check-notarize-config sign-app notarize verify
	@echo ""
	@echo "$(GREEN)✓ Release build complete: $(APP_BUNDLE)$(NC)"

# ─── Notarization ───────────────────────────────────────────────────

notarize: sign-app
	@echo "$(BLUE)Creating zip for notarization...$(NC)"
	@cd "$(BUILD_DIR)" && ditto -c -k --keepParent "$(APP_NAME).app" "$(APP_NAME).zip"
	@echo "$(BLUE)Submitting for notarization (this may take several minutes)...$(NC)"
	@xcrun notarytool submit "$(BUILD_DIR)/$(APP_NAME).zip" \
		--keychain-profile "$(NOTARIZATION_PROFILE)" \
		--wait
	@echo "$(BLUE)Stapling notarization ticket...$(NC)"
	@xcrun stapler staple "$(APP_BUNDLE)"
	@rm -f "$(BUILD_DIR)/$(APP_NAME).zip"
	@echo "$(GREEN)✓ App notarized and stapled$(NC)"

# ─── Packaging ──────────────────────────────────────────────────────

build-pkg: check-notarize-config sign-app
	@echo "$(BLUE)Building installer package...$(NC)"
	@mkdir -p "$(BUILD_DIR)/pkg-root/Applications"
	@cp -R "$(APP_BUNDLE)" "$(BUILD_DIR)/pkg-root/Applications/"
	@pkgbuild \
		--root "$(BUILD_DIR)/pkg-root" \
		--identifier "$(BUNDLE_ID).pkg" \
		--version "$(VERSION)" \
		"$(PKG_OUTPUT).unsigned"
	@echo "$(BLUE)Signing installer package...$(NC)"
	@productsign \
		--sign "$(SIGNING_IDENTITY_PKG)" \
		--timestamp \
		"$(PKG_OUTPUT).unsigned" \
		"$(PKG_OUTPUT)"
	@rm -f "$(PKG_OUTPUT).unsigned"
	@rm -rf "$(BUILD_DIR)/pkg-root"
	@echo "$(BLUE)Notarizing package...$(NC)"
	@xcrun notarytool submit "$(PKG_OUTPUT)" \
		--keychain-profile "$(NOTARIZATION_PROFILE)" \
		--wait
	@xcrun stapler staple "$(PKG_OUTPUT)"
	@echo "$(GREEN)✓ Package built, signed, and notarized: $(PKG_OUTPUT)$(NC)"

build-dmg: check-notarize-config sign-app
	@echo "$(BLUE)Building DMG disk image...$(NC)"
	@mkdir -p "$(BUILD_DIR)/dmg-staging"
	@cp -R "$(APP_BUNDLE)" "$(BUILD_DIR)/dmg-staging/"
	@ln -sf /Applications "$(BUILD_DIR)/dmg-staging/Applications"
	@hdiutil create -volname "$(APP_NAME)" \
		-srcfolder "$(BUILD_DIR)/dmg-staging" \
		-ov -format UDZO \
		"$(DMG_OUTPUT)"
	@rm -rf "$(BUILD_DIR)/dmg-staging"
	@echo "$(BLUE)Signing DMG...$(NC)"
	@codesign --force --sign "$(SIGNING_IDENTITY_APP)" \
		--timestamp \
		"$(DMG_OUTPUT)"
	@echo "$(BLUE)Notarizing DMG...$(NC)"
	@xcrun notarytool submit "$(DMG_OUTPUT)" \
		--keychain-profile "$(NOTARIZATION_PROFILE)" \
		--wait
	@xcrun stapler staple "$(DMG_OUTPUT)"
	@echo "$(GREEN)✓ DMG built, signed, and notarized: $(DMG_OUTPUT)$(NC)"

# ─── Verification ───────────────────────────────────────────────────

verify:
	@echo "$(BLUE)Verifying app security...$(NC)"
	@echo ""
	@echo "Code signature:"
	@codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)" 2>&1 | tail -5
	@echo ""
	@echo "Entitlements:"
	@codesign -d --entitlements - "$(APP_BUNDLE)" 2>/dev/null | head -20
	@echo ""
	@echo "Notarization:"
	@xcrun stapler validate "$(APP_BUNDLE)" 2>&1 || echo "$(YELLOW)⚠ Not notarized (run 'make notarize' first)$(NC)"
	@echo ""
	@echo "Gatekeeper:"
	@spctl --assess --type execute "$(APP_BUNDLE)" 2>&1 || echo "$(YELLOW)⚠ Will not pass Gatekeeper (needs notarization)$(NC)"
	@echo ""
	@echo "$(GREEN)✓ Verification complete$(NC)"

# ─── Clean ──────────────────────────────────────────────────────────

clean:
	@echo "$(YELLOW)Cleaning build artifacts...$(NC)"
	@rm -rf "$(BUILD_DIR)" || true
	@chmod -R u+w .build 2>/dev/null || true
	@rm -rf .build || true
	@echo "$(GREEN)✓ Clean complete$(NC)"
