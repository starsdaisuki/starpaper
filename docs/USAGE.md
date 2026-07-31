# StarPaper usage guide

**English** · [简体中文](USAGE.zh-CN.md)

## Requirements

- macOS 14 or later
- The current release is an Apple silicon build
- A video file macOS supports natively, such as mp4 or mov

StarPaper needs no Accessibility or Screen Recording permission, and does not require
disabling SIP.

## Installation

Download the DMG from [Releases](https://github.com/starsdaisuki/starpaper/releases) and
drag `StarPaper.app` into `/Applications`.

The release is ad-hoc signed and has not been notarized by Apple. Once you have confirmed
the file came from this repository, run the following if Gatekeeper blocks the first
launch:

```bash
xattr -dr com.apple.quarantine /Applications/StarPaper.app
```

For building from source see [CONTRIBUTING.md](../CONTRIBUTING.md).

## First launch

If no video has been chosen yet, StarPaper opens the Settings window on first run.

1. Pick a video on the **Content** tab.
2. Choose a scaling mode: fill, fit or stretch.
3. Adjust the crop focus and zoom as needed.
4. Close Settings; StarPaper keeps running in the menu bar.

The menu bar icon can pause, resume, skip to the next video in the playlist, mute, or open
Settings.

## Content and cropping

- **Fill** — keeps the aspect ratio and covers the screen; the overflow is cropped.
- **Fit** — keeps the aspect ratio and shows the whole frame; the screen edges may be black.
- **Stretch** — matches the screen size directly, which may distort the picture.
- **Crop focus** — decides which part of the video fill mode preserves.
- **Zoom** — magnifies further on top of covering the screen.

All displays currently share one video and one set of crop parameters, but the frame
position is recomputed for each display's aspect ratio. Windows are rebuilt automatically
when displays are connected or disconnected, and after the system wakes from sleep.

Desktop icons appear above the live wallpaper by default; this can be switched so that the
wallpaper covers them.

## Image adjustment

The **Image** tab in Settings has three groups:

- **Tone** — exposure, brightness, contrast, highlights, shadows, gamma
- **Colour** — saturation, vibrance, temperature, tint
- **Effects** — blur, sharpness, vignette, vignette radius, dimming mask

"Reset image settings" clears every image adjustment but does not change the video or the
crop parameters.

## Playlists and schedules

Playlists support:

- Sequential or shuffled playback
- Switching after each video finishes
- Switching at a fixed interval

A schedule can select a different video for day and night and set the switching times.
Playback sources take priority in this order:

```text
schedule > playlist > single video
```

Enabling a schedule keeps the playlist and single video configured, but they will not take
effect while the schedule is active.

## Sound and power saving

Sound is off by default. Once enabled, only the player on the main display outputs audio
in a multi-display setup, avoiding an echo.

Each of these auto-pause conditions can be toggled separately:

- The live wallpaper is fully covered by another window
- The screen is locked
- The system enters Low Power Mode
- The device is running on battery

When these states clear, whether playback resumes still takes manual pause and the other
pause conditions into account.

## Global hotkeys

You can record a separate hotkey for pause, next, mute and opening Settings. All hotkeys
are empty by default and must include at least one modifier key.

StarPaper registers the specified combination through Carbon's `RegisterEventHotKey`. It
never requests Accessibility permission and never listens to all keyboard input.

## Command line

Run the following from the source directory to link the CLI into `~/.local/bin`:

```bash
make link
```

After confirming `~/.local/bin` is on your `PATH`:

```bash
starpaper video "$HOME/Movies/wallpaper.mp4"
starpaper pause
starpaper resume
starpaper toggle
starpaper mute
starpaper unmute
starpaper next

starpaper dim 0.3
starpaper blur 10
starpaper vignette 0.5
starpaper saturation 1.2
starpaper exposure -0.2
starpaper highlights 0.8
starpaper speed 1.0
starpaper volume 0.5

starpaper get
starpaper get dim
starpaper reset
starpaper restart
starpaper --help
```

The CLI is a thin wrapper around `defaults`. The app watches for settings changes, so most
commands take effect immediately without a restart; "next" is sent through a one-shot
command channel.

Structured playlists, schedules and hotkeys are best edited in the graphical interface.

## Where settings live

Settings are stored for the current user in:

```text
~/Library/Preferences/io.github.starsdaisuki.starpaper.plist
```

You can also use `defaults` directly:

```bash
defaults write io.github.starsdaisuki.starpaper videoPath -string "/path/to/video.mp4"
defaults write io.github.starsdaisuki.starpaper dim -float 0.3
defaults read io.github.starsdaisuki.starpaper
```

When writing configuration directly, use keys and value ranges the app supports.
`starpaper reset` deletes the entire configuration domain and prompts you to restart the
app.

## Troubleshooting

### Gatekeeper says the app is damaged

The current release is not notarized by Apple. Once you have confirmed the DMG came from
this repository, remove the quarantine attribute as described under "Installation".

### The menu bar icon is missing

First check whether a menu bar manager such as Ice or Bartender has collapsed or hidden it.
Quitting and reopening StarPaper also rebuilds the menu bar item.

### Desktop icons are missing

Check the system's "Show desktop items" setting. Even when StarPaper is at the correct
window level, Finder will not draw icons if that setting is off.

### The live wallpaper is missing from a screenshot

A terminal without Screen Recording permission may capture a degraded screenshot that
excludes the window layer. Do not judge whether the wallpaper window works from such a
screenshot alone.

### The wallpaper is not playing

Check the manual pause state in the menu bar, along with the occlusion, lock-screen, Low
Power Mode and battery pause conditions in Settings. When debugging power draw or
playback, first confirm the desktop is not fully covered by a window.
