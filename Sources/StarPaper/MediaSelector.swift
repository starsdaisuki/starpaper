import Foundation
import AppKit

/// 决定「此刻该播哪个视频」。
///
/// 三个来源，优先级从高到低：日程 > 播放列表 > 单视频。
/// 把这个判断集中在一个地方，engine 只管播，不掺和选片。
final class MediaSelector {

    enum Period { case day, night }

    private let settings = AppSettings.shared
    private var index = 0
    private var order: [Int] = []
    private var intervalTimer: Timer?
    private var scheduleTimer: Timer?
    private var lastPeriod: Period?

    /// 该换片了。参数是新的路径。
    var onChange: ((String) -> Void)?

    init() {
        rebuildOrder()
        lastPeriod = currentPeriod
        restartTimers()
    }

    deinit {
        intervalTimer?.invalidate()
        scheduleTimer?.invalidate()
    }

    // MARK: - 当前该播什么

    var isScheduleActive: Bool {
        settings.scheduleEnabled && !(dayPath.isEmpty && nightPath.isEmpty)
    }

    var isPlaylistActive: Bool {
        !isScheduleActive && settings.playlistEnabled && !validPlaylist.isEmpty
    }

    private var dayPath: String { settings.dayVideoPath }
    private var nightPath: String { settings.nightVideoPath }

    /// 过滤掉已经不存在的文件 —— 视频被删被移走时不该整个卡住
    private var validPlaylist: [String] {
        settings.playlist.filter { FileManager.default.fileExists(atPath: $0) }
    }

    var currentPeriod: Period {
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let minutes = (now.hour ?? 0) * 60 + (now.minute ?? 0)
        let dayStart = settings.dayStartMinutes
        let nightStart = settings.nightStartMinutes

        if dayStart == nightStart { return .day }
        if dayStart < nightStart {
            return (minutes >= dayStart && minutes < nightStart) ? .day : .night
        }
        // 夜间开始时间早于白天开始时间 —— 白天跨午夜的情况
        return (minutes >= nightStart && minutes < dayStart) ? .night : .day
    }

    var currentPath: String {
        if isScheduleActive {
            let primary = currentPeriod == .day ? dayPath : nightPath
            let fallback = currentPeriod == .day ? nightPath : dayPath
            if !primary.isEmpty { return primary }
            if !fallback.isEmpty { return fallback }
        }
        if isPlaylistActive {
            let list = validPlaylist
            let effective = order.isEmpty ? Array(list.indices) : order
            let slot = effective.indices.contains(index) ? effective[index] : 0
            if list.indices.contains(slot) { return list[slot] }
            return list.first ?? settings.videoPath
        }
        return settings.videoPath
    }

    /// 播放列表模式下，视频是否应该无限循环。
    /// 「播完切下一个」时不能循环 —— 循环了就永远等不到结束事件。
    var shouldLoop: Bool {
        guard isPlaylistActive else { return true }
        return settings.playlistAdvance != .onEnd
    }

    // MARK: - 切换

    func advance() {
        guard isPlaylistActive else {
            onChange?(currentPath)     // 单视频 / 日程模式下「下一个」就是重播当前
            return
        }
        let count = validPlaylist.count
        guard count > 0 else { return }
        index += 1
        if index >= count {
            index = 0
            if settings.playlistShuffle { rebuildOrder() }   // 每轮结束重洗
        }
        onChange?(currentPath)
    }

    private func rebuildOrder() {
        let count = validPlaylist.count
        guard count > 0 else { order = []; return }
        order = Array(0..<count)
        if settings.playlistShuffle { order.shuffle() }
        if index >= count { index = 0 }
    }

    // MARK: - 设置变化

    /// 设置改了（列表内容 / 模式 / 时间点）之后调一次
    func settingsChanged() {
        rebuildOrder()
        restartTimers()
        let period = currentPeriod
        if period != lastPeriod {
            lastPeriod = period
            onChange?(currentPath)
        }
    }

    private func restartTimers() {
        intervalTimer?.invalidate()
        intervalTimer = nil
        scheduleTimer?.invalidate()
        scheduleTimer = nil

        if isPlaylistActive && settings.playlistAdvance == .interval {
            let seconds = max(60, settings.playlistIntervalMinutes * 60)
            intervalTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
                self?.advance()
            }
            intervalTimer?.tolerance = 10        // 允许系统合并唤醒，省电
        }

        if isScheduleActive {
            // 每 30 秒查一次时段。比精确到点调度简单得多，也不怕睡眠错过时刻。
            scheduleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                guard let self else { return }
                let period = self.currentPeriod
                guard period != self.lastPeriod else { return }
                self.lastPeriod = period
                self.onChange?(self.currentPath)
            }
            scheduleTimer?.tolerance = 5
        }
    }
}
