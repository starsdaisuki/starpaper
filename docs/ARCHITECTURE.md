# StarPaper architecture

**English** · [简体中文](ARCHITECTURE.zh-CN.md)

StarPaper is a SwiftPM executable target. It manages its lifecycle and desktop windows
with AppKit, builds the settings interface with SwiftUI, and plays local video through
AVFoundation.

## Desktop windows

Each display gets one borderless `NSWindow`. The window sits between the desktop picture
and the Finder desktop icons, ignores mouse events, and follows every Space:

```swift
window.level = NSWindow.Level(
    rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1
)
window.collectionBehavior = [
    .canJoinAllSpaces,
    .stationary,
    .ignoresCycle,
    .fullScreenNone,
]
window.ignoresMouseEvents = true
```

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

A playlist's "switch when finished" mode cannot use the looper, because the looper never
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
schedule > playlist > single video
```

The schedule picks a file by day and night time ranges; the playlist maintains a
sequential or shuffled queue and supports switching on end or at an interval. The playback
engine only consumes the path the selector hands it, and does not reimplement selection
logic inside each display.

## Playback state and power saving

`WallpaperEngine.updatePlayback()` aggregates every playback condition, so that different
event handlers never call `play()` / `pause()` against each other:

- Manual pause by the user
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

This version has no network client and no telemetry SDK. Video files are read from local
paths by AVFoundation; file paths, playlists and other settings are stored in the current
user's `UserDefaults` domain.
