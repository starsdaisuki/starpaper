<div align="center">

<img src="res/icon.png" width="120" alt="StarPaper">

# StarPaper

**Turn a local video into a macOS live wallpaper.**

[![release](https://img.shields.io/github/v/release/starsdaisuki/starpaper?label=release&color=4c1)](https://github.com/starsdaisuki/starpaper/releases)
[![macOS](https://img.shields.io/badge/macOS-14%2B-555)](#install)
[![license](https://img.shields.io/github/license/starsdaisuki/starpaper)](LICENSE)

**English** · [简体中文](README.zh-CN.md)

</div>

Multiple displays, custom cropping, image adjustment, a video library and power-saving
auto-pause. It lives in the menu bar; hiding the Dock icon is an option, not the default.

## Features

- Plays mp4, mov and other formats macOS supports natively, looping seamlessly
- Mirrors across multiple displays with fill, fit and stretch modes
- One wallpaper window per desktop (Space), so switching desktops no longer flashes the
  system's static wallpaper first
- Optionally stacks several wallpaper windows per desktop, which also removes the faint
  wallpaper bleed-through that remains during the switch (the stacked windows never decode
  or redraw; measured CPU and memory cost is within noise)
- Custom crop focus and zoom
- Adjusts exposure, brightness, contrast, colour, blur, sharpness, vignette and a dimming mask
- Optional desktop clock over the wallpaper: up to three format-driven lines, an outer glow,
  optional two-colour cycling, and vector rendering that stays sharp on any display
- A video library with thumbnails: **click one to switch to it**
- Auto-advance (on end or on a timer, optionally shuffled) and day / night schedules
- Auto-pauses when fully covered by a window, when the screen locks, or in Low Power Mode
- Global hotkeys, launch at login, and an English / Chinese interface
- Switches videos or adjusts common parameters instantly from the `starpaper` command line

StarPaper does not require disabling SIP, nor Accessibility or Screen Recording
permissions. Everything uses public macOS APIs except "One wallpaper window per desktop",
which relies on a few SkyLight private symbols to enumerate desktops and place a window on
a specific one. That path degrades automatically if the symbols are unavailable, and you can
turn the option off in Settings to stay entirely on public API.

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
- When a schedule is enabled it takes priority, otherwise the current video plays;
  the library decides what comes next.
- The current video and the library are one thing: videos you pick are kept in the
  library, and the Content tab follows along when auto-advance switches.

See the [usage guide](docs/USAGE.md) for the full walkthrough and command-line reference.

## Privacy

Videos are played locally through AVFoundation. This version contains no account system,
network requests, telemetry or analytics. The selected video paths, read-only persistent
file bookmarks and your settings stay on your own machine. See the [privacy policy](PRIVACY.md).

## Known limitations

- All displays currently share one set of video and crop parameters
- "One wallpaper window per desktop" defaults to **Auto**: it only turns on while
  "Accessibility → Display → Reduce motion" is enabled, because the problem it fixes only
  happens there; with Reduce motion off it falls back to the classic single window.
- With sound on, the player that owns the audio does not pause when you leave its desktop —
  otherwise every desktop switch restarts the audio on another player and you hear a hiccup.
  The cost is one extra decode while you are on another desktop; muted costs nothing, and
  "pause when covered" still overrides it.
- "One wallpaper window per desktop" adds a little memory per desktop (measured at about
  +4 MB for four desktops; CPU is unchanged, since only the foreground desktop decodes)
- "Wallpaper windows stacked per desktop" defaults to 3 (measured optimum), so 4 desktops
  means 12 windows. Measured CPU and memory cost is within noise — the stacked windows hold
  one still frame and never decode or redraw. Picture deviation during a switch: 10.6 with
  one window, 1.9 with three
- No support yet for images, GIFs, or sunrise / sunset switching
- Release builds are not notarized by Apple

## Documentation

- [Usage guide](docs/USAGE.md)
- [Building and contributing](CONTRIBUTING.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Spaces, displays and occlusion](docs/SPACES_AND_DISPLAYS.md) — which system signals can be trusted, and how to debug them
- [Maintainer notes](docs/MAINTAINER_NOTES.md)
- [Mac App Store readiness](docs/APP_STORE.md)

## License

[GPL-3.0](LICENSE)
