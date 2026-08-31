# StarPaper architecture

**English** · [简体中文](ARCHITECTURE.zh-CN.md)

StarPaper is a SwiftPM executable target. It manages its lifecycle and desktop windows
with AppKit, builds the settings interface with SwiftUI, and plays local video through
AVFoundation.

## Desktop windows

**Every desktop (Space) on every display gets its own** borderless `NSWindow`. The window
sits between the desktop picture and the Finder desktop icons and ignores mouse events:

```swift
window.level = NSWindow.Level(
    rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1
)
window.collectionBehavior = [
    // no first-group flag = belongs to the desktop it was created on
    // (SpaceBridge then moves it to the target desktop)
    .stationary,       // stays out of Exposé — .managed would show it in Mission Control
    .ignoresCycle,
    .fullScreenNone,
]
window.ignoresMouseEvents = true
```

### Why not `.canJoinAllSpaces`

Earlier versions used a single `.canJoinAllSpaces` window that followed the user across
desktops. With "Accessibility → Display → Reduce motion" enabled, switching desktops with
`⌃←` / `⌃→` then showed the system's static wallpaper for roughly 0.9s before the video
appeared.

After pinning the variables down one by one, `collectionBehavior` turned out to be the
only cause. Same binary, same window level, same desktop, same transition — only this flag
differs:

| collectionBehavior | during the 0.9s after switching in, this window is |
|---|---|
| one window per desktop (no `.canJoinAllSpaces`) | composited live throughout; 0.03s of leak |
| `.canJoinAllSpaces` (one window following the user) | replaced by the static wallpaper for 0.95s |

Ruled out: window level, redraw frequency (a window drawn once and never again behaves the
same), `.stationary`, how the window is placed, and how long the desktop was left. It also
explains an older observation — only the *last* desktop was exempt, which is a general
quirk of sticky windows. With one window per desktop no desktop leaks, so the exemption is moot.

### Why `.stationary` and not `.managed`

`.managed` / `.transient` / `.stationary` are a **mutually exclusive** choice of three (they
decide how Exposé treats the window), not flags you can combine. An earlier version wrote
`[.managed, .stationary]` — both bits set, `.managed` wins — so the wallpaper windows were
treated as ordinary windows by Exposé and **Mission Control showed extra wallpaper
thumbnails for every desktop** (one per stacked layer).

Measured after dropping `.managed` (2026-08-23, Reduce motion on):

- `CGSCopySpacesForWindows` reads back one desktop per window — they did *not* turn sticky,
  so the per-desktop fix still holds;
- Mission Control shows `No Available Windows`, and the video keeps playing behind it.

**"Which desktop it belongs to" and "how Exposé treats it" are two independent groups of
flags** in `collectionBehavior`. Leaving the first group empty already means "belongs to the
desktop it was created on", which is exactly what we want; `.managed` was never required.

### `SpaceBridge`: the only private API in the project

Public API can neither enumerate desktops nor place an `NSWindow` on any desktop other
than the one it was created on. Those two steps use SkyLight private symbols, confined to
`SpaceBridge`:

- `CGSCopyManagedDisplaySpaces` — read the display / desktop layout, keeping only regular
  desktops (`type == 0`)
- `CGSMoveWindowsToManagedSpace` — put a window on a specific desktop
- `CGSCopySpacesForWindows` — **read back and verify** (these calls return nothing, so a
  failed write is silent)

The symbols need neither SIP disabled nor any permission, but a macOS update may change
them. The whole path therefore degrades gracefully: if a symbol is missing, the layout
cannot be read, or a window cannot be placed, StarPaper falls back to a single
`.canJoinAllSpaces` window — identical to the old behaviour, except that the 0.9s comes
back. Users can also turn "One wallpaper window per desktop" off in Settings.

### Cross-desktop time sync: skipped when it is expensive

Each desktop has its own player; it pauses when you leave and keeps its position. On the way
back it is seeked to the position of whichever player is currently running, so the desktops do
not drift apart.

But the cost of a seek depends on the video's **keyframe density** — H.264 can only decode
forward from a keyframe, so seeking to time X decodes everything from the nearest keyframe up
to X. Measured on a 3840×2160 / 60fps / 128s wallpaper with one keyframe every 4.17s
(GOP 250, a very common default): median seek 882 ms, worst 2545 ms, and each new seek cancels the previous one — which looks
like "the picture is wrong for a moment, then jumps". Re-encoded with one keyframe per second,
the median drops to 345 ms.

So the sync is not hard-coded: `WallpaperEngine.noteSeekCost` scores the measured seek latency
and, if the median exceeds `seekCostBudgetMs` (220 ms), disables cross-desktop sync for that
video (re-evaluated when the video changes). Each desktop then simply resumes where it left
off — no decoding, no jump; the only cost is that desktops show different points of the video,
so the 0.4s switch looks like a cross-dissolve.

### Cap on concurrently playing windows

While flying across desktops, macOS marks the window on **every** desktop along the way as
un-occluded, and only takes it back about 1.4s after you stop — with 11 desktops that ends up
being ten 4K decodes at once. `maxConcurrentPlayers = 3` caps this, keeping the most recently
visible ones (the active desktop always wins). Measured over 14 rapid switches: CPU peak
54.7% → 42.8%, and it falls back much faster.

### Backing windows: `backingLayers`

One window per desktop removes the 0.9s, but a thin layer remains: **for about 0.4s during the switch
the system dims windows on the desktop layer, letting the static wallpaper show through**
(measured at ~16.6%).

That layer cannot be blocked, and it is not our doing — a static, fully opaque solid-colour
window still gets ~26% mixed in, regardless of content, level, `collectionBehavior` or
whether it redraws. It is also **not** caused by Reduce Motion: with the transition turned
off the residual is unchanged item for item.

Since it cannot be blocked, stack extra windows underneath the main one
(`WallpaperWindow.levelOffset`) so that what shows through is our own picture rather than
the wallpaper. Measured with a solid-colour probe, the wallpaper bleed-through falls off as
`1/sqrt(n)` (not geometrically):

| windows per desktop | 1 | 2 | 3 | 4 | 6 |
|---|---|---|---|---|---|
| bleed-through (solid probe) | 26.1% | 19.8% | 15.7% | 13.0% | 9.8% |

But **in the real app more is not better** — measuring the picture deviation during a switch:

| windows per desktop | 1 | 2 | 3 | 4 | 6 |
|---|---|---|---|---|---|
| picture deviation | +10.6 | +4.5 | **+1.9** | -2.0 | -3.2 |

**The sign flips between 3 and 4**: with few layers the wallpaper bleeding through dominates
(it is brighter, so the picture brightens); with many, the backing frame being slightly
darker than the main window dominates. Three layers cancel out, hence the default.

Why the backing frame is darker was not resolved — three colour spaces were tried (default
sRGB / colour management off / tagged BT.709), giving -3.2 / -5.0 / -3.3. Only "off" is
clearly worse; the other two are within noise.

Three things matter:

- **Backing windows must show the video** (`BackingWallpaperView`). With plain black ones,
  "the brighter wallpaper shows through" turns into "a flash of black" (measured 65.4 ->
  38.7), which is more noticeable than the problem it replaces.
- **They must use the same crop geometry as the main window**
  (`VideoWallpaperView.fillRects`); even a slight mismatch makes what shows through visibly
  misaligned.

- **The frame must be pumped right as the Space transition begins.** Feeding one fixed frame
  per video leaves the main window far ahead, so what shows through is two points in time
  overlaid — plainly visible in use. Feeding it on a 1 s timer instead costs
  **CPU 1.4% -> 5.6%**, which defeats the whole premise that this is nearly free. It is now
  pumped once when the occlusion notification arrives — about 0.126s after the keypress,
  while the backing window is still ~0.9s away from being visible. Nothing runs while idle.

All backing windows share the same `CGImage` (scaled to the screen), and never decode or
redraw.

### Desktops being added or removed

There is no public notification for creating or removing a desktop. `WallpaperEngine`
reconciles the desktop list on `NSWorkspace.activeSpaceDidChangeNotification`, plus a
low-frequency 20-second sweep. The sweep exists so a window is already in place *before*
the user first switches to a freshly created desktop; otherwise that first switch would
still leak.

The window level is raised accordingly if the user chooses to cover the desktop icons.
When display connections change, `WallpaperEngine` rebuilds the playback units from the
current set of screens.

## Playback units

Each `VideoWallpaperView` contains three layers:

```text
containerLayer
├── playerLayer   AVPlayerLayer, carrying the video and Core Image filters
└── dimLayer      black mask that dims the picture proportionally
```

Normal looping uses `AVQueuePlayer` with `AVPlayerLooper`, which avoids the stutter of
seeking manually at the end of the video.

Auto-advance's "switch when finished" mode cannot use the looper, because the looper never
produces a usable final end event to switch on. That mode uses a single item and
`AVPlayerItemDidPlayToEndTime` instead. With multiple displays, only the main screen's
playback unit notifies the selector, so one end event does not trigger several switches.

## Crop model

StarPaper stores `focusX`, `focusY` and `zoom` rather than a fixed crop rectangle for one
particular screen. Given a screen of `W × H` and a video of `vw × vh`:

```text
s = max(W / vw, H / vh) × zoom
w = vw × s
h = vh × s
x = -(w - W) × focusX
y = -(h - H) × focusY
```

`playerLayer.frame` is set directly to `(x, y, w, h)`, and the parent layer uses
`masksToBounds` to crop the overflow. Displays with different aspect ratios compute
independently from the same focus and zoom, so a crop intent is reusable across screens.

## Image processing

When image adjustment is needed, `AVPlayerLayer.filters` carries a Core Image filter
chain, ordered roughly as:

```text
exposure → highlights/shadows → gamma → brightness/contrast/saturation
        → vibrance → temperature/tint → sharpness → vignette → blur
```

Implementation constraints:

- `layerUsesCoreImageFilters = true` must be set before attaching any filter.
- Do not mutate an already-attached `CIFilter` in place; rebuild the filter array when
  settings change.
- `CITemperatureAndTint`'s neutral / target semantics do not match the direction of a
  typical colour-grading slider, so the conversion has to handle the direction.
- Blur consumes the edges of the picture, so the player layer is enlarged slightly in
  proportion to the blur radius and cropped back by the parent layer.
- Dimming uses the opacity of a separate black `CALayer` rather than `CIColorControls`'
  brightness, which is an additive offset and produces a grey haze.
- When every image parameter is at its default, no filter is attached and the system's
  video composition path is preserved.

## Playback sources

`MediaSelector` is the single place that decides the current video source:

```text
schedule > current video (videoPath)
```

`settings.videoPath` is **whatever is playing right now**; `settings.playlist` is the
**library**, the videos you can switch to with one click. They are not two parallel
playback channels: the library only answers "what comes next", never "what plays now".
Every manual pick goes through `AppSettings.play(_:)`, which also files the video into the
library, so the Content tab and the Playback tab always point at the same fact.

An earlier version did not work this way: the library kept its own `index` and `videoPath`
was only the single-video fallback, so the Content tab showed A while the desktop played B.

The schedule picks a file by day and night time ranges and overrides everything else while
it is on. `playlistEnabled` now means **auto-advance** only (on end or on a timer,
optionally shuffled); clicking an entry in the library works regardless of that switch.
"What comes next" is factored into the pure functions `MediaSelector.nextIndex` and
`shuffleNext`, both covered by `SelfTest`. The playback engine only consumes the path the
selector hands it, and does not reimplement selection logic inside each display.

## Playback state and power saving

`WallpaperEngine.updatePlayback()` aggregates every playback condition, so that different
event handlers never call `play()` / `pause()` against each other:

- Manual pause by the user
- Whether the window's desktop is the one currently on screen (if not, it stops — nobody
  can see it, and decoding anyway would multiply the cost by the number of desktops)
- Window occlusion state
- Screen locked
- System asleep
- Low Power Mode
- Running on battery

Occlusion uses `NSWindow.didChangeOcclusionStateNotification`. Power state is wired into
the main run loop through IOKit's `IOPSNotificationCreateRunLoopSource`, with no polling.

## Settings and external control

`AppSettings` is a singleton `ObservableObject` whose configuration is written to
`UserDefaults`. SwiftUI observes the settings object, and the playback engine subscribes to
the same state.

After an external `defaults write` or a CLI change, `UserDefaults.didChangeNotification`
triggers a reload. Loading must be idempotent, and saving must additionally guard against
re-entry from per-key notifications; the relevant invariants are in the
[maintainer notes](MAINTAINER_NOTES.md).

"Next" is not a persistent state, so the CLI writes a value with a unique suffix to the
`command` key, letting the app recognise each write as a distinct action.

## Global hotkeys

Hotkeys use Carbon's `RegisterEventHotKey` and register only the combinations the user has
explicitly configured. This needs no Accessibility permission and no global keyboard
monitoring.

## Localization

English and Chinese strings live in one table in `Localization.swift`. `T("key")` reads
from `AppSettings.shared.language`; SwiftUI redraws naturally after a settings change, and
AppKit menus are rebuilt through a language subscription.

## Local data boundary

This version has no network client and no telemetry SDK. Video files are read locally by
AVFoundation. Their display paths and read-only security-scoped bookmarks are stored with
the video library and other settings in the current user's `UserDefaults` domain. A bookmark
lease stays alive for the whole AVAsset / player lifetime because AVFoundation reads lazily.
