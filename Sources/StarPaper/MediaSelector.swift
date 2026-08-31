import Foundation
import AppKit

/// 决定「此刻该播哪个视频」。
///
/// ## 一套东西，不是两套
///
/// `settings.videoPath` = **正在播的那个**，`settings.playlist` = **视频库**（可选的池子）。
/// 库不是另一条独立的播放通道 —— 它只是「可以一键切过去的那些视频」，
/// 当前播的那个就是库里的某一项（或者一个还没进库的临时视频）。
///
/// 第一版不是这么写的：库有自己的 `index`，`videoPath` 只当单视频的兜底。
/// 结果是内容页显示 A、桌面上在播 B，两个页面各说各话。现在只有一个事实源。
///
/// 优先级：日程 > 当前视频。库不参与「播谁」的判断，只参与「下一个是谁」。
final class MediaSelector {

    enum Period { case day, night }

    private let settings = AppSettings.shared
    private var intervalTimer: Timer?
    private var scheduleTimer: Timer?
    private var lastPeriod: Period?
    private var timerSignature: String = ""
    /// 随机模式的「这一轮还没播过的」。见 `shuffleNext`。
    private var shuffleBag: [String] = []

    /// 该换片了。参数是新的路径。
    var onChange: ((String) -> Void)?

    init() {
        lastPeriod = currentPeriod
        restartTimers(force: true)
    }

    deinit {
        intervalTimer?.invalidate()
        scheduleTimer?.invalidate()
    }

    // MARK: - 当前该播什么

    var isScheduleActive: Bool {
        settings.scheduleEnabled && (isUsable(dayPath) || isUsable(nightPath))
    }

    /// 有没有人会**自动**换片。手点切换不看这个开关 —— 库任何时候都能点。
    var isAutoAdvanceActive: Bool {
        !isScheduleActive && settings.playlistEnabled && validLibrary.count > 1
    }

    private var dayPath: String { settings.dayVideoPath }
    private var nightPath: String { settings.nightVideoPath }

    /// 过滤掉已经不存在的文件 —— 视频被删被移走时不该整个卡住
    private var validLibrary: [String] {
        settings.playlist.filter(isUsable)
    }

    private func isUsable(_ path: String) -> Bool {
        MediaAccess.isUsable(path: path)
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
        let primary = currentPeriod == .day ? dayPath : nightPath
        let fallback = currentPeriod == .day ? nightPath : dayPath
        return Self.choosePath(
            scheduleActive: isScheduleActive,
            schedulePrimary: primary, scheduleFallback: fallback,
            selected: settings.videoPath, library: settings.playlist,
            builtIn: BuiltInMedia.defaultVideoPath, isUsable: isUsable)
    }

    /// 视频是否应该无限循环。
    /// 只有「播完切下一个」不能循环 —— 循环了就永远等不到结束事件。
    var shouldLoop: Bool {
        guard isAutoAdvanceActive else { return true }
        return settings.playlistAdvance != .onEnd
    }

    // MARK: - 切换

    /// 切到库里的下一个。日程开着时它说了算，这里只重播当前。
    ///
    /// 注意它**不看** `playlistEnabled`：那个开关管的是「自动换不换」，
    /// 托盘菜单和快捷键的「下一个」任何时候都该能用。
    func advance() {
        guard !isScheduleActive else {
            onChange?(currentPath)     // 日程模式下「下一个」就是重播当前
            return
        }
        let list = validLibrary
        guard list.count > 1 else {
            onChange?(currentPath)     // 库里就一个（或没有）：没得切
            return
        }
        let current = currentPath
        let next: String
        if settings.playlistShuffle {
            next = Self.shuffleNext(after: current, in: list, bag: &shuffleBag)
        } else {
            next = list[Self.nextIndex(after: current, in: list)]
        }
        settings.videoPath = next
        settings.save()
        onChange?(next)
    }

    // MARK: - 下一个是谁（纯函数，自检覆盖这两个）

    /// 播放来源优先级：日程 > 用户当前视频 > 视频库第一个 > 内置 demo。
    /// 抽成纯函数是为了钉住最重要的反例：加了 demo 之后绝不能覆盖老用户已选的视频。
    static func choosePath(
        scheduleActive: Bool,
        schedulePrimary: String,
        scheduleFallback: String,
        selected: String,
        library: [String],
        builtIn: String,
        isUsable: (String) -> Bool
    ) -> String {
        if scheduleActive {
            if isUsable(schedulePrimary) { return schedulePrimary }
            if isUsable(scheduleFallback) { return scheduleFallback }
        }
        if isUsable(selected) { return selected }
        if let first = library.first(where: isUsable) { return first }
        if isUsable(builtIn) { return builtIn }
        return ""
    }

    /// 顺序模式：当前那个的下一个。
    /// 当前不在库里（刚从别处挑了个视频）就从头开始 —— 不是跳到第 2 个。
    static func nextIndex(after current: String, in list: [String]) -> Int {
        guard !list.isEmpty else { return 0 }
        guard let i = list.firstIndex(of: current) else { return 0 }
        return (i + 1) % list.count
    }

    /// 随机模式：一轮之内不重复。
    ///
    /// 每次独立随机看着简单，实际用起来会连着抽到同一个，像卡住了。
    /// 所以维护一个「这轮还没播的」袋子，抽空了再重洗；重洗时排掉当前这个，
    /// 免得新一轮的第一个就是刚播完的。
    static func shuffleNext(after current: String, in list: [String], bag: inout [String]) -> String {
        bag.removeAll { !list.contains($0) }        // 库改过了，袋里的旧货得清掉
        if bag.isEmpty {
            bag = list.filter { $0 != current }.shuffled()
            if bag.isEmpty { return current }       // 库里就它一个
        }
        return bag.removeLast()
    }

    // MARK: - 设置变化

    /// 设置改了（库内容 / 模式 / 时间点）之后调一次
    func settingsChanged() {
        restartTimers(force: false)
        let period = currentPeriod
        if period != lastPeriod {
            lastPeriod = period
            onChange?(currentPath)
        }
    }

    /// 定时器只在**它自己的参数**变了才重建。
    ///
    /// 以前是每次设置变化都重建一次，于是「每 30 分钟换一片」实际上
    /// 只要期间动过任何一个滑杆就重新计时 —— 调完色再也等不到换片。
    private func restartTimers(force: Bool) {
        let signature = [
            isAutoAdvanceActive ? "1" : "0",
            settings.playlistAdvance.rawValue,
            String(settings.playlistIntervalMinutes),
            isScheduleActive ? "1" : "0",
        ].joined(separator: "|")
        guard force || signature != timerSignature else { return }
        timerSignature = signature

        intervalTimer?.invalidate()
        intervalTimer = nil
        scheduleTimer?.invalidate()
        scheduleTimer = nil

        if isAutoAdvanceActive && settings.playlistAdvance == .interval {
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
