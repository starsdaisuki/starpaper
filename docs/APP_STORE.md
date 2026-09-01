# Mac App Store readiness

StarPaper has two distribution variants because its best per-desktop transition fix needs
SkyLight private API, which App Review Guideline 2.5.1 does not allow.

| Variant | Desktop placement | File access | CLI | Signing |
|---|---|---|---|---|
| Direct / GitHub | Per-desktop SkyLight path with public fallback | Security-scoped bookmarks plus ordinary local access | Available | Developer ID + notarization (`make release-signed`) |
| Mac App Store | Public `.canJoinAllSpaces` path only | App Sandbox + read-only user-selected bookmarks | Not distributed or shown | Apple Distribution + provisioning profile |

### What the Mac App Store build is missing, and who can tell

| Removed from the App Store build | Visible to a user when |
|---|---|
| One wallpaper window per desktop (`perSpaceMode`, including **Auto · follow Reduce Motion**) | **Only while macOS "Reduce motion" is ON.** With it off, Space switching uses the slide path, which composites both Spaces live and never reveals the static wallpaper. Reduce motion is off by default. |
| Wallpaper above / below desktop icons (`iconLayer`) | Always — the App Store build always keeps Finder icons on top |
| Stacked backing windows (`backingLayers`) | Only in per-desktop mode, which the App Store build does not have |
| The `starpaper` command line | Only for users who wanted to script it |

Everything else ships in both variants: playback itself, multi-display, scale modes, crop and
zoom, all eight image adjustments, the clock overlay, the thumbnail library, auto-advance and
day/night schedules, occlusion / lock-screen / Low Power Mode pausing, global hotkeys, launch
at login and the English / Chinese interface.

⚠️ **Say this in user-facing terms, not as "private API removed".** The technical reason was
recorded on 2026-08-27, but nobody translated it into "the App Store build loses these three
settings" until a user opened the App Store build on 2026-09-01 and went looking for the
Reduce Motion option. A build variant that silently drops settings needs the consequence
written down where someone will read it, not just the cause.

`make appstore-test` builds a local ad-hoc sandboxed inspection bundle. It verifies the
entitlements, runs the self-test, and scans the raw Mach-O bytes for private SkyLight / CGS
names and absolute build paths from the developer's machine. It is deliberately **not** an uploadable App Store package.

An Xcode app target is **not** required. `make appstore-package` produces a package that
App Store Connect accepts: verified on 2026-08-31 with
`xcrun altool --validate-app -t macos`, which reported `VERIFY SUCCEEDED with no errors`,
followed by a successful `--upload-app`.

TestFlight needs two more things beyond a valid signature, and each one is reported as a
warning rather than an error, so a package can upload cleanly and still be ineligible:

- `Contents/embedded.provisionprofile`, a Mac App Store provisioning profile. Without it,
  warning **90889**.
- `com.apple.application-identifier` and `com.apple.developer.team-identifier` in the
  signed entitlements, matching the ones inside that profile. With a profile but without
  these, warning **90886**.

`make appstore-check` handles both: it copies `$(APPSTORE_PROFILE)` into the bundle and
merges those two keys out of the profile into `build/appstore-entitlements.plist`, which is
what actually gets signed. The keys are read from the profile at build time rather than
committed, so no team identifier lives in this repository. The profile itself is not
committed either — it is account-bound and useless to anyone else. Generate one from
developer.apple.com under Profiles, choosing Mac App Store, this bundle identifier and the
Apple Distribution certificate, then save it to `Resources/StarPaper-AppStore.provisionprofile`.

Without a profile the package still uploads and can be submitted for review; only
TestFlight is lost.

Still required outside the source tree:

- App Store Connect record, Utilities category, age-rating answers and privacy answers
- Privacy Policy URL pointing to `PRIVACY.md`, plus Support URL
- Review Notes explaining the menu-bar-only UI, first-run file picker, local-only playback,
  user-controlled login item and automatic power-saving pauses
- A small original or otherwise licensed review video and matching screenshots
- Tests on the current macOS release as well as the macOS 14 deployment floor
- Raw-byte privacy scan of the final `.app`, archive and upload package

The App Store build intentionally hides controls for per-desktop windows, stacked backing
windows, covering Finder icons and external `defaults` control. A setting being off by
default is not enough: prohibited private code must be absent from the submitted binary.

## 1.0.1 backlog

Collected while StarPaper 1.0.0 went through review on 2026-09-01. None of these can go
into 1.0.0 — it is under review, and changing the build restarts the queue.

### 1. Ship the bundle as `StarPaper.app`, not `StarPaper-AppStore.app`

`APPSTORE_BUNDLE := build/$(APP)-AppStore.app` is what `productbuild --component` writes into
the package payload, so a store user installs `/Applications/StarPaper-AppStore.app` and sees
that name in Finder, Launchpad and the Dock. `CFBundleName` is already correct, but Finder
shows the file name. Fix: build the store bundle at `build/appstore/$(APP).app`.

### 2. Fall back to the demo clip when a bookmark cannot be resolved

Container migration moves an existing non-sandboxed `~/Library/Preferences/<bundleid>.plist`
into the sandbox container on first launch. The migrated `videoPath` and `mediaBookmarks`
came from the non-sandboxed build, so the sandbox cannot resolve them — the wallpaper is
black while the clock overlay still draws. Fix: when no bookmark resolves, play the bundled
demo clip and tell the user to pick their video again, instead of leaving a black screen.

### 3. Offer the open-source build to users who have Reduce Motion on

Only the per-desktop feature is missing from this build, and it is only observable while
macOS Reduce motion is on. Show a line in Settings > Content, in the
`#if STARPAPER_APPSTORE` branch, gated on `reduceMotionNow` — `SettingsView` already keeps
that flag live (`accessibilityDisplayShouldReduceMotion`, refreshed on
`accessibilityDisplayOptionsDidChangeNotification`). The button opens
<https://github.com/starsdaisuki/starpaper> with `NSWorkspace.shared.open`, the same pattern
as the existing Privacy Policy button.

Link the **repository home page**, not a release tag (a tag pins users to 1.0.0 forever,
and an App Store build cannot change the URL without another submission) and not the `.dmg`
itself. The repository README opens on the install instructions.

⚠️ **Keep the wording accurate.** The only difference is the per-desktop path, and it is
only observable while Reduce motion is on — so calling the other build "full" or this one
crippled would simply be wrong. Say that this build uses public API only and that an
open-source build covers the per-desktop case. Keeping it behind the Reduce Motion check
means users who never see the problem never see the message.

### 4. Research: per-desktop windows without private API

Instead of asking the system for the list of desktops (private), create a window on a
desktop the first time the user actually visits it. Both pieces are public API:
`NSWorkspace.activeSpaceDidChangeNotification` and `NSWindow.isOnActiveSpace` — on a space
change, if no existing wallpaper window reports `isOnActiveSpace`, make one.

Costs: the first visit to each desktop after launch can still leak, and windows for closed
desktops linger because there is no public way to learn a desktop is gone. Unverified for
full-screen spaces and multi-display. Not scheduled; the existing window, playback-sync and
Reduce Motion code would carry over rather than be rewritten.

## 中文说明

StarPaper 保留两个发行变体：GitHub 直装版继续使用实测效果最好的每桌面
SkyLight 方案；App Store 版在编译期彻底移除私有 API，退回公开的单窗
`.canJoinAllSpaces` 方案。Store 版同时启用 App Sandbox 和只读持久 bookmark，
但不分发 CLI，也不显示私有 API 专属的设置。

### Store 版少了什么，以及什么情况下才感知得到

| App Store 版拿掉的 | 用户什么时候会察觉 |
|---|---|
| 每桌面一扇壁纸窗（`perSpaceMode`，含**自动 · 跟随「减弱动态效果」**）| **只有系统「减弱动态效果」开着时。** 关着时切 Space 走 slide 路径，两个 Space 实时并排合成，本来就不露静态壁纸。而这个开关**默认是关的**。 |
| 图标在上 / 壁纸在上（`iconLayer`）| 总是 —— Store 版恒定保留 Finder 桌面图标在上 |
| 叠几扇衬窗（`backingLayers`）| 只在每桌面模式下有意义，Store 版没有那个模式 |
| `starpaper` 命令行 | 只有想写脚本的人 |

其余全部两版都有：播放本身、多显示器、缩放模式、裁剪与变焦、八项图像调节、时钟叠加、
缩略图视频库、自动轮播与日夜计划、遮挡 / 锁屏 / 低电量暂停、全局热键、开机启动、中英界面。

⚠️ **要用「用户会失去什么」的说法讲，不要只写「移除了私有 API」。**
技术原因 2026-08-27 就记下了，但直到 2026-09-01 有人打开 Store 版去找那个
Reduce Motion 选项，才有人把它翻译成「Store 版少了这三个设置」。
**编译变体悄悄少掉设置项，后果必须写在有人会读到的地方，不能只写原因。**

`make appstore-test` 只产生本地 ad-hoc 沙盒体检包，不是可上传包；可上传包走
`make appstore-package`。**不需要建 Xcode App target** —— 2026-08-31 已用
`altool --validate-app` 实测 `VERIFY SUCCEEDED with no errors` 并成功上传。
仍要对最终 `.app` 与上传包做原始字节级隐私扫描。

⚠️ TestFlight 的两个额外条件都只报**警告**不报错误，所以包能干净上传却依然不能用于
TestFlight：缺 `embedded.provisionprofile` 报 90889；有描述文件但签名 entitlements 里
缺 `com.apple.application-identifier` / `com.apple.developer.team-identifier` 报 90886。
`make appstore-check` 两件都做了，且那两个值是**构建时从描述文件里读**的，
不把 Team ID 写进仓库。

### 1.0.1 待办

2026-09-01 StarPaper 1.0.0 过审期间攒下的。**都进不了 1.0.0** —— 它在审核中，动 build 就要重排队。

**① 打出来的包应该叫 `StarPaper.app`，不是 `StarPaper-AppStore.app`**

`APPSTORE_BUNDLE := build/$(APP)-AppStore.app` 会被 `productbuild --component` 写进安装载荷，
于是商店用户装到的是 `/Applications/StarPaper-AppStore.app`，Finder / 启动台 / Dock 里显示的就是这个名字。
`CFBundleName` 本身是对的，但 Finder 显示的是**文件名**。改法：把 Store 包建到 `build/appstore/$(APP).app`。

**② bookmark 解不开时退回内置 demo，别留一片黑**

容器迁移会在首次启动时把已有的非沙盒 `~/Library/Preferences/<bundleid>.plist` **搬进**沙盒容器。
搬进来的 `videoPath` / `mediaBookmarks` 是非沙盒版建的，沙盒解不开 ⇒ 壁纸全黑、只剩时钟在画。
改法：一个 bookmark 都解不开时，播内置 demo 并提示用户重新选视频。

**③ 给开着 Reduce Motion 的用户一个开源版入口**

这个变体只少了每桌面那一套，而它**只在系统「减弱动态效果」开着时才看得出来**。
在设置 → Content 的 `#if STARPAPER_APPSTORE` 分支里加一行，用 `reduceMotionNow` 做条件 ——
`SettingsView` 已经在实时跟这个标志（`accessibilityDisplayShouldReduceMotion`，
随 `accessibilityDisplayOptionsDidChangeNotification` 刷新），不用新写管线。
按钮用 `NSWorkspace.shared.open` 打开 <https://github.com/starsdaisuki/starpaper>，
和现有的「隐私政策」按钮同一个写法。

链接指**仓库首页**：release tag 会把用户永远钉在 1.0.0（App Store 版改不了 URL，除非再提交一次），
直接指 `.dmg` 则文件名带版本会变、观感也最差。仓库首页落地就是安装说明。

⚠️ **措辞要准确**：两者的差别只有每桌面那一套，而且只在 Reduce Motion 开着时看得出来 ——
所以把另一个叫「完整版 / 满血版」、或者把这个说成残废，本身就不符合事实。
只说这个版本仅使用公开接口、开源版覆盖每桌面那个场景。
藏在 Reduce Motion 判断后面的意义是：看不到问题的用户就不该看到这句话。

**④ 研究方向：不用私有 API 也做每桌面窗**

不去问系统要桌面名单（私有），而是**等用户第一次真的走到某个桌面时，当场在那儿建一扇窗**。
两块拼图都是公开 API：`NSWorkspace.activeSpaceDidChangeNotification` 和 `NSWindow.isOnActiveSpace`
—— 切桌面时如果现有壁纸窗没有一个 `isOnActiveSpace`，就新建一扇。

代价：每个桌面在启动后**第一次**去仍可能闪；桌面被关掉后窗口会残留（没有公开办法知道某个桌面没了）。
全屏 Space 与多显示器下是否稳定**未验证**。不排期。现有的窗口、播放同步与 Reduce Motion 判断都能复用，不是重写。

