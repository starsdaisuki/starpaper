# StarPaper

**English** · [简体中文](README.zh-CN.md)

Turn a local video into a macOS live wallpaper. StarPaper lives in the menu bar with no
Dock icon, and supports multiple displays, custom cropping, image adjustment, playlists
and power-saving auto-pause.

## Features

- Plays mp4, mov and other formats macOS supports natively, looping seamlessly
- Mirrors across multiple displays with fill, fit and stretch modes
- Custom crop focus and zoom
- Adjusts exposure, brightness, contrast, colour, blur, sharpness, vignette and a dimming mask
- Playlists, shuffle, timed switching and day / night schedules
- Auto-pauses when fully covered by a window, when the screen locks, or in Low Power Mode
- Global hotkeys, launch at login, and an English / Chinese interface
- Switches videos or adjusts common parameters instantly from the `starpaper` command line

StarPaper uses public macOS APIs. It does not require disabling SIP, nor Accessibility or
Screen Recording permissions.

## Download and install

The current release requires macOS 14 or later and ships an Apple silicon build.

1. Download `StarPaper.dmg` from [Releases](https://github.com/starsdaisuki/starpaper/releases).
2. Open the DMG and drag `StarPaper.app` into `/Applications`.
3. Pick a local video the first time it launches.

The current release is ad-hoc signed and has not been notarized by Apple. If Gatekeeper
reports that the app is damaged or refuses to open it, confirm the file came from this
repository's Releases, then run:

```bash
xattr -dr com.apple.quarantine /Applications/StarPaper.app
```

You can also [build from source](CONTRIBUTING.md); a local build usually needs no
quarantine removal.

## Quick start

- The menu bar icon pauses, resumes, skips to the next video or opens Settings.
- The Settings window covers content, image, sound, power, schedule, hotkeys and general options.
- Muted by default; with multiple displays only the main screen's player outputs sound.
- When a schedule is enabled it takes priority, then the playlist, then the single video.

See the [usage guide](docs/USAGE.md) for the full walkthrough and command-line reference.

## Privacy

Videos are played locally through AVFoundation. This version contains no account system,
network requests, telemetry or analytics. The selected video path and your settings are
stored in `UserDefaults` on your own machine.

## Known limitations

- All displays currently share one set of video and crop parameters
- No support yet for images, GIFs, a video thumbnail library, or sunrise / sunset switching
- Release builds are not notarized by Apple

## Documentation

- [Usage guide](docs/USAGE.md)
- [Building and contributing](CONTRIBUTING.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Maintainer notes](docs/MAINTAINER_NOTES.md)

## License

[MIT](LICENSE)
