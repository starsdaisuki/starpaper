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

Before submission, add a real Xcode macOS app target (or an equivalent Apple-supported
archive workflow), configure the App Store profile and Apple Distribution signing, then
archive and validate the exact submitted product. The target must define
`STARPAPER_APPSTORE` and use `Resources/StarPaper-AppStore.entitlements`.

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

`make appstore-test` 只产生本地 ad-hoc 沙盒体检包，不是可上传包。真正提交前还要
建 Xcode macOS App target，配置 Apple Distribution 证书和 provisioning profile，再对
最终 `.app` / archive / 上传包做原始字节级隐私扫描。
