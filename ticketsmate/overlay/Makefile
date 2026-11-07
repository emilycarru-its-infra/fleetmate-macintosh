# TicketsMate Makefile
#
#   make build            debug build
#   make test             run the test suite
#   make app              release build assembled into .build/app/TicketsMate.app
#   make zip              the app zipped as out/TicketsMate-App-$(VERSION).zip
#   make sign             sign the app, when SIGNING_IDENTITY is set
#   make notarize         notarise the signed app, when NOTARY_PROFILE is set
#
# Nothing here signs by default. A build with no SIGNING_IDENTITY is unsigned
# (ad hoc), which is what the release workflow publishes; whoever deploys the
# app signs and notarises it with their own identity.

ifneq (,$(wildcard ./.env))
	include .env
	export
endif

# The Command Line Tools 27 beta default to an SDK without the SwiftUI macro
# plugins; build against the macOS 26 SDK they still carry when that is all
# there is. An SDKROOT in the environment wins.
CLT_SDK_26 := /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
ifeq ($(SDKROOT),)
ifneq (,$(findstring CommandLineTools,$(shell xcode-select -p 2>/dev/null)))
ifneq (,$(wildcard $(CLT_SDK_26)))
export SDKROOT := $(CLT_SDK_26)
endif
endif
endif

APP_NAME := TicketsMate
PRODUCT := TicketsMate
# YYYY.MM.DD.HHMM stamps the bundle: CFBundleShortVersionString YYYY.MM.DD,
# CFBundleVersion HHMM. The default leaves Info.plist as committed.
VERSION ?= 1.0.0
export VERSION
# Override to ship under your own bundle id; the configuration profile domain
# follows it.
BUNDLE_ID ?= systems.focused.ticketsmate

SIGNING_IDENTITY ?=
NOTARY_PROFILE ?=
KEYCHAIN ?=

BUILD_DIR := .build
APP_DIR := $(BUILD_DIR)/app
APP_BUNDLE := $(APP_DIR)/$(APP_NAME).app
INFO_PLIST := Sources/TicketsMate/Info.plist
ENTITLEMENTS := Sources/TicketsMate/TicketsMate.entitlements
ICON_SOURCE := Sources/TicketsMate/Assets/TicketsMate.icon
ICON_PNG := Sources/TicketsMate/Assets/TicketsMate.png
SAFARI_EXTENSION_RESOURCES := Sources/TicketLinkExtension/Resources
HELPER_NAME := $(APP_NAME) Inbox Helper
HELPER_PATH := Contents/Library/LoginItems/$(HELPER_NAME).app
OUT_DIR := out

KEYCHAIN_ARG := $(if $(KEYCHAIN),--keychain "$(KEYCHAIN)",)

.PHONY: build test app zip sign notarize clean

build:
	swift build --product $(PRODUCT)

test:
	swift test
	python3 -m unittest discover -s Tests/Packaging -v

app:
	swift build -c release --product $(PRODUCT)
	@set -e; BIN="$$(swift build -c release --show-bin-path)/$(PRODUCT)"; \
	rm -rf "$(APP_BUNDLE)"; \
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"; \
	cp "$$BIN" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"; \
	cp "$(INFO_PLIST)" "$(APP_BUNDLE)/Contents/Info.plist"; \
	PLIST="$(APP_BUNDLE)/Contents/Info.plist"; \
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(BUNDLE_ID)" "$$PLIST"; \
	if echo "$(VERSION)" | grep -Eq '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{4}$$'; then \
		/usr/libexec/PlistBuddy \
			-c "Set :CFBundleShortVersionString $${VERSION%.*}" \
			-c "Set :CFBundleVersion $${VERSION##*.}" "$$PLIST"; \
	elif [ "$(VERSION)" != "1.0.0" ]; then \
		echo "VERSION must be YYYY.MM.DD.HHMM, not '$(VERSION)'"; exit 1; \
	fi; \
	SHA=$$(git rev-parse --short HEAD 2>/dev/null || true); \
	if [ -n "$$SHA" ]; then /usr/libexec/PlistBuddy -c "Add :TicketsMateGitCommit string $$SHA" "$$PLIST"; fi; \
	HELPER="$(APP_BUNDLE)/$(HELPER_PATH)"; \
	mkdir -p "$$HELPER/Contents/MacOS"; \
	cp "$$BIN" "$$HELPER/Contents/MacOS/$(HELPER_NAME)"; \
	cp "$$PLIST" "$$HELPER/Contents/Info.plist"; \
	/usr/libexec/PlistBuddy \
		-c "Set :CFBundleIdentifier $(BUNDLE_ID).inbox-agent" \
		-c "Set :CFBundleName $(HELPER_NAME)" \
		-c "Set :CFBundleExecutable $(HELPER_NAME)" \
		-c "Delete :CFBundleURLTypes" \
		-c "Delete :CFBundleIconFile" \
		-c "Delete :CFBundleIconName" \
		-c "Delete :LSApplicationCategoryType" \
		-c "Add :LSBackgroundOnly bool true" \
		-c "Add :LSUIElement bool true" \
		-c "Add :TicketsMateMainBundleIdentifier string $(BUNDLE_ID)" \
		"$$HELPER/Contents/Info.plist"; \
	AGENT_DIR="$(APP_BUNDLE)/Contents/Library/LaunchAgents"; \
	mkdir -p "$$AGENT_DIR"; \
	/usr/libexec/PlistBuddy \
		-c "Add :Label string $(BUNDLE_ID).inbox-agent" \
		-c "Add :BundleProgram string $(HELPER_PATH)/Contents/MacOS/$(HELPER_NAME)" \
		-c "Add :ProgramArguments array" \
		-c "Add :ProgramArguments:0 string $(HELPER_NAME)" \
		-c "Add :ProgramArguments:1 string --inbox-agent" \
		-c "Add :AssociatedBundleIdentifiers array" \
		-c "Add :AssociatedBundleIdentifiers:0 string $(BUNDLE_ID)" \
		-c "Add :RunAtLoad bool true" \
		-c "Add :KeepAlive bool true" \
		-c "Add :ThrottleInterval integer 60" \
		-c "Add :ProcessType string Background" \
		-c "Add :LimitLoadToSessionType string Aqua" \
		"$$AGENT_DIR/$(BUNDLE_ID).inbox-agent.plist" > /dev/null; \
	ICONSET=$$(mktemp -d)/AppIcon.iconset; mkdir -p "$$ICONSET"; \
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s "$(ICON_PNG)" --out "$$ICONSET/icon_$${s}x$${s}.png" > /dev/null 2>&1; \
		d=$$((s * 2)); sips -z $$d $$d "$(ICON_PNG)" --out "$$ICONSET/icon_$${s}x$${s}@2x.png" > /dev/null 2>&1; \
	done; \
	ACTOOL_OUT=$$(mktemp -d); \
	xcrun actool --compile "$$ACTOOL_OUT" --platform macosx --minimum-deployment-target 14.0 \
		--app-icon "$(APP_NAME)" --output-partial-info-plist "$$ACTOOL_OUT/partial.plist" \
		"$(ICON_SOURCE)" > /dev/null 2>&1 || true; \
	if [ -f "$$ACTOOL_OUT/Assets.car" ]; then cp "$$ACTOOL_OUT/Assets.car" "$(APP_BUNDLE)/Contents/Resources/"; fi; \
	if [ -f "$$ACTOOL_OUT/$(APP_NAME).icns" ]; then \
		cp "$$ACTOOL_OUT/$(APP_NAME).icns" "$(APP_BUNDLE)/Contents/Resources/"; \
	else \
		iconutil -c icns "$$ICONSET" -o "$(APP_BUNDLE)/Contents/Resources/$(APP_NAME).icns"; \
	fi; \
	rm -rf "$$ACTOOL_OUT" "$$(dirname "$$ICONSET")"
	python3 build/embed-safari-extension.py --app "$(APP_BUNDLE)" --resources "$(SAFARI_EXTENSION_RESOURCES)"
	@echo "Assembled $(APP_BUNDLE)"

zip: app
	mkdir -p $(OUT_DIR)
	ditto -c -k --keepParent "$(APP_BUNDLE)" "$(OUT_DIR)/$(APP_NAME)-App-$(VERSION).zip"
	@echo "Wrote $(OUT_DIR)/$(APP_NAME)-App-$(VERSION).zip"

# Sign the extension and the helper on their own first: --deep would give the
# extension the app's entitlements, and the helper keeps the app's signing
# identifier so it opens the app's keychain items without a prompt.
sign: app
	@if [ -z "$(SIGNING_IDENTITY)" ]; then \
		echo "SIGNING_IDENTITY is not set, so the app stays unsigned."; exit 1; \
	fi
	@set -e; \
	if [ -d "$(APP_BUNDLE)/Contents/PlugIns/TicketLinks.appex" ]; then \
		codesign --force --options runtime --timestamp $(KEYCHAIN_ARG) \
			--entitlements Sources/TicketLinkExtension/Extension.entitlements \
			--sign "$(SIGNING_IDENTITY)" "$(APP_BUNDLE)/Contents/PlugIns/TicketLinks.appex"; \
	fi; \
	codesign --force --options runtime --timestamp $(KEYCHAIN_ARG) \
		--identifier "$(BUNDLE_ID)" --entitlements "$(ENTITLEMENTS)" \
		--sign "$(SIGNING_IDENTITY)" "$(APP_BUNDLE)/$(HELPER_PATH)"; \
	codesign --force --options runtime --timestamp $(KEYCHAIN_ARG) \
		--entitlements "$(ENTITLEMENTS)" --sign "$(SIGNING_IDENTITY)" "$(APP_BUNDLE)"; \
	codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"

# NOTARY_PROFILE names credentials saved with `xcrun notarytool store-credentials`.
notarize: sign
	@if [ -z "$(NOTARY_PROFILE)" ]; then echo "NOTARY_PROFILE is not set."; exit 1; fi
	@set -e; ZIP="$(BUILD_DIR)/$(APP_NAME)-notarize.zip"; \
	ditto -c -k --keepParent "$(APP_BUNDLE)" "$$ZIP"; \
	OUT=$$(mktemp); \
	xcrun notarytool submit "$$ZIP" --keychain-profile "$(NOTARY_PROFILE)" --wait 2>&1 | tee "$$OUT"; \
	grep -q "status: Accepted" "$$OUT" || { echo "Notarisation was not accepted"; exit 1; }; \
	xcrun stapler staple "$(APP_BUNDLE)"; rm -f "$$ZIP" "$$OUT"

clean:
	rm -rf $(BUILD_DIR) $(OUT_DIR)
