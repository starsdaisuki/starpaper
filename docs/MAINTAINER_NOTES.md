# StarPaper maintainer notes

**English** · [简体中文](MAINTAINER_NOTES.zh-CN.md)

This file records behavioural invariants that a "looks simpler" change tends to break.
Read the [architecture notes](ARCHITECTURE.md) alongside it before changing the relevant
code, and run `make test` afterwards.

## Settings layer

### Do not rename `AppSettings` to `Settings`

SwiftUI already has a `Settings<Content>` scene. Using the same type name in a context
that imports SwiftUI causes resolution conflicts and generic errors that are hard to read.

### `load()` must be idempotent

A `@Published` property emits `objectWillChange` even when assigned the same value. If
`load()` assigns unconditionally, it triggers `save()`, which then produces another
`UserDefaults.didChangeNotification`, forming a loop.

Every read-back should go through `setIfChanged(_:_:)` so memory is written only when the
value has genuinely changed.

### Saving needs two re-entry guards

`UserDefaults` emits a change notification for each key written. While the first key is
being saved, a listener that immediately calls `load()` will overwrite the not-yet-written
keys with stale values from disk, and the save may then write those stale values back.

Both of these must be kept:

- `isSaving` — blocks notification re-entry during the save
- `hasUnsavedChanges` — blocks read-back from disk during the debounce window, while disk
  still holds the old values

Dropping either one reintroduces the "setting snaps back the moment you change it" bug.

### The self-test must not use the real settings domain

The self-test flips settings to verify read and write. Even if it restores the values on
disk afterwards, another running instance may read the temporary values during the test and
save them again later.

`SelfTest` must use a throwaway `UserDefaults` suite, switching the whole settings layer
over with `useDefaultsSuite(_:)` and deleting the suite when the test finishes. Never write
to `UserDefaults.standard` temporarily.

## Windows and app lifecycle

### `NSWindow` subclass initialization

`NSWindow.init(contentRect:styleMask:backing:defer:screen:)` — the one taking `screen:` —
is a convenience initializer, so a subclass cannot call it through `super.init`. Use the
four-argument designated initializer and then call `setFrame`.

### The main menu cannot be omitted

Even though an accessory app never shows a menu bar, `NSApplication` still relies on
`mainMenu` to dispatch many Command shortcuts. Without a main menu, ⌘W, ⌘A, ⌘V, ⌘X and ⌘Z
do not work in the Settings window.

Keep the hidden standard menu items, while avoiding shortcut actions that would casually
shut down the whole wallpaper engine.

### Desktop icons and the menu bar icon are external state

- Once Finder's "Show desktop items" is off, the desktop icons simply do not exist; this is
  not evidence of a wrong window level.
- Tools such as Ice or Bartender can collapse menu bar items, so not seeing the icon is not
  evidence that `NSStatusItem` creation failed.

## Playback

### `AVPlayerLooper` and switch-on-end cannot be combined

The looper is for seamless looping, but it never gives the playlist a final end point. The
"switch when finished" mode must use a single player item and the end notification.

Multiple displays create several players for the same video. Only the main screen's unit
may report the end, otherwise one end event skips several list items in a row.

### All playback conditions funnel into one entry point

Manual pause, occlusion, lock screen, sleep, battery and Low Power Mode are all aggregated
by `WallpaperEngine.updatePlayback()`. Event handlers must not each decide the final
play / pause state on their own.

## Filters and cropping

- `layerUsesCoreImageFilters` must be enabled before using `CALayer.filters`.
- Do not mutate an already-attached `CIFilter` in place; rebuild the whole chain.
- Default image parameters should create no filter, so the composition path is not changed
  unnecessarily.
- Persist crop as focus + zoom, not as a fixed pixel rectangle for one display.
- Blur needs the video layer enlarged to cover the sampling edge, avoiding transparent or
  black borders.
- Keep the dimming mask as a separate black layer; do not replace it with an additive
  brightness offset.

## Permissions and hotkeys

Global hotkeys use `RegisterEventHotKey`. Do not switch to NSEvent global monitoring; that
requires Accessibility permission, whose scope does not match what the feature needs.

When verifying the desktop effect, note that a screenshot tool without Screen Recording
permission may return a degraded screenshot that excludes the window layer.

## Building and releasing

- `make test` builds the bundle first, then runs the self-test in an isolated settings domain.
- Before testing playback or power draw, confirm the wallpaper is not paused because of
  window occlusion.
- A release should contain only the `.app` / `.dmg`, never `.build/`, dSYM bundles, module
  caches, object files or raw build descriptions — those products can embed absolute paths
  from the build machine.
- Before publishing, check the DMG listing, signing status and architecture, and run a
  privacy scan over the source, the Git history and the release assets.
- Do not commit local session handoffs, absolute paths, real media files, device inventories
  or cross-project notes to a public repository.
