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

需要 macOS 14 或更高版本，Apple silicon。

1. 打开 [**Releases**](https://github.com/starsdaisuki/starpaper/releases)，下载
   **`StarPaper.dmg`** —— 这个才是 app。
   （下面的 "Source code (zip)" 和 "(tar.gz)" 不用管，那是 GitHub 自动加的源码包。）
2. 双击下载好的 DMG，把里面的 **StarPaper** 拖到旁边的 **Applications** 文件夹上。
3. 打开「应用程序」，双击 **StarPaper**。它会立刻开始播放内置示例视频，
   同时弹出设置窗口，你可以在那里换成自己的视频。

就这样。DMG 已用 Developer ID 证书签名、经 Apple 公证并钉了票据，所以
**不需要右键打开、不需要去「系统设置」点「仍要打开」、也不需要敲任何终端命令。**

StarPaper 住在菜单栏，随时点它的图标就能重新打开设置。

> **从 Mac App Store 版切过来？** 两个版本可以共存，但**设置不互通**。
> App Store 版是沙盒 app，偏好设置存在它自己的容器里，所以装了这个版本之后要重新选一次视频。
> 反过来，在已经装了这个版本的 Mac 上装 App Store 版，系统会把这个版本的偏好设置**搬进**那个容器。

<details>
<summary>想自己验一下签名（可选）</summary>

```bash
spctl -a -vv /Applications/StarPaper.app
#   accepted
#   source=Notarized Developer ID
```

</details>

也可以[从源码构建](CONTRIBUTING.zh-CN.md)。本地构建走 ad-hoc 签名，自己用没问题，但不适合再分发给别人。

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

## 文档

- [使用指南](docs/USAGE.zh-CN.md)
- [构建与贡献](CONTRIBUTING.zh-CN.md)
- [架构说明](docs/ARCHITECTURE.zh-CN.md)
- [桌面、显示器与遮挡](docs/SPACES_AND_DISPLAYS.zh-CN.md) —— 哪些系统信号能信，以及怎么调试
- [维护者笔记](docs/MAINTAINER_NOTES.zh-CN.md)
- [Mac App Store 上架准备](docs/APP_STORE.md)

## 致谢

由 [starsdaisuki](https://github.com/starsdaisuki) 与 [Claude](https://claude.com/claude-code)（Anthropic）共同编写 —— 设计、实现和绝大部分调试都是两个人一起做的。

## License

[GPL-3.0](LICENSE)
