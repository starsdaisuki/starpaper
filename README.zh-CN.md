# StarPaper

[English](README.md) · **简体中文**

把本地视频变成 macOS 动态壁纸。StarPaper 常驻菜单栏，不显示 Dock 图标；支持多显示器、自定义裁剪、画面调节、播放列表与省电自动暂停。

## 主要功能

- 播放 mp4 / mov 等 macOS 原生支持的视频，并无缝循环
- 多显示器同步显示，支持填充、适应和拉伸
- 自定义裁剪焦点与缩放比例
- 调整曝光、亮度、对比度、色彩、模糊、锐化、暗角和变暗遮罩
- 播放列表、随机播放、定时切换与白天 / 夜间日程
- 被窗口遮挡、锁屏或进入低电量模式时自动暂停
- 全局快捷键、开机自启和中 / 英界面
- 通过 `starpaper` 命令行即时切换视频或调整常用参数

StarPaper 使用公开的 macOS API，不需要关闭 SIP，也不需要辅助功能或屏幕录制权限。

## 下载与安装

当前 Release 需要 macOS 14 或更高版本，并提供 Apple silicon 构建。

1. 从 [Releases](https://github.com/starsdaisuki/starpaper/releases) 下载 `StarPaper.dmg`。
2. 打开 DMG，把 `StarPaper.app` 拖进 `/Applications`。
3. 首次启动时选择一个本地视频。

当前发布包使用 ad-hoc 签名，未经过 Apple 公证。Gatekeeper 如果提示应用“已损坏”或无法打开，请确认文件来自本仓库的 Release，再运行：

```bash
xattr -dr com.apple.quarantine /Applications/StarPaper.app
```

也可以[从源码构建](CONTRIBUTING.zh-CN.md)，本地构建通常不需要移除 quarantine 属性。

## 快速使用

- 菜单栏图标可以暂停、继续、切换下一个视频或打开设置。
- 设置窗口包含内容、画面、声音、省电、日程、快捷键和通用选项。
- 默认静音；多显示器环境中只有主屏播放器输出声音。
- 日程启用时优先级最高，其次是播放列表，最后是单个视频。

完整操作与命令行说明见 [使用指南](docs/USAGE.zh-CN.md)。

## 隐私

视频只在本机通过 AVFoundation 播放。当前版本不包含账号、网络请求、遥测或分析服务；所选视频路径和设置保存在本机的 `UserDefaults` 中。

## 已知限制

- 所有显示器目前共用同一套视频与裁剪参数
- 暂不支持图片、GIF、视频缩略图库或按日出日落自动切换
- 发布包没有 Apple Developer 公证

## 文档

- [使用指南](docs/USAGE.zh-CN.md)
- [构建与贡献](CONTRIBUTING.zh-CN.md)
- [架构说明](docs/ARCHITECTURE.zh-CN.md)
- [维护者笔记](docs/MAINTAINER_NOTES.zh-CN.md)

## License

[MIT](LICENSE)
