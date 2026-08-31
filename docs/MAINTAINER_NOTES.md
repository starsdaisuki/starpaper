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

## Desktop windows (one per desktop)

### `collectionBehavior` cannot be changed in place

`.canJoinAllSpaces` ↔ `.managed` only takes effect when the window is created; changing it
on an existing window does not reassign which desktop the window belongs to. A change of
placement means rebuilding the windows (that is what `WallpaperEngine.applySettings()`
checks for).

### Order the window in before moving it

`NSWindow.windowNumber` is 0 until the window is actually registered with WindowServer,
and passing 0 to `CGSMoveWindowsToManagedSpace` fails silently.

### CGS writes return nothing, so read back and verify

`CGSMoveWindowsToManagedSpace` returns no status and fails silently. Always confirm with
`CGSCopySpacesForWindows` afterwards, or you end up with an invisible window. Tear down any
window that could not be placed — leaving it turns it into a spare window that follows the
current desktop around.

### No public notification for adding or removing desktops

Reconcile on `activeSpaceDidChangeNotification`, plus a low-frequency sweep. Without the
sweep, the first switch into a freshly created desktop still leaks.

### Occlusion state must be read live, not taken from the notification cache

Windows are created on the current desktop and then moved to their target desktop, so the
moved ones **never receive** `didChangeOcclusionStateNotification` and `isOccluded` stays
at its initial `false`. Using that cached value as the gate marks every desktop "visible"
and leaves all of them decoding (measured: CPU 5% → 11%). The notification only triggers a
re-evaluation; the state itself is read from `window.occlusionState` every time.

### `activeSpaceDidChange` lags the picture by about 0.93s

Measured: after pressing `⌃→`, the occlusion notification arrives at **0.126s** while
`activeSpaceDidChangeNotification` arrives at **1.056s** (our own handler takes 2 ms).
Waiting for `activeSpaceDidChange` to resume playback therefore always shows 0.1–0.25s of
stutter plus a visible jump. The resume gate has to include "not occluded right now", which
is the public signal that arrives as the transition starts.

### ⚠️ Clear the desktop layer before measuring the leak

The brightness probe treats "a bright frame appeared" as the static wallpaper showing
through. Any leftover test window at the desktop level — especially one that changes colour
— is counted too, and shows up as "one edge occasionally leaks 0.1–0.4s", which looks very
much like a real bug. Confirm the desktop layer holds only Dock / Finder / StarPaper first:

```bash
swift -e 'import AppKit
let all = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
print(Set(all.compactMap { w -> String? in
    (w[kCGWindowLayer as String] as! Int) < -2_000_000_000
        ? (w[kCGWindowOwnerName as String] as? String) : nil }).sorted())'
```

### A Bool that defaults to `true` cannot be self-tested by value alone

`UserDefaults.bool(forKey:)` returns `false` for a missing key, which is indistinguishable
from a genuine `false`. A `save()` that forgets the key still passes a value-only
assertion. Assert `object(forKey:) != nil` as well. `muted` is one of these (`perSpaceWindows` used to be too; it is now the string enum `perSpaceMode`, migrated once from the old boolean key), and they are both
in this category.

`backingLayers` is the integer version of the same trap, and sneakier: when the key is
missing `integer(forKey:)` returns `0`, and `load()` clamps `0` back up to the lower bound
`1` — **exactly the default value**, so a value assertion still passes. Assert existence too.

## Settings UI

### Never nest a `List` inside a `Form`

`Form(.formStyle(.grouped))` is itself a List, and a `List` nested inside it **swallows the
scroll wheel**: it neither scrolls itself nor forwards the event to the outer scroll view.
Once the video library grows past the visible height, the rest of it is unreachable.

Measured on macOS 15.7.4 against the real settings view tree: the inner
`ListCoreScrollView` held 797pt of content in a 150pt viewport, the wheel event did hit it,
and the offset stayed at `0.0`. The same test against a `ScrollView` moved `320pt`.

That is why the library is a `ScrollView` + `LazyVStack` with hand-written selection,
⌘/⇧ multi-select and drag reordering (`LibraryReorderDrop` stands in for `List.onMove`).
**Do not go back to a nested List when adding another table to this window.**

### ⚠️ Never schedule settings changes on `RunLoop.main`

Combine's `RunLoop` scheduler is backed by `RunLoop.perform`, which **only delivers in the
run loop's default mode**. While a slider is being dragged (likewise dragging a window or
tracking a menu) AppKit's tracking loop puts the main run loop into
`NSEventTrackingRunLoopMode`, so the subscriber receives nothing for the whole drag and gets
it all at once on mouse-up — the wallpaper appears frozen while dragging and then jumps.
Volume, playback speed and every image-adjustment slider were affected.

Measured (5 changes emitted during a drag, main run loop pumped only in event-tracking mode):

| Scheduler | received while dragging | after mouse-up |
|---|---|---|
| `.receive(on: RunLoop.main)` | **0** | 5 |
| `.receive(on: DispatchQueue.main)` | **5** | 5 |

The main queue's source is registered in the common modes and keeps being drained during
event tracking, so use `DispatchQueue.main`. This is encapsulated in `LiveSettingsRelay`,
which also coalesces every change within one run loop turn into a single `applySettings()`
(drags emit per frame, and `load()` emits dozens of `@Published` in a row, each otherwise
rebuilding the whole CIFilter chain across every window and every backing layer).
`SelfTest.liveSettingsRelaySelfTest()` pumps the run loop in event-tracking mode and turns
red the moment this goes back to `RunLoop.main`.

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
  privacy scan over the source, the Git history and the release assets. Scan Mach-O raw
  bytes (`rg -a`), not only `strings`: `N_OSO` object paths can be invisible to `strings`.
  Bundle builds strip debug symbols before signing so local build paths do not ship.
- Do not commit local session handoffs, absolute paths, real media files, device inventories
  or cross-project notes to a public repository.

### Signing a release people can actually open

An ad-hoc signed `.app` is refused by Gatekeeper on any machine that did not build it, so
every downloader has to run `xattr -dr com.apple.quarantine` first. The only real fix is a
Developer ID Application certificate plus Hardened Runtime, notarization and stapling.

- `make devid-check` reports whether that certificate is in the keychain, and prints the
  Xcode steps to create one if it is not. Developer ID Application is a different
  certificate from the Apple Distribution one used for the Mac App Store.
- `make notarize-setup` prints the one-time `xcrun notarytool store-credentials` command.
  It needs an app-specific password, not the Apple Account password.
- `make release-signed` signs the bundle with Hardened Runtime and a secure timestamp,
  builds and signs the DMG, submits it for notarization, staples the ticket and re-assesses
  the result through `spctl`. Stapling matters because it lets Gatekeeper verify offline.
- The ticket is stapled to the DMG. Shipping a bare `.app` needs its own staple pass.

### Screen lock detection has no public notification

`NSWorkspace.sessionDidResignActive` is fast user switching, not screen lock — the session
stays on console when the screen locks, so that notification never fires. Replacing the
`com.apple.screenIsLocked` distributed notification with it makes the "pause when screen
locked" setting inert. Both are observed now and recorded in separate fields, because a
user switch that returns while the screen is still locked would otherwise clear the lock
state. `PowerMonitor.LockState` exists so the self-test can replay those event sequences.

The notification name is undocumented, but `DistributedNotificationCenter` itself is public
API and no private symbol is involved, so the App Store variant keeps it too.
