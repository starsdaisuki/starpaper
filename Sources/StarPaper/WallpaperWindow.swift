import AppKit

/// 桌面壁纸窗口。
///
/// 关键就三件事：
///   1. window level 压到桌面层 —— 在「桌面图片之上、桌面图标之下」
///   2. collectionBehavior 让它跟着所有 Space 走、不参与 Cmd+Tab / Exposé
///   3. ignoresMouseEvents 让鼠标事件穿透过去，桌面照常双击右键
///
/// 全部是公开 API，不需要辅助功能权限，也不需要关 SIP。
final class WallpaperWindow: NSWindow {

    init(screen: NSScreen, layerMode: IconLayerMode) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        applyLayerMode(layerMode)

        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
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
            level = NSWindow.Level(rawValue: iconLevel - 1)
        case .aboveIcons:
            level = NSWindow.Level(rawValue: iconLevel + 1)
        }
    }

    // 壁纸永远不该抢焦点
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}
