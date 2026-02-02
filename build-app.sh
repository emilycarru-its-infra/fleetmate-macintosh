#!/bin/bash
set -e

# FleetMate macOS App Builder
# Creates a proper .app bundle from SPM executable

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="FleetMate"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "🔨 Building FleetMate..."

# Build release by default, debug if --debug flag passed
BUILD_CONFIG="release"
if [[ "$1" == "--debug" ]]; then
    BUILD_CONFIG="debug"
fi

swift build -c $BUILD_CONFIG

# Get the built executable path
if [[ "$BUILD_CONFIG" == "release" ]]; then
    EXECUTABLE=".build/release/FleetMateApp"
else
    EXECUTABLE=".build/debug/FleetMateApp"
fi

if [ ! -f "$EXECUTABLE" ]; then
    echo "❌ Error: FleetMateApp executable not found at $EXECUTABLE"
    exit 1
fi

echo "📦 Creating app bundle..."

# Create bundle structure
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy executable
cp "$EXECUTABLE" "$MACOS_DIR/${APP_NAME}"
chmod +x "$MACOS_DIR/${APP_NAME}"

# Create PkgInfo
echo -n "APPL????" > "${CONTENTS_DIR}/PkgInfo"

# Ensure Info.plist exists
if [ ! -f "${CONTENTS_DIR}/Info.plist" ]; then
    cat > "${CONTENTS_DIR}/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>FleetMate</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.fleetmate.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>FleetMate</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2024-2026 FleetMate. All rights reserved.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>NSSupportsSuddenTermination</key>
    <true/>
</dict>
</plist>
PLIST
fi

# Create a simple app icon if none exists
if [ ! -f "${RESOURCES_DIR}/AppIcon.icns" ]; then
    echo "📎 Note: No AppIcon.icns found. Add one to ${RESOURCES_DIR}/ for a custom icon."
fi

# Touch the bundle to update modification date
touch "$APP_BUNDLE"

echo "✅ Built ${APP_BUNDLE}"
echo ""
echo "To run:"
echo "  open ${APP_BUNDLE}"
echo ""
echo "To install:"
echo "  cp -R ${APP_BUNDLE} /Applications/"
echo ""

# Optionally open the app
if [[ "$1" == "--open" ]] || [[ "$2" == "--open" ]]; then
    echo "🚀 Launching FleetMate..."
    open "$APP_BUNDLE"
fi
