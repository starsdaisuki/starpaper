# Mac App Store readiness

StarPaper has two distribution variants because its best per-desktop transition fix needs
SkyLight private API, which App Review Guideline 2.5.1 does not allow.

| Variant | Desktop placement | File access | CLI | Signing |
|---|---|---|---|---|
| Direct / GitHub | Per-desktop SkyLight path with public fallback | Security-scoped bookmarks plus ordinary local access | Available | Developer ID + notarization (`make release-signed`) |
| Mac App Store | Public `.canJoinAllSpaces` path only | App Sandbox + read-only user-selected bookmarks | Not distributed or shown | Apple Distribution + provisioning profile |

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

## 中文说明

StarPaper 保留两个发行变体：GitHub 直装版继续使用实测效果最好的每桌面
SkyLight 方案；App Store 版在编译期彻底移除私有 API，退回公开的单窗
`.canJoinAllSpaces` 方案。Store 版同时启用 App Sandbox 和只读持久 bookmark，
但不分发 CLI，也不显示私有 API 专属的设置。

`make appstore-test` 只产生本地 ad-hoc 沙盒体检包，不是可上传包；可上传包走
`make appstore-package`。**不需要建 Xcode App target** —— 2026-08-31 已用
`altool --validate-app` 实测 `VERIFY SUCCEEDED with no errors` 并成功上传。
仍要对最终 `.app` 与上传包做原始字节级隐私扫描。

⚠️ TestFlight 的两个额外条件都只报**警告**不报错误，所以包能干净上传却依然不能用于
TestFlight：缺 `embedded.provisionprofile` 报 90889；有描述文件但签名 entitlements 里
缺 `com.apple.application-identifier` / `com.apple.developer.team-identifier` 报 90886。
`make appstore-check` 两件都做了，且那两个值是**构建时从描述文件里读**的，
不把 Team ID 写进仓库。
