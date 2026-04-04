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

## Key Conventions

- **No interactive SSO popups** — All web auth must be silent/headless. Never show browser login sheets to the user. If silent SSO fails, mark auth as failed.
- **No Xcode GUI** — Everything is SPM-driven from the command line.
- **macOS 14+ target** — Platform is macOS only, minimum deployment target is macOS 14 (Sonoma).
