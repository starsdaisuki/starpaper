import AppKit
import CoreGraphics

/// 「前台 app 是不是正盖着整块屏」——**只作为兜底**。
///
/// ⚠️ 首选判据是 `SpaceBridge.currentSpaceIsDesktop()`。这里只在私有 API 被裁掉
/// （Mac App Store 构建）时才会被问到。
///
/// ## 为什么不能再用「窗口尺寸 == 屏幕尺寸」
///
/// 2026-08-30 实测，同一台机器屏幕 1512×982：
///
/// | 全屏 app | 主窗 bounds | 尺寸相等判据 |
/// |---|---|---|
/// | Finder | 1512×945 @0,37 | ❌ 认不出 |
/// | Ghostty | 1512×907 @0,75 | ❌ 认不出 |
/// | Google Chrome | 1512×857 @0,125 | ❌ 认不出 |
///
/// 带标题栏 / 标签栏的 app 会把那部分拆成独立的 layer-0 窗口，主窗只剩下面那块。
/// 旧实现要求 ±2pt 内相等，于是**对所有真实 app 都返回「不是全屏」**，
/// 音频门每次都走短兜底放行。旧自检里那条「1512×907 不算全屏」是绿的，
/// 而 1512×907 恰恰就是真实全屏窗的尺寸 —— 测试把 bug 断言成了正确行为。
///
/// 现在改成「宽度铺满 + 高度占屏 80% 以上」，并且允许把同一个 app 的多扇窗一起看。
enum ForegroundCoverage {

    /// 前台 app 有没有一扇窗盖住整块屏。`CGWindowListCopyWindowInfo` 是公开 API；
    /// 只读 owner PID / layer / bounds，不截图，也不读窗口标题。
    static func frontmostCoversScreen() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            // 前台是谁都问不出来时保守当作「盖着」——宁可晚出声，不要乱出声
            return true
        }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return true }
        let displays = NSScreen.screens.map(\.frame)

        for row in rows {
            guard (row[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let dict = row[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict)
            else { continue }
            if displays.contains(where: { covers(window: bounds.size, display: $0.size) }) {
                return true
            }
        }
        return false
    }

    /// 只比宽度是否铺满 + 高度是否占到屏幕的绝大部分。
    ///
    /// 故意不比 origin：Space 交互动画中全屏窗会横向滑出屏幕，但它仍是那扇全屏窗，
    /// 正是需要继续压住 BGM 的时候。
    ///
    /// 高度阈值取 0.8：实测最"矮"的全屏主窗是 Chrome 的 857/982 ≈ 0.873。
    /// 普通最大化窗同样会命中，但这不构成误判 —— 有窗盖满整屏时壁纸本来就不可见，
    /// 根本走不到问这个函数的路径上。
    static func covers(window: CGSize, display: CGSize,
                       widthTolerance: CGFloat = 2, minHeightRatio: CGFloat = 0.8) -> Bool {
        guard display.width > 0, display.height > 0 else { return false }
        return abs(window.width - display.width) <= widthTolerance
            && window.height >= display.height * minHeightRatio
    }
}
