import AppKit
import AVFoundation
import Combine

/// 单块屏幕的壁纸单元：一个窗口 + 一个 player
private final class ScreenUnit {
    let window: WallpaperWindow
    let view: VideoWallpaperView
    let player: AVQueuePlayer
    var looper: AVPlayerLooper?
    var isOccluded = false
    /// 这块屏是不是负责出声的那块（多屏时只让一块出声，否则回声）
    var isAudioScreen = false
    /// 也是「播完切下一个」的事件源 —— 只让一块屏报结束，不然多屏会连跳好几个
    var isPrimary = false

    init(screen: NSScreen, layerMode: IconLayerMode) {
        window = WallpaperWindow(screen: screen, layerMode: layerMode)
        view = VideoWallpaperView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.contentView = view

        player = AVQueuePlayer()
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = true
        view.playerLayer.player = player
    }

    /// - Parameter loop: false 时不套 looper，播完会发 AVPlayerItemDidPlayToEndTime
    func load(url: URL, loop: Bool) {
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()

        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        let item = AVPlayerItem(asset: asset)

        if loop {
            player.actionAtItemEnd = .advance
            looper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            player.actionAtItemEnd = .pause
            player.insert(item, after: nil)
        }

        // 裁剪几何需要视频原始尺寸，异步取回后回填
        Task { @MainActor [weak view] in
            guard let size = await VideoInfo.naturalSize(of: asset) else { return }
            view?.videoSize = size
        }
    }

    func teardown() {
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
        view.playerLayer.player = nil
        window.orderOut(nil)
        window.contentView = nil
    }
}

/// 壁纸引擎：管理每块屏幕的窗口 / 播放器，并根据设置 + 遮挡 + 电源状态决定播还是停。
final class WallpaperEngine {

    private var units: [ScreenUnit] = []
    private let settings = AppSettings.shared
    private let power = PowerMonitor()
    private let selector = MediaSelector()
    private var bag = Set<AnyCancellable>()
    private var currentPath: String = ""
    private var currentLoop: Bool = true

    /// 播放状态变了就回调（菜单栏用来更新文案）
    var onStateChange: (() -> Void)?

    private(set) var isPlaying = false

    init() {
        power.onChange = { [weak self] in self?.updatePlayback() }
        selector.onChange = { [weak self] _ in self?.reloadVideo(force: true) }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuildScreens()
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? WallpaperWindow else { return }
            self?.handleOcclusionChange(for: window)
        }

        // 「播完切下一个」模式：主屏那份播完就通知选片器
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, !self.currentLoop else { return }
            guard let item = note.object as? AVPlayerItem,
                  let primary = self.units.first(where: { $0.isPrimary }),
                  primary.player.items().contains(item)
            else { return }
            self.selector.advance()
        }

        // 睡醒后 AVPlayer 经常卡死在 buffer 里，直接重建一次最省事
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self?.reloadVideo(force: true)
            }
        }

        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.selector.settingsChanged()
                self?.applySettings()
            }
            .store(in: &bag)

        rebuildScreens()
    }

    // MARK: - 屏幕管理

    func rebuildScreens() {
        let mode = settings.iconLayer
        units.forEach { $0.teardown() }
        units = NSScreen.screens.map { ScreenUnit(screen: $0, layerMode: mode) }

        // 主屏（含菜单栏那块）负责出声，也当播完事件的唯一来源
        let mainFrame = NSScreen.main?.frame
        for unit in units {
            unit.isAudioScreen = (unit.window.frame == mainFrame)
        }
        if !units.contains(where: { $0.isAudioScreen }) {
            units.first?.isAudioScreen = true
        }
        units.forEach { $0.isPrimary = $0.isAudioScreen }

        for unit in units {
            unit.window.orderFrontRegardless()
        }

        currentPath = ""
        reloadVideo(force: true)
        applySettings()
    }

    // MARK: - 视频加载

    func reloadVideo(force: Bool = false) {
        let path = selector.currentPath
        let loop = selector.shouldLoop

        guard !path.isEmpty else {
            units.forEach { $0.player.pause() }
            isPlaying = false
            onStateChange?()
            return
        }
        guard force || path != currentPath || loop != currentLoop else { return }

        guard FileManager.default.fileExists(atPath: path) else {
            NSLog("[StarPaper] 视频文件不存在: %@", path)
            return
        }
        currentPath = path
        currentLoop = loop

        let url = URL(fileURLWithPath: path)
        units.forEach { $0.load(url: url, loop: loop) }
        updatePlayback()
        onStateChange?()
    }

    /// 手动跳下一个（菜单 / 快捷键）
    func next() {
        selector.advance()
    }

    var nowPlayingName: String {
        currentPath.isEmpty ? "" : (currentPath as NSString).lastPathComponent
    }

    // MARK: - 设置应用

    func applySettings() {
        for unit in units {
            unit.window.applyLayerMode(settings.iconLayer)
            unit.view.apply(settings)
            unit.player.defaultRate = Float(settings.playbackRate)
            let audible = unit.isAudioScreen && !settings.muted
            unit.player.isMuted = !audible
            unit.player.volume = Float(settings.volume)
        }
        reloadVideo()
        updatePlayback()
    }

    // MARK: - 遮挡

    private func handleOcclusionChange(for window: WallpaperWindow) {
        guard let unit = units.first(where: { $0.window === window }) else { return }
        unit.isOccluded = !window.occlusionState.contains(.visible)
        updatePlayback()
    }

    // MARK: - 播放决策

    /// 单一入口：所有「该不该播」的判断都汇总到这里，避免多处 play/pause 打架
    func updatePlayback() {
        let globalOK = power.shouldPlay(with: settings) && !settings.isPaused
        var anyPlaying = false

        for unit in units {
            let occludedStop = settings.pauseWhenOccluded && unit.isOccluded
            let shouldPlay = globalOK && !occludedStop && !currentPath.isEmpty

            if shouldPlay {
                if unit.player.timeControlStatus != .playing {
                    unit.player.play()
                    unit.player.rate = Float(settings.playbackRate)
                }
                anyPlaying = true
            } else {
                if unit.player.timeControlStatus != .paused {
                    unit.player.pause()
                }
            }
        }

        if anyPlaying != isPlaying {
            isPlaying = anyPlaying
            onStateChange?()
        }
    }

    var statusText: String {
        if currentPath.isEmpty { return T("status.noVideo") }
        if settings.isPaused { return T("status.manualPause") }
        if let reason = power.pauseReason(with: settings) {
            return String(format: T("status.pausedFmt"), reason)
        }
        if !isPlaying { return T("status.occluded") }
        return String(format: T("status.playingFmt"), units.count)
    }

    func togglePause() {
        settings.isPaused.toggle()
        updatePlayback()
    }
}
