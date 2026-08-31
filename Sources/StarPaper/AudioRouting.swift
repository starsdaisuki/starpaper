import Foundation

/// 「哪一扇壁纸窗该出声」的纯决策。
///
/// 抽成独立函数是为了能离线自检 —— 真的切一次 Space 没办法在自检里复现，
/// 但规则本身可以逐条钉住（见 `SelfTest.audioRoutingSelfTest`）。
///
/// ## 规则（按顺序取第一个命中的）
///
/// 1. `designateAudioAndPrimary()` 选中、而且此刻在播的那一扇
/// 2. 在播的里面挑主屏那一扇（多屏时别让声音留在副屏）
/// 3. 在播的第一扇
/// 4. 被选中的那一扇（哪怕它还没起播）
/// 5. 主屏那一扇 → 再不行就第一扇
///
/// 为什么 2、3 要兜：切桌面时 `activeSpaceDidChange` 比画面**晚约 0.9 秒**
/// （见 `WallpaperEngine.updatePlayback` 里的实测），这 0.9 秒里被选中的还是旧桌面那一扇，
/// 而它可能已经因为遮挡停了。不兜的话这段时间就是一段静音空档。
///
/// ⚠️ 为什么 4、5 也要兜（**这条是踩出来的**）：冷启动时 `updatePlayback()` 里
/// 刚 `play()` 完，`timeControlStatus` 还是 `.paused`（item 尚未 ready），
/// 于是「一扇在播的都没有」。只认在播的话这一轮就全静音，而之后没有任何事件会再触发
/// 一次 `updatePlayback()` —— 表现是**整个 app 从头到尾一点声音都没有**。
/// 给暂停的窗解除静音本身完全无害（它没在播，出不了声），所以宁可给早了。
enum AudioRouting {

    /// - Parameters:
    ///   - designated: 每扇窗是不是 `isAudioScreen`
    ///   - live: 每扇窗此刻是不是在播
    ///   - onMainScreen: 每扇窗是不是挂在主屏上
    /// - Returns: 该出声的下标；一扇窗都没有时返回 nil
    static func speakerIndex(designated: [Bool], live: [Bool], onMainScreen: [Bool]) -> Int? {
        let n = min(designated.count, min(live.count, onMainScreen.count))
        guard n > 0 else { return nil }

        if let i = (0..<n).first(where: { designated[$0] && live[$0] }) { return i }
        if let i = (0..<n).first(where: { live[$0] && onMainScreen[$0] }) { return i }
        if let i = (0..<n).first(where: { live[$0] }) { return i }
        if let i = (0..<n).first(where: { designated[$0] }) { return i }
        if let i = (0..<n).first(where: { onMainScreen[$0] }) { return i }
        return 0
    }
}

/// 「壁纸重新露脸之后，什么时候才真的出声」——纯状态机，能回放事件序列。
///
/// ## 现象
///
/// 在全屏 app 里横划切 Space，BGM 会响。**拖到一半悬停不动，它会一直响到松手。**
///
/// ## 为什么画面的判据不能直接给音频用
///
/// 画面用 `occlusionState`。Space 转换一**开始**，系统就把参与转换的壁纸窗标成
/// 「不再被遮挡」（公开 API，比 `activeSpaceDidChange` 早约 0.9 秒）。画面**需要**
/// 这个提前量，否则切过去要卡 0.1~0.25 秒才恢复。但音频跟着它走，就是在本该静音的
/// 场景里每划一下出一声。**画面提前恢复，音频等落定** —— 两者必须是两条判据。
///
/// ## 三次失败的兜底（不要再走回去）
///
/// | 版本 | 兜底 | 为什么失败 |
/// |---|---|---|
/// | 0.7 秒定时门 | 露出后 0.7s 放行 | 转换动画本身就能持续 0.9~1.4 秒 |
/// | 2 秒盲超时 | 露出后 2s 放行 | 真机实测转换 2.22 秒，仍漏 0.20 秒 |
/// | 量前台窗尺寸 | 窗口尺寸 == 屏幕尺寸才算全屏 | **真实全屏窗根本不等于屏幕尺寸** |
///
/// ⭐ 最后一条是 2026-08-30 实测钉死的：同一台机器上屏幕 1512×982，而
/// Finder 全屏窗 1512×945、Ghostty 1512×907、Chrome 1512×857 —— 带标题栏 / 标签栏的
/// app 会把那部分拆成独立窗口，主窗只剩下面那块。**没有一个能被认成全屏。**
/// 于是每次都走「同 Space 关窗」的短兜底，到点无条件放行，门再也关不上。
///
/// 而且交互式手势可以悬停**任意久**，所以**任何固定时长的兜底都必然被跨过去**，
/// 区别只是「立刻响一下」还是「晚一点响一下」。
///
/// ## 现在的判据
///
/// 直接问系统：**当前激活的 Space 是不是普通桌面**（`SpaceBridge.currentSpaceIsDesktop()`）。
/// 全屏 app 的 Space 是 `type == 4`，普通桌面是 `type == 0`；两个全屏 Space 之间
/// 无论怎么拖、悬停多久，当前 Space 都不会变成普通桌面。没有时间常数，没有尺寸测量，
/// 也不需要监听全局输入事件。
enum AudioResumeGate {
    /// 真正落到桌面之后仍留一点稳定期，避开转换动画收尾那一批遮挡变化（实测约 0.34 秒）。
    /// ⚠️ 它**不是**兜底放行的超时 —— 不在桌面时根本不会走到这个计时。
    static let settleDelay: TimeInterval = 0.5

    /// 一次采样。状态机自己不去问系统，全部由调用方喂进来，这样能离线回放。
    struct Sample {
        /// 有没有任何一扇壁纸窗此刻被判为可见（occlusion，**带提前量**）
        var isVisible: Bool
        /// 「被窗口遮挡时暂停」开关。关掉 = 用户明确要求一直响，不装门。
        var enabled: Bool
        /// 当前 Space 是不是普通桌面。**nil = 判不出**（MAS 构建裁掉了私有 API），
        /// 此时退到 `frontmostCoversScreen` 兜底，不要把 nil 当成 false。
        var currentSpaceIsDesktop: Bool?
        /// 兜底判据：前台 app 的窗口并集是否覆盖整块屏。
        /// 只在 `currentSpaceIsDesktop == nil` 时才会被看。
        var frontmostCoversScreen: Bool = false
        var now: TimeInterval
    }

    struct State {
        /// 「人看起来真的落在桌面上」是从什么时候开始的。
        /// `nil` = 此刻不算在桌面上 → 一律静音，**没有任何超时能放行**。
        /// 初值 0 = 冷启动当作已经稳定，避免刚起来就哑一段。
        private(set) var steadySince: TimeInterval? = 0
        private(set) var lastVisible = true
        private(set) var lastOnDesktop = true

        /// 门此刻是不是压着（true = 静音）
        func shouldSilence(now: TimeInterval) -> Bool {
            guard let steadySince else { return true }
            return now < steadySince + AudioResumeGate.settleDelay
        }

        /// 还需要在哪个时刻主动重判一次；nil = 不需要定时器，等系统事件即可。
        ///
        /// ⚠️ 这个时刻到了**不能直接放行**，必须重新采样一轮再决定 ——
        /// 旧实现就是在这里无条件 `applyAudioRouting()`，等于把「等落定」变成了盲超时。
        var nextRecheck: TimeInterval? {
            guard let steadySince else { return nil }
            let deadline = steadySince + AudioResumeGate.settleDelay
            return deadline
        }

        mutating func observe(_ s: Sample) {
            lastVisible = s.isVisible

            // 用户把「遮挡暂停」关了 = 明确要求一直有声，这里不许自作主张
            guard s.enabled else {
                lastOnDesktop = true
                steadySince = 0
                return
            }

            // 壁纸此刻看不见 —— 本来就不该出声，同时把门复位成「等下一次露出」
            guard s.isVisible else {
                lastOnDesktop = false
                steadySince = nil
                return
            }

            let onDesktop: Bool
            if let known = s.currentSpaceIsDesktop {
                onDesktop = known
            } else {
                // 判不出当前 Space 时保守：前台窗盖满整屏就当作还在全屏 / 转换里
                onDesktop = !s.frontmostCoversScreen
            }
            lastOnDesktop = onDesktop

            if onDesktop {
                // 刚落到桌面才开始计稳定期；已经在计的不要重置，否则永远到不了期
                if steadySince == nil { steadySince = s.now }
            } else {
                // ⭐ 关键：门能**重新关上**。旧实现开门后 pendingSince 不清，
                //    `shouldSilence` 永远返回 false —— 于是「响一下」变成「一直响」。
                steadySince = nil
            }
        }

        /// Space 转换已经落定，且调用方重新采过一轮。
        /// 落在桌面上就不必再等稳定期（那 0.5 秒是给转换收尾的，落定通知本身已经等过）。
        mutating func noteSettled(_ s: Sample) {
            observe(s)
            if steadySince != nil { steadySince = s.now - AudioResumeGate.settleDelay }
        }
    }
}
