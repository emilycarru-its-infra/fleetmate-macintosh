# FleetMate Development Guide

## Build Workflow

After every code change iteration, run the full pipeline and launch the app:

```
make release-app-signed && open .build/app/FleetMate.app
```

This builds the release binary, assembles the .app bundle, signs it with Developer ID, notarizes with Apple, and opens the app.

For a faster unsigned build during rapid iteration:

```
make release-app && open .build/app/FleetMate.app
```

Both targets compile with the Command Line Tools alone; no Xcode is needed. The Makefile builds against the macOS 26 SDK when only the Command Line Tools are installed, because the 27 beta tools default to the macOS 27 SDK and carry no SwiftUI macro plugins. `#Preview` blocks stay inside `#if DEBUG` for the same reason: release builds never expand the Previews macro. `swift test` still needs XCTest, which the Command Line Tools do not ship, so the suite runs in CI.

## Key Conventions

- **No interactive SSO popups** — All web auth must be silent/headless. Never show browser login sheets to the user. If silent SSO fails, mark auth as failed.
- **No Xcode GUI** — Everything is SPM-driven from the command line.
- **macOS 14+ target** — Platform is macOS only, minimum deployment target is macOS 14 (Sonoma).
