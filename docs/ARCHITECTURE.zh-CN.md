# StarPaper 架构说明

[English](ARCHITECTURE.md) · **简体中文**

StarPaper 是一个 SwiftPM 可执行目标。应用使用 AppKit 管理生命周期和桌面窗口，使用 SwiftUI 构建设置界面，并通过 AVFoundation 播放本地视频。

## 桌面窗口

**每块显示器的每个桌面（Space）各对应一个**无边框 `NSWindow`。窗口位于桌面图片与 Finder 桌面图标之间，忽略鼠标事件：

```swift
window.level = NSWindow.Level(
    rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1
)
window.collectionBehavior = [
    // 不写第一组标志位 = 只属于创建它的那个桌面（再用 SpaceBridge 搬到目标桌面）
    .stationary,       // 不参与 Exposé —— 写 .managed 会让它出现在 Mission Control 里
    .ignoresCycle,
    .fullScreenNone,
]
window.ignoresMouseEvents = true
```

### 为什么不能是 `.canJoinAllSpaces`

早期版本用一扇 `.canJoinAllSpaces` 的窗口跟着用户在桌面之间跑。那样在开启「辅助功能 → 显示 → 减弱动态效果」时，用 `⌃←` / `⌃→` 切桌面，目标桌面会先露出系统静态壁纸约 0.9 秒，视频才顶上来。

把变量逐个钉死之后，根因只有 `collectionBehavior` 一个 —— 同一个二进制、同一个窗口层级、同一个桌面、同一次转换，只翻这一个标志位：

| collectionBehavior | 切进目标桌面那 0.9 秒里，这扇窗 |
|---|---|
| 每桌面一扇（不写 `.canJoinAllSpaces`） | 全程被实时合成，露出 0.03 秒 |
| `.canJoinAllSpaces`（一扇窗跟着人跑） | 被换成系统静态壁纸 0.95 秒 |

已经排除的因素：窗口层级、重绘频率（画一次就不再画的窗口同样不露）、`.stationary`、窗口的放置方式、离开桌面的时长。顺带解释了一个老现象 —— 只有「最后一个桌面」进出不露，那是 sticky 窗口的通用例外；每桌面一扇之后所有桌面都不露，也就不需要那个例外了。

### 为什么是 `.stationary` 而不是 `.managed`

`.managed` / `.transient` / `.stationary` 是**互斥**的三选一（决定这扇窗在 Exposé 里怎么处理），
不是可以叠加的开关。早期版本写成 `[.managed, .stationary]`，两个位都置了，`.managed` 赢 ——
于是壁纸窗被当成普通窗口参与 Exposé，**Mission Control 里每个桌面都会多冒出几张壁纸缩略图**
（叠了几层就冒几张）。

去掉 `.managed` 之后（2026-08-23 实测，Reduce Motion 开着）：

- `CGSCopySpacesForWindows` 回读，四扇窗仍各属一个桌面 —— 没有退化成 sticky，
  「每桌面一扇」的修复没丢；
- Mission Control 显示 `No Available Windows`，桌面背景上视频照常播。

**「只属于哪个桌面」和「Exposé 怎么处理」是 `collectionBehavior` 里两组独立的标志位**，
第一组不写就是默认的「只属于创建它的那个桌面」，这正是我们要的；`.managed` 从来不是必需的。

### `SpaceBridge`：唯一用到私有 API 的地方

公开 API 既不能枚举桌面，也不能把 `NSWindow` 放到创建它的那个桌面以外的地方。这两步走 SkyLight 的私有符号，全部封装在 `SpaceBridge` 里：

- `CGSCopyManagedDisplaySpaces` —— 读显示器 / 桌面布局，只取普通桌面（`type == 0`）
- `CGSMoveWindowsToManagedSpace` —— 把窗口放到指定桌面
- `CGSCopySpacesForWindows` —— 放完**回读校验**（这套 API 没有返回值，写失败是静默的）

这些符号不需要关闭 SIP，也不需要任何权限，但系统升级可能变化。所以整块是可降级的：符号缺失、布局读不到或窗口放不进去时，自动退回单扇 `.canJoinAllSpaces` 窗口 —— 行为与旧版完全一致，只是那 0.9 秒会回来。用户也可以在设置里手动关掉「每个桌面单独一扇壁纸窗」。

### 跨桌面对时：贵就不做

每个桌面各有一个 player，离开时暂停、进度就停在那儿。切回来时把它 seek 到「此刻正在播的
那一份」的进度上，各桌面才不会越飘越远。

但 seek 的代价取决于**视频的关键帧密度** —— H.264 只能从关键帧往后解码，所以「跳到第 X 秒」
要从最近的关键帧一路解到 X。实测一份 3840×2160 / 60fps / 128 秒、关键帧每 4.17 秒一个
（GOP=250，常见默认值）的壁纸：对时中位 882 ms、最坏 2545 ms，而且下一次对时会把上一次取消 ——
表现是「切过去画面先不对，然后猛跳一下」。同一个文件重压成每秒一个关键帧后，中位降到 345 ms。

所以对时不写死，而是**实测了再决定**（`WallpaperEngine.noteSeekCost`）：给每次 seek 的
耗时打分，中位超过 `seekCostBudgetMs`（220 ms）就关掉这个视频的跨桌面对时，换视频时重新评估。

关掉之后各桌面各播各的：切过去 player 从自己停的地方立刻续播，不解码、不跳帧；
代价只是不同桌面进度不同，转换那 0.4 秒看起来像一次交叉溶解。
拿 1~2.5 秒的错画面加一次猛跳去换一个干净的 0.4 秒混合，并不划算。

### 同时在播的窗口数封顶

飞速连切桌面时，系统会把**沿途每一个**桌面的窗口都标成「不再被遮挡」，而且要等人停下来
约 1.4 秒才一起收回去 —— 11 个桌面连飞一遍，最后十路 4K 同时解码。
`maxConcurrentPlayers = 3` 封顶，按「这一轮从什么时候开始看得见」倒序保留，当前桌面优先。
实测连飞 14 次：CPU 峰值 54.7% → 42.8%，而且回落明显更快。

### 衬窗：`backingLayers`

改成每桌面一扇之后那 0.9 秒没了，但还剩薄薄一层：**切桌面的 0.4 秒里，系统会把桌面层的窗口压暗一下，露出下面的系统静态壁纸**（实测透出约 16.6%）。

这一层挡不住，而且原因跟我们无关 —— 一扇静止的、完全不透明的纯色窗照样被混进约 26%，与窗口内容、层级、`collectionBehavior`、是否重绘都无关，也**不是** Reduce Motion 的过渡效果造成的（关掉它这层残留逐项不变）。

既然挡不住，就在主窗下面多垫几扇窗（`WallpaperWindow.levelOffset`），让透出来的是我们自己的画面而不是壁纸。用纯色探针量「壁纸透出」，衰减是 `1/√n`（不是几何衰减）：

| 每桌面窗口数 | 1 | 2 | 3 | 4 | 6 |
|---|---|---|---|---|---|
| 壁纸透出（纯色探针） | 26.1% | 19.8% | 15.7% | 13.0% | 9.8% |

但**在真实 StarPaper 上不是越多越好** —— 量切桌面时的画面偏离：

| 每桌面窗口数 | 1 | 2 | 3 | 4 | 6 |
|---|---|---|---|---|---|
| 画面偏离 | +10.6 | +4.5 | **+1.9** | −2.0 | −3.2 |

**符号在 3 和 4 之间翻转**：层数少时壁纸透出占上风（壁纸更亮 → 变亮），层数多时衬窗自己偏暗占上风。3 层刚好抵消，所以默认是 3。

衬窗为什么偏暗没查出来 —— 色彩空间试过三种（默认 sRGB / 关掉色彩管理 / 标成 BT.709），偏离分别是 −3.2 / −5.0 / −3.3，只有「关掉色彩管理」明显更差，另外两种在噪声里。

三个要点：

- **衬窗必须显示视频画面**（`BackingWallpaperView`）。垫纯黑窗时「露出更亮的壁纸」会变成「闪一下黑」（实测画面 65.4 → 38.7），比原来更显眼。
- **衬窗的裁剪几何必须和主窗用同一份计算**（`VideoWallpaperView.fillRects`），差一点点透出来的画面就是错位的。

- **喂帧的时机要卡在 Space 转换刚开始**。只在换视频时喂一次固定帧的话，主窗早播远了，透出来就是两个时间点的画面叠在一起（肉眼很明显，像「很多不同时间的画面」叠着）；改成每秒定时喂则 **CPU 1.4% → 5.6%**，把这个方案「几乎不要钱」的前提直接否掉。现在只在遮挡通知到达时喂一次 —— 它在按键后约 0.126 秒就到，而衬窗真正露脸还有约 0.9 秒，来得及，静止时一次都不跑。

衬窗共用同一个 `CGImage`（缩到屏幕逻辑尺寸），不解码也不重绘。

### 桌面的增删

新建 / 删除桌面没有公开通知。`WallpaperEngine` 在 `NSWorkspace.activeSpaceDidChangeNotification` 时对账一次桌面清单，另有一个 20 秒的低频兜底 —— 后者的作用是在用户**第一次切进**新建的桌面之前就把窗口补上，否则那一次仍会露一下。

如果用户选择覆盖桌面图标，窗口层级会相应提高。显示器连接状态变化时，`WallpaperEngine` 会根据当前屏幕重新建立播放单元。

## 播放单元

每个 `VideoWallpaperView` 包含三层：

```text
containerLayer
├── playerLayer   AVPlayerLayer，负责视频与 Core Image 滤镜
└── dimLayer      黑色遮罩，负责等比压暗画面
```

正常循环播放使用 `AVQueuePlayer` 与 `AVPlayerLooper`，避免在视频末尾手动 seek 造成停顿。

自动轮播的“播完切换”模式不能使用 looper，因为 looper 不会产生可用于换片的最终结束事件。此模式改用单个 item 和 `AVPlayerItemDidPlayToEndTime`；多显示器环境中只由主屏播放单元通知选择器，避免一次结束触发多次切换。

## 裁剪模型

StarPaper 保存 `focusX`、`focusY` 与 `zoom`，而不是保存某个屏幕上的固定裁剪矩形。设屏幕尺寸为 `W × H`，视频尺寸为 `vw × vh`：

```text
s = max(W / vw, H / vh) × zoom
w = vw × s
h = vh × s
x = -(w - W) × focusX
y = -(h - H) × focusY
```

`playerLayer.frame` 直接设置为 `(x, y, w, h)`，父层使用 `masksToBounds` 裁掉超出部分。不同宽高比的显示器会用同一组 focus 与 zoom 独立计算，因此裁剪意图可以跨屏幕复用。

## 画面处理

需要画面调节时，`AVPlayerLayer.filters` 使用 Core Image 滤镜链。主要顺序为：

```text
曝光 → 高光/阴影 → 伽马 → 亮度/对比度/饱和度
     → 鲜艳度 → 色温/色调 → 锐化 → 暗角 → 模糊
```

实现约束：

- 挂滤镜前必须设置 `layerUsesCoreImageFilters = true`。
- 不原地修改已经挂载的 `CIFilter`；设置变化时重建滤镜数组。
- `CITemperatureAndTint` 的 neutral / target 语义与常见调色滑杆方向不同，转换时需要处理方向。
- 模糊会消耗画面边缘，因此播放器层会按模糊半径略微放大，再由父层裁切。
- 变暗使用独立黑色 `CALayer` 的 opacity，而不是 `CIColorControls` 的 brightness，避免加法偏移造成灰雾感。
- 所有画面参数为默认值时不挂滤镜，保留系统的视频合成路径。

## 播放来源

`MediaSelector` 集中决定当前视频来源：

```text
日程 > 当前视频（videoPath）
```

`settings.videoPath` 是**正在播的那个**，`settings.playlist` 是**视频库**：可以一键切过去的那些视频。两者不是并列的播放通道，库只参与「下一个是谁」的判断，不参与「现在播谁」。手动选片统一走 `AppSettings.play(_:)`，它顺手把视频收进库，因此内容页和播放页永远指着同一个事实。

早期版本不是这样：库有自己的 `index`，`videoPath` 只当单视频兜底，结果内容页显示 A、桌面在播 B。

日程按白天和夜间时间段选择文件，开启时盖过其余来源。`playlistEnabled` 现在只表示**自动轮播**（播完切 / 定时切，可随机）；手动点库里的某一项任何时候都能用，与这个开关无关。「下一个是谁」抽成 `MediaSelector.nextIndex` 与 `shuffleNext` 两个纯函数，由 `SelfTest` 覆盖。播放引擎只消费选择器给出的路径，不在各个显示器内重复实现选择逻辑。

## 播放状态与省电

`WallpaperEngine.updatePlayback()` 汇总所有播放条件，避免不同事件处理器互相调用 `play()` / `pause()`：

- 用户手动暂停
- 窗口所在的桌面此刻是不是前台桌面（不是就停 —— 没人看得见，继续解码等于按桌面数翻倍烧电）
- 窗口遮挡状态
- 屏幕锁定
- 系统睡眠
- 低电量模式
- 电池供电

窗口遮挡使用 `NSWindow.didChangeOcclusionStateNotification`。电源状态使用 IOKit 的 `IOPSNotificationCreateRunLoopSource` 接入主 run loop，不进行轮询。

## 设置与外部控制

`AppSettings` 是单例 `ObservableObject`，配置写入 `UserDefaults`。SwiftUI 观察设置对象，播放引擎也订阅同一状态。

外部 `defaults write` 或 CLI 修改配置后，`UserDefaults.didChangeNotification` 触发重新加载。加载必须幂等，保存过程还必须防止逐键通知重入；相关不变量见 [维护者笔记](MAINTAINER_NOTES.zh-CN.md)。

“下一个”不是持续状态，CLI 会向 `command` 键写入带唯一后缀的值，应用据此把每次写入识别为独立动作。

## 全局快捷键

快捷键使用 Carbon `RegisterEventHotKey`，只注册用户明确设置的组合。这样不需要辅助功能权限，也不需要全局监听键盘事件。

## 本地化

中英文字符串保存在 `Localization.swift` 的同一张表中。`T("key")` 根据 `AppSettings.shared.language` 取值；SwiftUI 设置变化后自然重绘，AppKit 菜单通过语言订阅重新构建。

## 本地数据边界

当前版本没有网络客户端或遥测 SDK。视频文件由 AVFoundation 在本地读取；用于显示的路径、
只读 security-scoped bookmark、视频库和其他设置保存在当前用户的 `UserDefaults` 域中。
AVFoundation 会惰性读文件，所以 bookmark lease 会保持到 AVAsset / player 换片或卸载。
