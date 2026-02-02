#!/bin/bash
# Run FleetMate macOS App

cd "$(dirname "$0")"

echo "Building FleetMate App..."
swift build -c debug

echo "Launching app..."
EXECUTABLE=".build/debug/FleetMateApp"

if [ -f "$EXECUTABLE" ]; then
    # Run with proper app bundle simulation
    LSUIElement=0 "$EXECUTABLE" &
    APP_PID=$!
    echo "FleetMate App launched (PID: $APP_PID)"
    echo "If the window doesn't appear, run from Xcode:"
    echo "  1. Open this project in Xcode: xed ."
    echo "  2. Select FleetMateApp scheme"
    echo "  3. Press Cmd+R"
else
    echo "Error: FleetMateApp executable not found"
    exit 1
fi
