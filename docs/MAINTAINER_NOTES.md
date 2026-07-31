# StarPaper 维护者笔记

这里记录容易被“看起来更简单”的改动破坏的行为不变量。修改相关代码前，请同时阅读 [架构说明](ARCHITECTURE.md)，完成后运行 `make test`。

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
- 不要把本地会话交接、绝对路径、真实媒体文件、设备清单或跨项目笔记提交到公开仓库。
