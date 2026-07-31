# StarPaper 使用指南

[English](USAGE.md) · **简体中文**

## 系统要求

- macOS 14 或更高版本
- 当前 Release 为 Apple silicon 构建
- 一个 macOS 原生支持的视频文件，例如 mp4 或 mov

StarPaper 不需要辅助功能、屏幕录制权限，也不需要关闭 SIP。

## 安装

从 [Releases](https://github.com/starsdaisuki/starpaper/releases) 下载 DMG，把 `StarPaper.app` 拖进 `/Applications`。

发布包使用 ad-hoc 签名且未经过 Apple 公证。确认文件来自本仓库后，如果 Gatekeeper 阻止首次启动，运行：

```bash
xattr -dr com.apple.quarantine /Applications/StarPaper.app
```

从源码构建的方法见 [CONTRIBUTING.zh-CN.md](../CONTRIBUTING.zh-CN.md)。

## 第一次启动

首次运行时，如果还没有选择视频，StarPaper 会自动打开设置窗口。

1. 在“内容”页选择视频。
2. 选择缩放方式：填充、适应或拉伸。
3. 按需要调整裁剪焦点与缩放。
4. 关闭设置窗口；StarPaper 会继续在菜单栏运行。

菜单栏图标可以暂停、继续、切换到播放列表的下一个视频、静音或打开设置。

## 内容与裁剪

- **填充**：保持宽高比并铺满屏幕，超出部分会被裁掉。
- **适应**：保持宽高比并完整显示，屏幕边缘可能留黑。
- **拉伸**：直接匹配屏幕尺寸，可能改变画面比例。
- **裁剪焦点**：决定填充模式优先保留视频的哪一部分。
- **缩放**：在铺满屏幕的基础上继续放大。

所有显示器目前共用一套视频和裁剪参数，但会按各自宽高比重新计算画面位置。显示器连接状态变化或系统睡眠唤醒后，窗口会自动重建。

桌面图标默认显示在动态壁纸上方，也可以切换为由动态壁纸覆盖。

## 画面调节

设置中的“画面”页分为三组：

- **影调**：曝光、亮度、对比度、高光、阴影、伽马
- **色彩**：饱和度、鲜艳度、色温、色调
- **效果**：模糊、锐化、暗角、暗角范围、变暗遮罩

“恢复默认画面设置”会清空全部画面调节，但不会更换视频或裁剪参数。

## 播放列表与日程

播放列表支持：

- 顺序或随机播放
- 每段视频播放完后切换
- 按固定时间间隔切换

日程可以为白天和夜间分别选择视频并设置切换时间。播放来源的优先级为：

```text
日程 > 播放列表 > 单个视频
```

启用日程后，播放列表和单个视频仍会保留，但当前不会生效。

## 声音与省电

声音默认关闭。打开声音后，多显示器环境中只有主屏对应的播放器输出音频，避免重复回声。

以下自动暂停条件可以分别开关：

- 动态壁纸被其他窗口完全遮挡
- 屏幕锁定
- 系统进入低电量模式
- 设备正在使用电池

这些状态恢复后，是否继续播放仍会综合考虑手动暂停和其他暂停条件。

## 全局快捷键

可以为暂停、下一个、静音和打开设置分别录制快捷键。快捷键默认全部为空，并且必须至少包含一个修饰键。

StarPaper 使用 Carbon 的 `RegisterEventHotKey` 注册指定组合，不会请求辅助功能权限，也不会监听全部键盘输入。

## 命令行

从源码目录运行以下命令，把 CLI 链接到 `~/.local/bin`：

```bash
make link
```

确认 `~/.local/bin` 已加入 `PATH` 后，可以使用：

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

CLI 是 `defaults` 的薄包装。应用监听设置变化，因此大多数命令会立即生效，不需要重启；“下一个”通过一次性命令通道发送。

结构化的播放列表、日程和快捷键建议使用图形界面修改。

## 配置位置

设置保存在当前用户的：

```text
~/Library/Preferences/io.github.starsdaisuki.starpaper.plist
```

也可以直接使用 `defaults`：

```bash
defaults write io.github.starsdaisuki.starpaper videoPath -string "/path/to/video.mp4"
defaults write io.github.starsdaisuki.starpaper dim -float 0.3
defaults read io.github.starsdaisuki.starpaper
```

直接写入配置时请使用应用支持的键和值域。`starpaper reset` 会删除整个配置域，并提示重启应用。

## 常见问题

### Gatekeeper 提示应用已损坏

当前 Release 没有 Apple Developer 公证。确认 DMG 来自本仓库后，按“安装”一节移除 quarantine 属性。

### 看不到菜单栏图标

先检查 Ice、Bartender 等菜单栏管理器是否把图标折叠或隐藏。退出并重新打开 StarPaper 也会重建菜单栏项目。

### 看不到桌面图标

检查系统的“显示桌面项目”设置。即使 StarPaper 位于正确层级，系统关闭桌面项目后 Finder 也不会显示图标。

### 截图里没有动态壁纸

没有屏幕录制权限的终端可能得到不包含窗口层的降级截图。不要用这类截图单独判断壁纸窗口是否工作。

### 壁纸没有播放

检查菜单栏中的手动暂停状态，以及设置里的遮挡、锁屏、低电量和电池暂停条件。调试能耗或播放问题时，先确认桌面没有被窗口完全遮挡。
