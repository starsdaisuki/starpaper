import Foundation

/// 播放决策真正需要的一扇窗状态。这里故意不带 `NSWindow` / `AVPlayer`，
/// 让所有模式组合都能在自检里穷举，不再靠人反复切 Space 才撞出布尔逻辑错误。
struct PlaybackUnitState {
    let screenID: String
    let isOnActiveSpace: Bool
    let isOccluded: Bool
    let isAudioScreen: Bool
    let visibleSince: TimeInterval?
}

struct PlaybackDecision {
    /// 未经过并发限流的整体可见性。音频遮挡语义看的是「有没有任何壁纸真正露出来」。
    let anyDesktopVisible: Bool
    /// 经过并发限流后，本轮哪些窗值得解码画面。
    let visual: [Bool]
    /// 回写给下一轮的可见起始时间。
    let visibleSince: [TimeInterval?]
    let play: [Bool]
    let clockActive: [Bool]
    let playerLimit: Int
}

/// 只负责「采集完状态以后应该怎么做」，不读系统、不碰播放器。
enum PlaybackPolicy {
    /// 单屏时保留现有实测上限：当前窗 + 最多两扇转换中的窗。
    static let transitionAllowance = 2

    static func decide(
        units: [PlaybackUnitState],
        placement: SpacePlacement,
        pauseWhenOccluded: Bool,
        muted: Bool,
        globalOK: Bool,
        hasMedia: Bool,
        neverPause: Bool,
        now: TimeInterval,
        basePlayerLimit: Int
    ) -> PlaybackDecision {
        var visual = units.map {
            SpaceStrategy.isSeen(placement: placement,
                                 isOnActiveSpace: $0.isOnActiveSpace,
                                 isOccluded: $0.isOccluded)
        }
        let anyDesktopVisible = visual.contains(true)

        let since = units.indices.map { i -> TimeInterval? in
            if visual[i] { return units[i].visibleSince ?? now }
            return nil
        }

        // 原来的全局固定上限 3 只在单屏成立。四块屏本来就有四扇同时可见的壁纸，
        // 固定截到 3 会随机冻住其中一屏；Space 转换时还要在每块常驻可见屏之外，
        // 给最近经过的两扇窗留提前解码余量。
        let screenCount = Set(units.map(\.screenID)).count
        let playerLimit = max(basePlayerLimit, screenCount + transitionAllowance)
        var live = units.indices.filter { visual[$0] }
        if live.count > playerLimit {
            live.sort { a, b in
                if units[a].isOnActiveSpace != units[b].isOnActiveSpace {
                    return units[a].isOnActiveSpace
                }
                let ta = since[a] ?? 0
                let tb = since[b] ?? 0
                if ta != tb { return ta > tb }
                return a < b
            }
            let keep = Set(live.prefix(playerLimit))
            for i in units.indices where visual[i] && !keep.contains(i) {
                visual[i] = false
            }
        }

        let play = units.indices.map { i in
            let unit = units[i]
            let occludedStop = pauseWhenOccluded
                && (unit.isAudioScreen ? !anyDesktopVisible : unit.isOccluded)
            let keepsAudioAlive = unit.isAudioScreen && !muted
            return globalOK && hasMedia && !occludedStop
                && (neverPause || visual[i] || keepsAudioAlive)
        }
        let clockActive = units.indices.map { play[$0] && visual[$0] }

        // 被并发上限裁掉的窗仍然在系统层面「看得见」，保留 since 才能让下一轮排序稳定；
        // 真正被系统判成不可见的窗才在上面清零。
        return PlaybackDecision(anyDesktopVisible: anyDesktopVisible,
                                visual: visual, visibleSince: since,
                                play: play, clockActive: clockActive,
                                playerLimit: playerLimit)
    }
}
