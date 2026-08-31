<div align="center">

<img src="res/icon.png" width="120" alt="StarPaper">

# StarPaper

**把本地视频变成 macOS 动态壁纸。**

[![release](https://img.shields.io/github/v/release/starsdaisuki/starpaper?label=release&color=4c1)](https://github.com/starsdaisuki/starpaper/releases)
[![macOS](https://img.shields.io/badge/macOS-14%2B-555)](#安装)
[![license](https://img.shields.io/github/license/starsdaisuki/starpaper)](LICENSE)

[English](README.md) · **简体中文**

</div>

支持多显示器、自定义裁剪、画面调节、视频库与省电自动暂停。常驻菜单栏；「只在菜单栏显示」是可选项，不是默认。

## 主要功能

- 播放 mp4 / mov 等 macOS 原生支持的视频，并无缝循环
- 多显示器同步显示，支持填充、适应和拉伸
- 每个桌面（Space）单独一扇壁纸窗，切换桌面时不会先露出系统静态壁纸
- 每个桌面可叠多扇壁纸窗，把切换瞬间剩下的那层淡淡的壁纸透出也压掉（叠出来的窗不解码不重绘，实测 CPU 与内存增量都在噪声里）
- 自定义裁剪焦点与缩放比例
- 调整曝光、亮度、对比度、色彩、模糊、锐化、暗角和变暗遮罩
- 可选的桌面时钟，叠在壁纸之上：最多三行自定义格式、外发光、双色循环，矢量渲染任何分辨率都清晰
- 视频库：常用壁纸收进来，**点一下就切过去播**，列表里带缩略图
- 自动轮播（播完换 / 定时换，可随机）与白天 / 夜间日程
- 被窗口遮挡、锁屏或进入低电量模式时自动暂停
- 全局快捷键、开机自启和中 / 英界面
- 通过 `starpaper` 命令行即时切换视频或调整常用参数

StarPaper 不需要关闭 SIP，也不需要辅助功能或屏幕录制权限。除了「每个桌面单独一扇壁纸窗」用到的几个 SkyLight 私有符号（用于枚举桌面和把窗口放到指定桌面，符号不可用时自动降级；也可以在设置里关掉，关掉后完全只用公开 API）之外，其余全部是公开 macOS API。

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
- 日程启用时优先级最高，其次是当前视频；视频库决定「下一个是谁」。
- 「当前视频」和视频库是同一套东西：手动挑的视频自动进库，轮播换片时内容页也跟着变。

完整操作与命令行说明见 [使用指南](docs/USAGE.zh-CN.md)。

## 隐私

视频只在本机通过 AVFoundation 播放。当前版本不包含账号、网络请求、遥测或分析服务；
所选视频路径、只读的持久文件授权与设置都只保存在本机。详见[隐私政策](PRIVACY.md)。

## 已知限制

- 所有显示器目前共用同一套视频与裁剪参数
- 「每个桌面单独一扇壁纸窗」会随桌面数量小幅增加内存占用（4 个桌面实测约 +4 MB，CPU 不变 —— 同一时刻只有前台那个桌面在解码）。它默认是**自动**档：只在系统「辅助功能 → 显示 → 减弱动态效果」开着时才启用，因为它要解决的问题只在那种情况下发生；关着时自动退回单扇窗（老行为）
- 开了声音时，负责出声的那一份播放器不会跟着桌面暂停，否则每切一次桌面音频都要重新起播（听感是卡一下）。代价是你不在它那个桌面时多一路解码；静音时没有这个代价，「被窗口遮挡时暂停」也照样能压过它
- 「每个桌面叠几扇壁纸窗」默认 3（实测最优），窗口数变成 4 桌面 × 3 = 12 扇；实测 CPU 与内存增量都在噪声里 —— 衬窗只挂一张静止画面，不解码也不重绘。切桌面时的画面偏离：1 扇 10.6 → 3 扇 1.9
- 暂不支持图片、GIF 或按日出日落自动切换
- 发布包没有 Apple Developer 公证

## 文档

- [使用指南](docs/USAGE.zh-CN.md)
- [构建与贡献](CONTRIBUTING.zh-CN.md)
- [架构说明](docs/ARCHITECTURE.zh-CN.md)
- [桌面、显示器与遮挡](docs/SPACES_AND_DISPLAYS.zh-CN.md) —— 哪些系统信号能信，以及怎么调试
- [维护者笔记](docs/MAINTAINER_NOTES.zh-CN.md)
- [Mac App Store 上架准备](docs/APP_STORE.md)

## License

[GPL-3.0](LICENSE)
