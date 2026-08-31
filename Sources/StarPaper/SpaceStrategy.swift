import Foundation

/// 这一轮到底用哪种放置方式、每桌面叠几扇窗 —— 纯函数，能离线自检。
///
/// 抽出来是因为这里有三个来源要合流（用户三档开关 / 系统 Reduce Motion / 私有 API 在不在），
/// 而且 2026-08-23 已经被踩过一次：判断散在 `desiredPlacement` 和 `desiredBackingLayers`
/// 两个 computed property 里，各自看一半条件，很容易出现「放置退回老模式了，
/// 衬窗还按每桌面 3 扇建」这种半吊子状态。
enum SpaceStrategy {

    /// - Parameters:
    ///   - mode: 用户那三档
    ///   - reduceMotion: 系统「辅助功能 → 显示 → 减弱动态效果」此刻开着没有
    ///   - bridgeAvailable: SkyLight 那几个私有符号还在不在
    ///   - requestedLayers: 用户设的叠窗层数
    ///   - maxLayers: 上限
    static func resolve(mode: PerSpaceMode, reduceMotion: Bool, bridgeAvailable: Bool,
                        requestedLayers: Int, maxLayers: Int) -> (placement: SpacePlacement, layers: Int) {
        let wanted = (mode == .on) || (mode == .auto && reduceMotion)
        // 私有 API 没了就只能退回老行为 —— 宁可露那 0.9 秒，也不能一扇壁纸都没有
        let placement: SpacePlacement = (wanted && bridgeAvailable) ? .singleDesktop : .followsUser

        // ⚠️ 衬窗只在「每桌面一扇」下有意义：单扇 sticky 窗在 Space 转换里整扇被换成
        // 静态壁纸快照（实测 ㉕-2），垫在它下面的窗是 sticky 的，同样被换掉，垫了等于没垫。
        // 所以老模式下强制 1 扇，别白占内存、也别在 Mission Control 里多冒几张。
        let layers = placement == .singleDesktop
            ? min(maxLayers, max(1, requestedLayers))
            : 1
        return (placement, layers)
    }

    /// `applySettings()` 会不会因为「这一轮实际建成的样子」≠「现在想要的样子」再触发一次重建。
    ///
    /// 抽成纯函数是为了让**回退路径**能被自检覆盖。2026-08-27 的 bug 就在这儿：
    /// 私有 API 那条路走不通时，回退分支只把 placement 改回 `.followsUser`，
    /// `currentBackingLayers` 留在 3，于是这里判定要重建 → `rebuildScreens()` 又清掉
    /// 回退标记、再试一次私有 API、再失败、再回退……两个函数互相调用直到爆栈。
    /// 结论：**placement 和 layers 必须成对写回**，谁都不能单独改。
    static func needsRebuild(desired: (placement: SpacePlacement, layers: Int),
                             current: (placement: SpacePlacement, layers: Int)) -> Bool {
        desired.placement != current.placement || desired.layers != current.layers
    }

    /// 这扇窗此刻算不算「人看得见」——纯函数，能离线自检。
    ///
    /// ## 为什么必须分模式
    ///
    /// 2026-08-29 的现象：**把「每桌面一扇壁纸窗」设成「一直关」之后，
    /// 「被窗口遮挡时暂停」100% 失效。**
    ///
    /// 旧写法是一个公式吃两种模式：`isOnActiveSpace || !isOccluded`。
    /// 那个并集是**专门为每桌面窗口模式的 Space 转换**加的提前量 ——
    /// `activeSpaceDidChange` 比画面晚约 0.93 秒，只等它的话切过去要先卡一下。
    ///
    /// 但 `.followsUser` 模式下窗是 sticky 的、压根不参与 Space 转换，
    /// 而 `refreshActiveSpaces()` 会把它的 `isOnActiveSpace` **硬设成 true**
    /// （语义上没错：单扇窗永远跟着人跑，当然在当前桌面）。
    /// 两件事撞在一起，这个并集就恒为 true →`anyDesktopVisible` 恒 true →
    /// 出声那一份的 `occludedStop` 恒 false → 遮挡暂停整个失效。
    ///
    /// ⚠️ 教训和 `AudioResumeGate` 那条是同一个：**判据被复用了，语义没有被复用。**
    /// 一个字段在两种模式下含义不同时，下游不能共用一个公式。
    /// 单扇 sticky 壁纸窗「到底看不看得见」的二次确认。
    ///
    /// ## 为什么 `occlusionState` 对这扇窗不可信
    ///
    /// 2026-08-31 实测（`perSpaceMode=auto` + Reduce Motion 关 → `.followsUser`）：
    /// 在两个**相邻的普通桌面**之间按一次 `⌃→`，
    ///
    /// ```
    /// 00:03:55.271  遮挡=Y 停      ← 切换瞬间被标成不可见
    /// 00:04:11.599  遮挡=N 播      ← 16.3 秒后才翻回来，还是被下一次 Space 切换带回来的
    /// ```
    ///
    /// 原因是 sticky 窗在 Space 转换里整扇被换成系统静态壁纸快照（见 `SpaceBridge` 注释），
    /// 真窗没有被合成 → 系统如实报告「不可见」。但**用户明明正看着壁纸**。
    /// 表现就是切一次桌面 BGM 断一下。
    ///
    /// ⚠️ 这不是抖动，**去抖救不了**：阈值得设到 16 秒以上，那等于把遮挡暂停关掉。
    /// `.singleDesktop` 模式没这个问题 —— 每个桌面有自己的真实窗，不走快照替换，
    /// 所以「一直开」档位下用户听不到断音。
    ///
    /// ## 换的判据
    ///
    /// 只在系统说「不可见」时才二次确认，正常播放路径零开销：
    ///
    /// | 当前 Space 是普通桌面 | 前台有窗盖满屏 | 结论 |
    /// |---|---|---|
    /// | 否 | — | 真的看不见（人在全屏 app 的 Space 里） |
    /// | 是 | 是 | 真的看不见（被全屏 / 铺满的窗盖住） |
    /// | 是 | 否 | **假遮挡**，判为看得见 |
    /// | 判不出（nil） | — | 退回系统原值，保持旧行为 |
    ///
    /// - Parameters:
    ///   - rawOccluded: `window.occlusionState` 的原始判断
    ///   - currentSpaceIsDesktop: `SpaceBridge.currentSpaceIsDesktop()`；nil = 私有 API 不可用
    ///   - frontmostCoversScreen: 只在需要二次确认时才求值
    static func stickyOccluded(rawOccluded: Bool,
                               currentSpaceIsDesktop: Bool?,
                               frontmostCoversScreen: @autoclosure () -> Bool) -> Bool {
        guard rawOccluded else { return false }
        guard let onDesktop = currentSpaceIsDesktop else { return true }
        guard onDesktop else { return true }
        return frontmostCoversScreen()
    }

    static func isSeen(placement: SpacePlacement,
                       isOnActiveSpace: Bool, isOccluded: Bool) -> Bool {
        switch placement {
        case .followsUser:
            // sticky 窗的 isOnActiveSpace 恒 true，带上它这里就永远是 true。
            // 单扇窗「看不看得见」本来也只由遮挡决定。
            return !isOccluded
        case .singleDesktop:
            return isOnActiveSpace || !isOccluded
        }
    }
}
