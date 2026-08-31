# StarPaper 维护者笔记

[English](MAINTAINER_NOTES.md) · **简体中文**

这里记录容易被“看起来更简单”的改动破坏的行为不变量。修改相关代码前，请同时阅读 [架构说明](ARCHITECTURE.zh-CN.md)，完成后运行 `make test`。

## 设置层

### 不要把 `AppSettings` 改名为 `Settings`

SwiftUI 已有 `Settings<Content>` scene。在导入 SwiftUI 的上下文中使用同名类型，会造成解析冲突和难以理解的泛型错误。

### `load()` 必须幂等

`@Published` 属性即使赋相同的值也会发送 `objectWillChange`。如果 `load()` 无条件赋值，它会触发 `save()`，随后再次收到 `UserDefaults.didChangeNotification`，形成循环。

所有回读都应通过 `setIfChanged(_:_:)`，只在值真正变化时写内存。

### 保存需要两道重入保护

`UserDefaults` 的逐键写入会逐次发送变化通知。保存第一个键时，如果监听者立刻 `load()`，尚未写入的键会被磁盘旧值覆盖；保存随后可能把旧值重新写回。

必须同时保留：

- `isSaving`：阻止保存过程中的通知重入
- `hasUnsavedChanges`：阻止 debounce 等待期间从仍是旧值的磁盘回读

少任何一个都会重新引入“设置刚修改就弹回原值”的问题。

### 自检不能使用真实设置域

自检会翻转设置来验证读写。即使测试结束后恢复磁盘值，另一个正在运行的实例也可能在测试期间读到临时值，并在稍后重新保存。

`SelfTest` 必须使用一次性的 `UserDefaults` suite，通过 `useDefaultsSuite(_:)` 把整个设置层切过去；测试结束后删除该 suite。不要临时写入 `UserDefaults.standard`。

## 窗口与应用生命周期

### `NSWindow` 子类初始化

带 `screen:` 参数的 `NSWindow.init(contentRect:styleMask:backing:defer:screen:)` 是 convenience initializer，子类不能通过 `super.init` 调用。使用四参数 designated initializer，再调用 `setFrame`。

### 主菜单不能省略

即使 accessory app 不显示菜单栏，`NSApplication` 仍依靠 `mainMenu` 派发许多 Command 快捷键。没有主菜单时，设置窗口中的 ⌘W、⌘A、⌘V、⌘X、⌘Z 等不会正常工作。

保留隐藏的标准菜单项，同时避免随意加入会关闭整个壁纸引擎的快捷动作。

### 桌面图标与菜单栏图标是外部状态

- Finder 的“显示桌面项目”关闭后，桌面图标本来就不存在，不能据此判断窗口层级错误。
- Ice、Bartender 等工具可能折叠菜单栏项目，不能仅凭肉眼看不到图标判断 `NSStatusItem` 创建失败。

## 桌面窗口（每桌面一扇）

### `collectionBehavior` 不能就地改

`.canJoinAllSpaces` ↔ `.managed` 只在窗口创建时生效，改已有窗口不会重新分配桌面归属。
放置方式变了必须整个重建窗口（`WallpaperEngine.applySettings()` 里就是这么判的）。

### 先 `orderFront` 再搬窗口

`NSWindow.windowNumber` 在窗口真正挂进 WindowServer 之前是 0，
拿 0 去调 `CGSMoveWindowsToManagedSpace` 会静默失败。

### CGS 的写操作没有返回值，必须回读校验

`CGSMoveWindowsToManagedSpace` 不返回任何东西，失败是静默的。
放完一定要用 `CGSCopySpacesForWindows` 回读确认，否则会留下一扇看不见的窗。
搬不动的那一扇要直接撤掉 —— 留着它会退化成一扇跟着当前桌面跑的多余窗口。

### 桌面的增删没有公开通知

只能在 `activeSpaceDidChangeNotification` 时对账，再加一个低频兜底。
少了兜底的话，用户第一次切进刚建好的桌面仍会露一次。

### ⚠️ 遮挡状态必须现读，不能只信通知

窗口是在当前桌面建好之后再搬到目标桌面的，被搬走的那几扇**从来不会收到**
`didChangeOcclusionStateNotification`，`isOccluded` 会一直停在初始值 `false`。
拿这个缓存值当判据的话，所有桌面都被判成「看得见」，四个桌面全在解码
（实测 CPU 5% → 11%）。通知只负责触发重新决策，状态本身每次都从
`window.occlusionState` 现读。

### `activeSpaceDidChange` 比画面晚约 0.93 秒

实测：按 `⌃→` 之后 **0.126s** 系统就发了遮挡通知，**1.056s** 才发
`activeSpaceDidChangeNotification`（我们自己的代码只花 2 ms）。
所以「等 activeSpaceDidChange 再恢复播放」必然让人先看到 0.1~0.25 秒的卡顿加一次跳帧。
恢复播放的判据要带上「此刻没被遮挡」，那是转换一开始就到的公开信号。

### ⚠️ 量「露不露」时先清干净桌面层

亮度探针把「屏幕上出现亮画面」当成露出系统静态壁纸。
任何遗留在桌面层的测试窗口（尤其是会变色的）都会被算进去，
表现为「某一条边偶发 0.1~0.4 秒」，看起来特别像真 bug。
量之前先确认桌面层只有 Dock / Finder / StarPaper：

```bash
swift -e 'import AppKit
let all = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
print(Set(all.compactMap { w -> String? in
    (w[kCGWindowLayer as String] as! Int) < -2_000_000_000
        ? (w[kCGWindowOwnerName as String] as? String) : nil }).sorted())'
```

### 默认值为 `true` 的布尔，自检不能只比值

键不存在时 `UserDefaults.bool(forKey:)` 读出来是 `false`，
和「确实被存成 false」完全一样。所以 `save()` 漏写这个键，只比值的断言照样绿。
必须额外断言 `object(forKey:) != nil`。`muted` 就属于这一类（`perSpaceWindows` 曾经也是，现已换成字符串枚举 `perSpaceMode`，load 时会从老的布尔键迁移一次）。

`backingLayers` 是同一个坑的整数版，而且更隐蔽：漏写时 `integer(forKey:)` 读出来是 `0`，
而 `load()` 会把 `0` 夹回合法下限 `1` —— **正好等于默认值**，值断言照样绿。同样要验键存在。

## 设置界面

### `Form` 里不能再套 `List`

`Form(.formStyle(.grouped))` 本身就是一个 List，嵌在它里面的 `List` 会**吞掉滚轮事件**：
既不滚自己，也不上抛给外层。视频库一旦超过可视高度，下面几个就永远看不到。

实测（macOS 15.7.4，设置窗口真实视图树）：内层 `ListCoreScrollView` 装着 797pt 内容、
可视区只有 150pt，滚轮事件确实命中了它，位移却恒为 `0.0`；
同一测法换成 `ScrollView` 位移 `320pt`。

所以视频库用的是 `ScrollView` + `LazyVStack`，选中、⌘/⇧ 多选、拖动排序都是手写的
（`LibraryReorderDrop` 就是 `List.onMove` 的替身）。**要在设置窗口里放第二个列表时别走回头路。**

### ⚠️ 设置改动的调度器不能用 `RunLoop.main`

Combine 的 `RunLoop` 调度器底下是 `RunLoop.perform`，**只往 runloop 的 default 模式投递**。
拖动滑杆（以及拖窗口、拉菜单）时 AppKit 的跟踪循环把主 runloop 切进
`NSEventTrackingRunLoopMode`，于是整个拖动过程订阅方一次都收不到，松手回到 default
模式才一次性补上 —— 表现为「拖的时候壁纸完全没反应，松手才一下跳到位」，
音量、播放速度、影调滑杆全中招。

实测（拖动期间连发 5 次改动，主 runloop 只跑事件跟踪模式）：

| 调度器 | 拖动中收到 | 松手后收到 |
|---|---|---|
| `.receive(on: RunLoop.main)` | **0** | 5 |
| `.receive(on: DispatchQueue.main)` | **5** | 5 |

主队列那条 source 注册在 common modes 里，事件跟踪期间照样被排空，所以走
`DispatchQueue.main`。这条封装在 `LiveSettingsRelay`，它同时把一轮 runloop 内的多次改动
合并成一次 `applySettings()`（拖动是逐帧来的，`load()` 一次能连发几十条 `@Published`，
每条都重建整条 CIFilter 链 × 所有窗 × 每桌面几扇衬窗）。
回归测试 `SelfTest.liveSettingsRelaySelfTest()` 会在事件跟踪模式下跑 runloop，
换回 `RunLoop.main` 直接红。

## 播放

### `AVPlayerLooper` 与结束切换不能同时使用

looper 用于无缝循环，但不会给播放列表提供最终结束点。“播完切换”模式必须使用单个 player item 和结束通知。

多显示器会为同一视频创建多个播放器。只允许主屏播放单元上报结束，否则一次结束会连续跳过多个列表项目。

### 所有播放条件汇总到一个入口

手动暂停、遮挡、锁屏、睡眠、电池与低电量状态都交给 `WallpaperEngine.updatePlayback()` 汇总。事件处理器不要各自直接决定最终的 play / pause 状态。

## 滤镜与裁剪

- `CALayer.filters` 使用前必须启用 `layerUsesCoreImageFilters`。
- 已挂载的 `CIFilter` 不要原地修改；重建整条滤镜链。
- 默认画面参数不应创建滤镜，避免不必要地改变合成路径。
- 裁剪持久化 focus + zoom，不要保存某个显示器的固定像素矩形。
- 模糊需要扩大视频层以覆盖采样边缘，避免出现透明或黑边。
- 变暗遮罩保持为独立黑色 layer，不要换成亮度加法偏移。

## 权限与快捷键

全局快捷键使用 `RegisterEventHotKey`。不要改成 NSEvent 全局监听；后者需要辅助功能权限，权限范围与功能需求不匹配。

验证桌面效果时，注意没有屏幕录制权限的截图工具可能返回不包含窗口层的降级截图。

## 构建与发布

- `make test` 会先构建 bundle，再在隔离设置域中运行自检。
- 测试播放或能耗前，确认壁纸没有因为窗口遮挡而暂停。
- Release 只应包含 `.app` / `.dmg`，不得包含 `.build/`、dSYM、module cache、对象文件或原始构建描述；这些产物可能嵌入本机绝对路径。
- 发布前检查 DMG 清单、签名状态和架构，并对源码、Git 历史与发布资产做隐私扫描。
  Mach-O 要用 `rg -a` 扫原始字节，不能只信 `strings`：`N_OSO` 对象路径可能被
  `strings` 漏掉。Bundle 在签名前先 strip debug symbols，避免带出本机构建路径。
- 不要把本地会话交接、绝对路径、真实媒体文件、设备清单或跨项目笔记提交到公开仓库。

### 让别人下载后能直接打开的签名

ad-hoc 签名的 `.app` 在别人机器上一律被 Gatekeeper 拦，对方必须先跑
`xattr -dr com.apple.quarantine`。根治只有一条路：Developer ID Application 证书 +
Hardened Runtime + 公证（notarization）+ stapling。

- `make devid-check` 检查钥匙串里有没有这张证书，没有就直接打印 Xcode 里的建法。
  ⚠️ 它和 Mac App Store 用的 Apple Distribution 是两张不同的证书。
- `make notarize-setup` 打印一次性的 `xcrun notarytool store-credentials` 命令。
  它要的是 **app 专用密码**，不是 Apple Account 本身的密码。
- `make release-signed` 一条龙：Hardened Runtime + 安全时间戳签名 → 打并签 dmg →
  提交公证 → `stapler staple` 钉票据 → 用 `spctl` 以 Gatekeeper 的身份复验。
  钉票据的意义是**离线**也能验通过。
- 票据钉在 dmg 上；要单独发 `.app`，得对它再 staple 一次。

### 锁屏没有公开通知可用

`NSWorkspace.sessionDidResignActive` 是**快速用户切换**，不是锁屏 —— 锁屏时会话并没有
离开 console，这条通知根本不会发。用它替换 `com.apple.screenIsLocked` 会让界面上
「锁屏时暂停」变成死开关。现在两条都收，且**分开记两个字段**：否则「锁着屏被切走又
切回来」会把锁屏状态误清掉。抽出 `PowerMonitor.LockState` 就是为了让自检能重放这些事件序列。

通知名是未文档化的，但 `DistributedNotificationCenter` 本身是公开 API、不涉及任何私有符号，
所以 App Store 变体也保留它。
