import Foundation
import CoreMedia

/// 重建窗口之后，要不要把播放进度接回原处 —— 纯函数，能离线自检。
///
/// ## 为什么要有这个
///
/// `rebuildScreens()` 会 `teardown()` 掉所有 `ScreenUnit`，播放进度跟着 `AVQueuePlayer`
/// 一起消失，末尾的 `reloadVideo(force: true)` 又是从 0 开始。而走到重建的路径全是日常操作：
///
/// - 新建 / 关闭一个桌面（Space）
/// - 把 App Store 这类窗口切进 / 切出**全屏** —— 全屏会建一个新 Space，退出时又销毁，
///   所以一进一出会重建**两次**
/// - 改系统「减弱动态效果」开关（`.auto` 档的判据）
/// - `scheduleReconcile()` 那个 20 秒轮询发现桌面数对不上
///
/// 表现就是「壁纸和 BGM 每隔一会儿自己从头开始」，而且只在**每桌面一扇**模式下出现
/// （`reconcileDesktops()` 开头就 `guard currentPlacement == .singleDesktop`）——
/// 也就是只在 Reduce Motion 开着时撞得到，这是它显得时有时无的原因。
///
/// ## 为什么抽成纯函数
///
/// `rebuildScreens()` 要真窗口、真 `AVPlayer`，跑不进离线自检。把判据摘出来才能用反例盖住
/// ——尤其是「重建期间正好轮播换了片」那条：不比对路径就会把新片 seek 到旧片的时间点。
enum PlaybackResume {

    /// 比这更靠前就别接了：跟从头几乎没差别，而 seek 是要钱的
    /// （4K60 得从最近的关键帧重解上百帧，见 `WallpaperEngine.noteSeekCost` 的实测）。
    static let minSeconds = 0.25

    /// - Parameters:
    ///   - previousPath: 重建**之前**正在播的视频路径；空串 = 当时就没在播
    ///   - currentPath: 重建**之后** `reloadVideo` 实际装上的路径
    ///   - time: 重建之前的播放位置
    static func shouldRestore(previousPath: String, currentPath: String, time: CMTime?) -> Bool {
        guard !previousPath.isEmpty,
              // ⚠️ 必须比对：重建期间轮播可能已经换片，那本来就该从头
              previousPath == currentPath,
              let t = time,
              // 直播流 / 还没 ready 的 item 会给出 indefinite 或 invalid
              t.isValid, t.isNumeric,
              t.seconds > minSeconds
        else { return false }
        return true
    }
}
