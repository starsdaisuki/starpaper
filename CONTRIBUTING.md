# Building and contributing

**English** · [简体中文](CONTRIBUTING.zh-CN.md)

StarPaper compiles with SwiftPM, and the Makefile assembles the macOS `.app` bundle by
hand. The repository contains no Xcode project.

## Environment

- macOS 14 or later
- Swift 6 (Xcode or the Command Line Tools)
- `make`

## Common commands

```bash
make build      # release build
make bundle     # build and produce build/StarPaper.app
make run        # kill the old instance, repackage and launch
make install    # install into ~/Applications
make test       # run the settings-layer self-test in an isolated UserDefaults suite
make link       # link the CLI into ~/.local/bin
make dmg        # produce build/StarPaper.dmg
make icon       # regenerate the app icon from tools/make-icon.swift
make kill       # only terminate the running instance
make clean      # remove .build and build
```

`make run` and `make kill` terminate the currently running StarPaper instance. Use
`make build` or `make bundle` when you only want to verify that it compiles.

For personal use you can open `build/StarPaper.app` directly; no DMG is needed. `make
bundle` and `make dmg` produce ad-hoc signed output, which is fine locally but is rejected
by Gatekeeper on someone else's machine. Released DMGs are built with `make
release-signed`, which adds Developer ID signing, Hardened Runtime, notarization and
stapling; see [Maintainer notes](docs/MAINTAINER_NOTES.md).

## Code layout

```text
Package.swift
Makefile
Resources/
├── Info.plist
└── AppIcon.icns
bin/
└── starpaper                  thin CLI wrapper
tools/
└── make-icon.swift            pure Core Graphics icon generator
Sources/StarPaper/
├── main.swift                 NSApplication entry point
├── AppDelegate.swift          menu bar, main menu and Settings window
├── AppSettings.swift          UserDefaults settings model
├── Localization.swift         English / Chinese string table
├── VideoInfo.swift            video dimensions and crop preview frame
├── MediaSelector.swift        schedule, playlist and single-video selection
├── LoginItem.swift            SMAppService launch at login
├── Hotkeys.swift              Carbon global hotkeys
├── WallpaperWindow.swift      desktop-layer window
├── VideoWallpaperView.swift   playback, crop and filter layers
├── WallpaperEngine.swift      per-display playback units and playback decisions
├── PowerMonitor.swift         power, lock-screen and sleep state
├── SettingsView.swift         SwiftUI settings interface
└── SelfTest.swift             self-test in an isolated settings domain
```

For design background see the [architecture notes](docs/ARCHITECTURE.md). Read the
[maintainer notes](docs/MAINTAINER_NOTES.md) before changing settings, playback, window
or filter logic.

## Before you commit

Run at least:

```bash
make test
git diff --check
git status --short
```

Changes touching the interface, desktop window level, multiple displays, hot-plugging,
sleep and wake, global hotkeys or launch at login also need manual verification in a real
macOS session.

## Privacy and release hygiene

A public commit should contain only source code, documentation aimed at users or
contributors, synthetic test data, and build configuration. Do not commit:

- `.build/`, `build/`, dSYM bundles, object files, module caches or compilation databases
- Absolute paths from your machine, real video paths, device identifiers or account credentials
- `.env` files, API keys, tokens, private keys or configuration exports
- Local session handoffs, personal background, or internal incident records from other projects
- Screenshots, logs, DMGs or archives whose metadata has not been reviewed

Before publishing, check the current tree, the reachable Git history *and* the release
assets — not just the latest source.

## Release checklist

```bash
make clean
make test
make dmg
file build/StarPaper.app/Contents/MacOS/StarPaper
codesign -dvv build/StarPaper.app
shasum -a 256 build/StarPaper.dmg
```

Then mount the DMG and inspect the actual file listing to confirm there is no dSYM, log
or other build product before uploading the release.
