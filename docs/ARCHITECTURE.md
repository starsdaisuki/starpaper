# StarPaper 架构说明

StarPaper 是一个 SwiftPM 可执行目标。应用使用 AppKit 管理生命周期和桌面窗口，使用 SwiftUI 构建设置界面，并通过 AVFoundation 播放本地视频。

## 桌面窗口

每块显示器对应一个无边框 `NSWindow`。窗口位于桌面图片与 Finder 桌面图标之间，忽略鼠标事件，并跟随所有 Space：

```swift
window.level = NSWindow.Level(
    rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1
)
window.collectionBehavior = [
    .canJoinAllSpaces,
    .stationary,
    .ignoresCycle,
    .fullScreenNone,
]
window.ignoresMouseEvents = true
```

如果用户选择覆盖桌面图标，窗口层级会相应提高。显示器连接状态变化时，`WallpaperEngine` 会根据当前屏幕重新建立播放单元。

## 播放单元

每个 `VideoWallpaperView` 包含三层：

```text
containerLayer
├── playerLayer   AVPlayerLayer，负责视频与 Core Image 滤镜
└── dimLayer      黑色遮罩，负责等比压暗画面
```

正常循环播放使用 `AVQueuePlayer` 与 `AVPlayerLooper`，避免在视频末尾手动 seek 造成停顿。

播放列表的“播完切换”模式不能使用 looper，因为 looper 不会产生可用于换片的最终结束事件。此模式改用单个 item 和 `AVPlayerItemDidPlayToEndTime`；多显示器环境中只由主屏播放单元通知选择器，避免一次结束触发多次切换。

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
日程 > 播放列表 > 单个视频
```

日程按白天和夜间时间段选择文件；播放列表维护顺序或随机队列，并支持结束切换与定时切换。播放引擎只消费选择器给出的路径，不在各个显示器内重复实现选择逻辑。

## 播放状态与省电

`WallpaperEngine.updatePlayback()` 汇总所有播放条件，避免不同事件处理器互相调用 `play()` / `pause()`：

- 用户手动暂停
- 窗口遮挡状态
- 屏幕锁定
- 系统睡眠
- 低电量模式
- 电池供电

窗口遮挡使用 `NSWindow.didChangeOcclusionStateNotification`。电源状态使用 IOKit 的 `IOPSNotificationCreateRunLoopSource` 接入主 run loop，不进行轮询。

## 设置与外部控制

`AppSettings` 是单例 `ObservableObject`，配置写入 `UserDefaults`。SwiftUI 观察设置对象，播放引擎也订阅同一状态。

外部 `defaults write` 或 CLI 修改配置后，`UserDefaults.didChangeNotification` 触发重新加载。加载必须幂等，保存过程还必须防止逐键通知重入；相关不变量见 [维护者笔记](MAINTAINER_NOTES.md)。

“下一个”不是持续状态，CLI 会向 `command` 键写入带唯一后缀的值，应用据此把每次写入识别为独立动作。

## 全局快捷键

快捷键使用 Carbon `RegisterEventHotKey`，只注册用户明确设置的组合。这样不需要辅助功能权限，也不需要全局监听键盘事件。

## 本地化

中英文字符串保存在 `Localization.swift` 的同一张表中。`T("key")` 根据 `AppSettings.shared.language` 取值；SwiftUI 设置变化后自然重绘，AppKit 菜单通过语言订阅重新构建。

## 本地数据边界

当前版本没有网络客户端或遥测 SDK。视频文件由 AVFoundation 从本地路径读取；文件路径、播放列表和其他设置保存在当前用户的 `UserDefaults` 域中。
