import AppKit

/// 壁纸窗口落在哪些桌面上
enum SpacePlacement {
    /// 一扇窗跟着人跑（`.canJoinAllSpaces`）。
    /// 老行为，不需要任何私有 API —— 代价是切桌面时那 0.9 秒会露出系统静态壁纸，
    /// 原因见 `SpaceBridge` 的注释。
    case followsUser
    /// 只属于一个桌面（`.managed`），每个桌面各有一扇。切桌面时不露。
    case singleDesktop
}

/// 桌面壁纸窗口。
///
/// 关键就三件事：
///   1. window level 压到桌面层 —— 在「桌面图片之上、桌面图标之下」
///   2. collectionBehavior 决定它落在哪些桌面上、不参与 Cmd+Tab / Exposé
///   3. ignoresMouseEvents 让鼠标事件穿透过去，桌面照常双击右键
///
/// 窗口本身全部是公开 API，不需要辅助功能权限，也不需要关 SIP；
/// 只有「把 `.singleDesktop` 的窗放到指定桌面」那一步要私有 API（见 `SpaceBridge`）。
final class WallpaperWindow: NSWindow {

    let placement: SpacePlacement

    /// 往下压几层。0 = 主窗；>0 是垫在主窗下面的「衬窗」，见 `WallpaperEngine.ScreenUnit`。
    let levelOffset: Int

    init(screen: NSScreen, layerMode: IconLayerMode,
         placement: SpacePlacement = .followsUser, levelOffset: Int = 0) {
        self.placement = placement
        self.levelOffset = levelOffset
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        applyLayerMode(layerMode)

        // ⚠️ 这一行就是「切桌面露不露系统静态壁纸」的开关，别顺手改回单一写法。
        //
        // 两种模式的差别只有**第一组**（窗口落在哪些桌面上）：
        //   `.canJoinAllSpaces` = 一扇窗跟着人跑（会露 0.9 秒，见 SpaceBridge 注释）
        //   不写 = 默认「只属于创建它的那个桌面」，再用 CGS 搬到目标桌面
        //
        // ⭐ 第二组（Exposé 行为）两边都必须是 `.stationary`，**不能写 `.managed`**：
        //    `.managed / .transient / .stationary` 是互斥的三选一，同时写
        //    `[.managed, .stationary]` 会让 `.managed` 赢 —— 于是壁纸窗被当成普通窗口
        //    参与 Exposé，**Mission Control 里每个桌面都会多冒出几张壁纸缩略图**
        //    （2026-08-23 实测：叠了几层就冒几张）。
        //    `.stationary` = 「不受 Exposé 影响，像桌面窗口一样待着」，正是我们要的。
        //
        // 实测（2026-08-23，Reduce Motion 开着）：去掉 `.managed` 之后
        //   · CGSCopySpacesForWindows 回读：四扇窗仍各属一个桌面 [643][136][644][919]
        //     —— 没有变成 sticky，每桌面一扇的修复没丢；
        //   · Mission Control 显示 "No Available Windows"，桌面背景上视频照常在播。
        switch placement {
        case .followsUser:
            collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        case .singleDesktop:
            collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        }
        ignoresMouseEvents = true
        // ⚠️ **建出来时是隐形的**，由 `WallpaperEngine.revealWindows()` 统一放出来。
        //
        // 每桌面一扇窗的做法是「先在当前桌面把窗建好、orderFront 拿到 windowNumber，
        // 再搬去各自的目标桌面」—— 搬走之前，所有桌面的壁纸窗**全叠在用户眼前**。
        // 之前它们是可见的，于是每次启动/重建都会闪一下：桌面数有几个就有几层画面
        // 叠在一起，各画各的时钟（2026-08-31 用户报告「看到两个时钟」就是这个），
        // 而且新建的窗还没解出第一帧时是黑的，叠上去就是「先暗后亮」。
        alphaValue = 0
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isMovable = false
        isRestorable = false
        isReleasedWhenClosed = false
        canHide = false                       // Cmd+H 不该把壁纸藏掉
        displaysWhenScreenProfileChanges = true
        animationBehavior = .none
        setFrame(screen.frame, display: true)
    }

    /// 切换「图标在上 / 壁纸在上」。
    ///
    /// Finder 的桌面图标画在 kCGDesktopIconWindowLevel 这一层，
    /// 所以 -1 就在图标下面（图标可见），+1 就盖住图标。
    func applyLayerMode(_ mode: IconLayerMode) {
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        switch mode {
        case .belowIcons:
            level = NSWindow.Level(rawValue: iconLevel - 1 - levelOffset)
        case .aboveIcons:
            level = NSWindow.Level(rawValue: iconLevel + 1 - levelOffset)
        }
    }

    // 壁纸永远不该抢焦点
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}
