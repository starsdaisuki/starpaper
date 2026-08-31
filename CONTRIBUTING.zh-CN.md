# 构建与贡献

[English](CONTRIBUTING.md) · **简体中文**

StarPaper 使用 SwiftPM 编译，再由 Makefile 手工组装 macOS `.app` bundle；仓库不包含 Xcode 工程。

## 环境

- macOS 14 或更高版本
- Swift 6（Xcode 或 Command Line Tools）
- `make`

## 常用命令

```bash
make build      # release 编译
make bundle     # 编译并生成 build/StarPaper.app
make run        # 结束旧实例、重新打包并启动
make install    # 安装到 ~/Applications
make test       # 在隔离的 UserDefaults suite 中运行设置层自检
make link       # 把 CLI 链接到 ~/.local/bin
make dmg        # 生成 build/StarPaper.dmg
make icon       # 从 tools/make-icon.swift 重新生成应用图标
make kill       # 只结束正在运行的实例
make clean      # 删除 .build 与 build
```

`make run` 和 `make kill` 会结束当前运行的 StarPaper 实例。只想验证编译时使用 `make build` 或 `make bundle`。

本地自用可以直接打开 `build/StarPaper.app`，不需要 DMG。`make bundle` 和 `make dmg` 产出的是 ad-hoc 签名，自己机器上没问题，但到别人机器上会被 Gatekeeper 拦。正式发布的 DMG 由 `make release-signed` 产出，额外做 Developer ID 签名、Hardened Runtime、公证与 stapling，见[维护者笔记](docs/MAINTAINER_NOTES.zh-CN.md)。

## 代码结构

```text
Package.swift
Makefile
Resources/
├── Info.plist
└── AppIcon.icns
bin/
└── starpaper                  CLI 薄包装
tools/
└── make-icon.swift            纯 Core Graphics 图标生成器
Sources/StarPaper/
├── main.swift                 NSApplication 启动入口
├── AppDelegate.swift          菜单栏、主菜单与设置窗口
├── AppSettings.swift          UserDefaults 设置模型
├── Localization.swift         中英文字符串表
├── VideoInfo.swift            视频尺寸与裁剪预览帧
├── MediaSelector.swift        日程、播放列表、单视频选择
├── LoginItem.swift            SMAppService 开机自启
├── Hotkeys.swift              Carbon 全局快捷键
├── WallpaperWindow.swift      桌面层窗口
├── VideoWallpaperView.swift   播放、裁剪与滤镜图层
├── WallpaperEngine.swift      多屏播放单元与播放决策
├── PowerMonitor.swift         电源、锁屏与睡眠状态
├── SettingsView.swift         SwiftUI 设置界面
└── SelfTest.swift             隔离设置域自检
```

设计背景见 [架构说明](docs/ARCHITECTURE.zh-CN.md)。修改设置、播放、窗口或滤镜逻辑前，请阅读 [维护者笔记](docs/MAINTAINER_NOTES.zh-CN.md)。

## 提交前验证

至少运行：

```bash
make test
git diff --check
git status --short
```

涉及界面、桌面层级、多显示器、热插拔、睡眠唤醒、全局快捷键或开机自启的改动，还需要在真实 macOS 会话中手工验证。

## 隐私与发布卫生

公开提交只应包含源码、面向用户或贡献者的文档、合成测试数据和构建配置。不要提交：

- `.build/`、`build/`、dSYM、对象文件、module cache 或编译数据库
- 本机绝对路径、真实视频路径、设备标识或账户凭据
- `.env`、API key、token、私钥或配置导出
- 本地会话交接、个人背景、其他项目的内部事故记录
- 未检查元数据的截图、日志、DMG 或压缩包

发布前应检查当前 tree、可访问 Git 历史与 Release 资产，而不是只扫描最新源码。

## Release 检查

```bash
make clean
make test
make dmg
file build/StarPaper.app/Contents/MacOS/StarPaper
codesign -dvv build/StarPaper.app
shasum -a 256 build/StarPaper.dmg
```

随后挂载 DMG 检查实际文件清单，确认没有 dSYM、日志或其他构建产物，再上传 Release。
