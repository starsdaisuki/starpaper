# Spaces, displays and occlusion — what you can and cannot trust

Most of the hard bugs in this project were not logic errors. They were **the wrong
signal**: macOS offers several ways to ask "can the user see the wallpaper right
now", each true only inside a narrow range, and picking the wrong one gives you an
implementation that looks correct, passes its tests, and fails on every real machine.

Read this before touching playback, occlusion, audio gating or per-desktop windows.

## 1. Signal reliability table

| Signal | Trustworthy? | Notes |
|---|---|---|
| `window.occlusionState` on a **per-desktop** window | ✅ | Each desktop has a real window; the system composites it for real. |
| `window.occlusionState` on the **single sticky** window | ❌ | After a Space switch it stays "not visible" for **~16 s**. See §3. |
| `occlusionState` as "the user is back on the desktop" | ❌ | It flips ~0.9 s **early**, on purpose — the picture needs that head start. |
| Window size `==` screen size ⇒ full-screen window | ❌ | No real full-screen window matches. See §2. |
| Current Space type via `CGSCopyManagedDisplaySpaces` | ✅ | `type == 0` desktop, `type == 4` full-screen app. The one dependable answer. |
| `isOnActiveSpace` on the sticky window | ❌ | Always `true` — it follows the user by definition. |
| `NSEvent` global `.scrollWheel` / `.swipe` to catch a 4-finger Space swipe | ❌ | WindowServer consumes the gesture; the app never sees it. |
| Any fixed timeout as a fallback | ❌ | An interactive gesture can hover **indefinitely**. See §4. |

The single most useful line of code in this project:

```swift
SpaceBridge.currentSpaceIsDesktop()   // Bool?, nil when the private API is unavailable
```

Treat `nil` as "unknown", never as `false`.

## 2. Real full-screen windows do not match the screen size

Measured on one machine, screen `1512×982`:

| Full-screen app | Main window bounds | Size-equality check |
|---|---|---|
| Finder | `1512×945 @0,37` | ❌ not detected |
| Ghostty | `1512×907 @0,75` | ❌ not detected |
| Google Chrome | `1512×857 @0,125` | ❌ not detected |

Apps with a title bar or tab strip split that part into **separate layer-0 windows**;
the main window is only the remainder. TextEdit and System Settings happen to fill
the screen exactly — which is why a check written against them passes review and
then fails on everything the user actually runs.

If you must approximate coverage without the private API, use
"width fills the screen **and** height ≥ 80 % of it" (`ForegroundCoverage.covers`),
and remember the **Dock owns a permanently on-screen `1512×982` layer-0 window** —
"any full-screen window exists ⇒ hide the wallpaper" would silence the app forever.

## 3. The sticky window's occlusion freezes after a Space switch

One `⌃→` between two adjacent ordinary desktops, single-window mode:

```
00:03:55.271  occluded=Y  paused      flagged invisible the instant the switch starts
00:04:11.599  occluded=N  playing     16.3 s later — and only because the next switch nudged it
```

During the transition the sticky window is replaced wholesale by the system's static
wallpaper snapshot. The real window is never composited, so the system honestly
reports "not visible" — while the user is looking straight at the wallpaper.

**Debouncing cannot fix this.** The threshold would have to exceed 16 s, which is
the same as disabling pause-when-covered. The fix is to re-check with a different
signal (`SpaceStrategy.stickyOccluded`), and only when the system claims invisibility,
so the normal playing path costs nothing.

Per-desktop mode is immune: every desktop owns a real window, so no snapshot swap.

## 4. Three shapes that keep coming back

**a. A predicate gets reused; its meaning does not.**
`occlusionState` is deliberately early so the *picture* can recover without a stutter.
Audio reusing it means one beep per swipe. `isOnActiveSpace` is meaningful per-desktop
and constant-true for the sticky window; one formula for both silently breaks one of them.
When a field means different things in two modes, downstream must not share a formula.

**b. Any fixed timeout will be stepped over.**
Three fallbacks failed in a row — 0.7 s, then 2 s, then 0.5 s — because an interactive
gesture can hover for as long as the user likes. A timeout only converts "beeps now"
into "beeps later". Before writing "release after X seconds", ask whether the user can
hold that state for X+1.

**c. A test sample that happens to be the only passing one is worse than no test.**
The size-equality check was verified against TextEdit, and a self-test even asserted
`1512×907 is not full-screen` — which is Ghostty's real full-screen height. The test
did not merely miss the bug, it certified it.

Also: a gate that only knows how to *open* will eventually open forever. State machines
here must be able to close again.

## 5. Debugging playbook

**Turn on the log** (off by default, zero cost when off):

```bash
STARPAPER_DEBUGLOG=1 open -n ~/Applications/StarPaper.app
tail -f ~/Library/Logs/StarPaper.log
```

Each `updatePlayback` prints the whole decision: placement, window count, per-unit
`playing/paused` with its reasons, the audio gate, and what the Space check returned.

**Inspect window state** with the bundled probe:

```bash
swiftc -O tools/space-probe.swift -o /tmp/space-probe && /tmp/space-probe
```

Prints, every 120 ms: frontmost app, how `ForegroundCoverage` classifies it, and every
full-screen-sized window on screen.

**Fake extra displays** — no hardware needed. An Apple-silicon laptop tops out at 2
external displays (4 on a Max chip), but virtual screens are free:

```bash
betterdisplaycli create --type=VirtualScreen --virtualScreenName=Test1
betterdisplaycli set --name=Test1 --connected=on     # REQUIRED: create alone is invisible to the OS
betterdisplaycli set --name=Test1 --connected=off
betterdisplaycli discard --name=Test1                # never run discard without --name
```

**Read the Space layout** (types, order, which app owns each full-screen Space):

```bash
plutil -convert json -o - ~/Library/Preferences/com.apple.spaces.plist
```

Note this file is a **lagging cache**; for the live answer call
`CGSCopyManagedDisplaySpaces` (that is what `SpaceBridge` does).

## 6. Traps that cost hours

- **`⌃←/→` is not equivalent to a trackpad swipe.** With Reduce Motion on it is an
  instant crossfade with no intermediate state, so it cannot reproduce anything that
  needs a half-finished transition. Only a real gesture can hover mid-switch, and it
  cannot be synthesised — WindowServer eats it.
- **Two preference files.** If a sandboxed build ever ran, `defaults read/write` may
  hit `~/Library/Containers/<bundle-id>/Data/Library/Preferences/` while the normal
  build reads `~/Library/Preferences/`. They drift apart silently. Read settings with
  `plutil -p` on the outer file, or trust the debug log header instead.
- **Writing defaults while the app runs gets overwritten** when the app exits and
  flushes its own copy. Quit first, then write, then launch.
- **Verify the running binary, not the installed file.** Compare `ps -Ao pid,lstart`
  against the binary's mtime before concluding a fix did not work.
- **Preferences reach disk seconds late.** Right after changing a setting, `plutil -p`
  can still show the old value; the debug log header is authoritative.
- **UI enable/disable must follow the *resolved* state, not the picked option.**
  Stacked-layer count is forced to 1 whenever placement resolves to single-window,
  including `Auto` with Reduce Motion off — gating the control on `mode == .off`
  alone leaves the user a control that does nothing.
