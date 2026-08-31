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

The DMG is signed with a Developer ID certificate, notarized by Apple and stapled, so
Gatekeeper lets it open by double-clicking. To check that for yourself:

```bash
spctl -a -vv /Applications/StarPaper.app
#   accepted
#   source=Notarized Developer ID
```

For building from source see [CONTRIBUTING.md](../CONTRIBUTING.md).

## First launch

If no video has been chosen yet, StarPaper opens the Settings window on first run.

1. Pick a video on the **Content** tab.
2. Choose a scaling mode: fill, fit or stretch.
3. Adjust the crop focus and zoom as needed.
4. Close Settings; StarPaper keeps running in the menu bar.

The menu bar icon can pause, resume, skip to the next video in the library, mute, or open
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

### Wallpaper bleed-through when switching desktops

For about 0.4s while you switch desktops, the system dims windows on the desktop layer,
letting the static wallpaper show through a little (measured at ~16.6%). That dimming is
system behaviour and does not go away when you turn off Reduce Motion.

**Wallpaper windows stacked per desktop** (default 3) exists for this. Raise it and what
shows through is a frame of your own video instead of the static wallpaper.

**More is not better.** Measured picture deviation during a switch: 10.6 with 1, 4.5 with 2,
1.9 with 3, -2.0 with 4, -3.2 with 6. With few layers the wallpaper bleeding through
dominates (picture brightens); with many, the backing frame being slightly darker dominates.
Three cancels out, hence the default.

The stacked windows hold one still frame and never decode or redraw — the measured CPU and
memory cost is within noise.

## Image adjustment

The **Image** tab in Settings has three groups:

- **Tone** — exposure, brightness, contrast, highlights, shadows, gamma
- **Colour** — saturation, vibrance, temperature, tint
- **Effects** — blur, sharpness, vignette, vignette radius, dimming mask

"Reset image settings" clears every image adjustment but does not change the video or the
crop parameters.

## Desktop clock

Some live wallpapers ship with a clock baked into the video. Baked clocks are frozen at
whatever time the author exported the file. The **Clock** tab draws a real one on top
instead, so it actually tells the time.

### Format

Up to three lines, each driven by its own format string. Leave a line empty to hide it.

| Token | Meaning | Example |
|---|---|---|
| `yyyy` / `yy` | Year, four digits / last two | `2026` / `26` |
| `MM` | Month, zero-padded | `08` |
| `dd` | Day, zero-padded | `22` |
| `HH` | Hour, 24-hour, zero-padded | `00` |
| `hh` | Hour, 12-hour | `1` |
| `mm` | Minute | `41` |
| `ss` | Second | `07` |
| `[W]` | Weekday | `Sat` / `周六` |
| `[P]` | Period of day | `Night` / `凌晨` |

Anything that is not a token is printed as-is, so `MM|dd [W]` keeps its `|` and its space.
This also means ordinary letters get substituted when they happen to spell a token —
`summer` renders as `su41er` at 41 minutes past. Deliberate: the rule is uniform.

`[W]` and `[P]` follow the **[W] / [P] language** setting, which is independent of the
interface language — an English interface with a Chinese clock is a normal combination.

### Style

| Option | Notes |
|---|---|
| Font | Six system weights, including SF Rounded; no external font files |
| Size | The first line, calibrated for a 1920-wide screen and scaled to the display |
| Sub size | The other two lines, as a fraction of the first |
| Glow | An outer glow in the text colour. Set it to 0 for plain text |
| Opacity | Lines after the first are drawn slightly fainter |
| Colour / Cycle between two colours | Optionally eases back and forth between two colours |

**Glow, not drop shadow.** A dark drop shadow makes the clock look like a sticker pasted
over the picture; wallpapers that ship their own clock use a bright halo so the text sits
*in* the scene. The glow is rendered as a second text layer beneath the solid one, so the
centre of each glyph stays crisp.

The clock is a `CATextLayer` rasterised at the display's `backingScaleFactor`, so it stays
sharp on Retina and at any resolution — unlike a clock baked into a video, which carries the
compression artefacts of its source file. It redraws once per minute (once per second if a
format contains `ss`) and its timer stops whenever playback is paused.

### Anchor

This matters whenever the wallpaper's aspect ratio differs from the display, because `fill`
mode then crops the footage.

- **Video** (default) — the clock is cropped, scaled and panned together with the footage.
  Its position relative to the artwork is identical on every display, and the font scales
  with the picture. Use this to match how the clock sat in the original wallpaper.
- **Screen** — the clock is pinned to the display and ignores cropping entirely, like a
  separate UI layer. Use this if you want it in a fixed corner regardless of the video.

With **Video** the clock can be cropped off-screen along with the rest of the frame, which is
the point: it behaves like part of the picture.

Double-click a slider's label to reset just that value. **Reset position** restores every
clock setting to its default.

## The video library and schedules

The library on the Playback tab holds the wallpapers you use often. **Click one to switch
to it**; every row carries a thumbnail and the one currently playing is marked with ▶.
Drag rows to reorder them.

The "Now Playing" entry on the Content tab is that same video: anything you pick there or
from the menu bar is filed into the library, and the Content tab follows along when
auto-advance switches, so the two views never disagree.

"Auto-advance" only decides whether it switches **on its own** — the library stays
clickable either way:

- Sequential or shuffled playback (shuffle never repeats within a round)
- Switching after each video finishes
- Switching at a fixed interval

A schedule can select a different video for day and night and set the switching times.
Playback sources take priority in this order:

```text
schedule > current video (the library decides what comes next)
```

Enabling a schedule keeps the library and auto-advance configured, but they will not take
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

The structured video library, schedules and hotkeys are best edited in the graphical interface.

## Where settings live

Settings are stored for the current user in:

```text
~/Library/Preferences/io.github.starsdaisuki.starpaper.plist
```

You can also use `defaults` directly:

```bash
defaults write io.github.starsdaisuki.starpaper videoPath -string "/path/to/video.mp4"
defaults write io.github.starsdaisuki.starpaper dim -float 0.3
defaults write io.github.starsdaisuki.starpaper backingLayers -int 6
defaults read io.github.starsdaisuki.starpaper
```

When writing configuration directly, use keys and value ranges the app supports.
`starpaper reset` deletes the entire configuration domain and prompts you to restart the
app.

## Troubleshooting

### Gatekeeper says the app is damaged or cannot be verified

Released DMGs are notarized, so this should not happen with a file downloaded from
Releases. It does happen with a locally built `.app`, which is only ad-hoc signed: run
`xattr -dr com.apple.quarantine /Applications/StarPaper.app`.

If a **downloaded** DMG is rejected, check it first — do not skip straight to `xattr`:

```bash
spctl -a -vv /Applications/StarPaper.app
```

`source=Notarized Developer ID` means the signature is intact and something else is wrong
(a revoked or otherwise unusable signing certificate would do it); the same `xattr` command
is then a valid escape hatch. Any other result means the file is not the one published
here — it was altered in transit or came from somewhere else — and should be downloaded
again rather than forced open.

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
