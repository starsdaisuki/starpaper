import AppKit
import AVFoundation
import Combine

/// 一扇壁纸窗的完整单元：窗口 + 视图 + player。
///
/// 粒度是「一块屏 × 一个桌面」。单窗模式（`spaceID == nil`）下退化成「一块屏一个」，
/// 和以前完全一样。
private final class ScreenUnit {
    let window: WallpaperWindow
    /// 垫在主窗下面的衬窗，从上到下排列，不含主窗。
    ///
    /// 它们不播放、不解码，只是几扇不透明的黑窗 —— 存在的唯一意义是：
    /// 切桌面那 0.4 秒主窗被系统压暗时，透出来的是它们而不是系统静态壁纸。
    /// 详见 `AppSettings.backingLayers`。
    let backing: [WallpaperWindow]
    /// 衬窗的内容视图，和 `backing` 一一对应
    let backingViews: [BackingWallpaperView]
    /// 主窗 + 衬窗，需要一起搬桌面 / 一起改层级的场合用这个
    var allWindows: [WallpaperWindow] { [window] + backing }
    let view: VideoWallpaperView
    let player: AVQueuePlayer
    var looper: AVPlayerLooper?
    var isOccluded = false
    /// 从正在播的那份里取当前帧，喂给衬窗用。
    ///
    /// `AVPlayerLooper` 每循环一次就换一个 item，所以每次都要确认 output 还挂在
    /// 当前 item 上 —— 挂错了会一直取不到帧，而且不报错。
    private let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
    ])
    private weak var outputAttachedTo: AVPlayerItem?
    private var loadGeneration: UInt64 = 0

    func copyCurrentPixelBuffer() -> CVPixelBuffer? {
        guard let item = player.currentItem else { return nil }
        if outputAttachedTo !== item {
            outputAttachedTo?.remove(videoOutput)
            item.add(videoOutput)
            outputAttachedTo = item
            return nil                       // 刚挂上，这一轮还没帧
        }
        let t = item.currentTime()
        guard videoOutput.hasNewPixelBuffer(forItemTime: t) else { return nil }
        return videoOutput.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil)
    }

    /// 这块屏是不是负责出声的那块（多屏时只让一块出声，否则回声）
    var isAudioScreen = false
    /// 也是「播完切下一个」的事件源 —— 只让一份报结束，不然会连跳好几个
    var isPrimary = false

    /// 归属屏幕，多屏时用来把「当前桌面」对到正确的屏
    let screenUUID: String?
    /// 纯决策层用的非空屏幕身份。UUID 极端情况下取不到时，退到 CGDirectDisplayID；
    /// 否则每桌面的窗都会被误当成一块新屏，并发上限等于失效。
    let screenKey: String
    /// 归属桌面；nil = 单窗模式（这扇窗跟着人跑，永远算在当前桌面上）
    let spaceID: UInt64?
    /// 这扇窗所在的桌面是不是它那块屏此刻显示的桌面
    var isOnActiveSpace = true
    /// 上一次的播放决策，只用来节流诊断日志（nil = 还没决策过）
    var lastShouldPlay: Bool?
    /// 这一轮「看得见」是从什么时候开始的（nil = 此刻看不见）。
    /// 飞速连切时用来判断谁是刚路过的、谁是早就被甩在后面的。
    var visibleSince: TimeInterval?

    init(screen: NSScreen, layerMode: IconLayerMode,
         placement: SpacePlacement, screenUUID: String?, spaceID: UInt64?,
         backingLayers: Int = 1) {
        self.screenUUID = screenUUID
        if let screenUUID {
            screenKey = screenUUID
        } else if let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            screenKey = "display-\(number.uint32Value)"
        } else {
            screenKey = "frame-\(screen.frame.origin.x),\(screen.frame.origin.y),\(screen.frame.width)x\(screen.frame.height)"
        }
        self.spaceID = spaceID
        window = WallpaperWindow(screen: screen, layerMode: layerMode, placement: placement)
        backing = (1..<max(1, backingLayers)).map { i in
            WallpaperWindow(screen: screen, layerMode: layerMode,
                            placement: placement, levelOffset: i)
        }
        backingViews = backing.map { w in
            let v = BackingWallpaperView(frame: NSRect(origin: .zero, size: screen.frame.size))
            w.contentView = v
            return v
        }
        view = VideoWallpaperView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.contentView = view

        player = AVQueuePlayer()
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = true
        view.playerLayer.player = player
    }

    /// - Parameter loop: false 时不套 looper，播完会发 AVPlayerItemDidPlayToEndTime
    func load(url: URL, loop: Bool) {
        loadGeneration &+= 1
        let generation = loadGeneration
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

        // 裁剪几何需要视频原始尺寸，异步取回后回填（衬窗用的是同一份几何，一起给）
        Task { @MainActor [weak self] in
            guard let size = await VideoInfo.naturalSize(of: asset) else { return }
            guard let self, self.loadGeneration == generation else { return }
            self.view.videoSize = size
            for v in self.backingViews { v.videoSize = size }
        }
    }

    /// 重建窗口之后把进度接回原处。
    ///
    /// ⚠️ **不能 `load()` 完就直接 seek**：`AVPlayerItem` 刚建出来 `status` 是 `.unknown`，
    /// 这个阶段的 seek 会被丢掉（而且不报错），表现就是「明明 seek 了还是从头播」。
    /// 所以这里等到 `.readyToPlay` 再动，最多等 2 秒；等不到就放弃从头播，
    /// 总比卡在那儿强。`loadGeneration` 保证等待期间又换了片时这次 seek 直接作废。
    func seekWhenReady(to time: CMTime, tolerance: CMTime) {
        let generation = loadGeneration
        Task { @MainActor [weak self] in
            for _ in 0..<66 {                        // 66 × 30ms ≈ 2 秒
                guard let self, self.loadGeneration == generation else { return }
                if self.player.currentItem?.status == .readyToPlay { break }
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            guard let self, self.loadGeneration == generation,
                  let item = self.player.currentItem,
                  item.status == .readyToPlay
            else {
                DebugLog.log("↻ seek 放弃：2 秒内没等到 readyToPlay（或已换片）→ 这一扇从头播")
                return
            }
            // 越界保护：重建期间可能换成了更短的片
            let duration = item.duration
            guard !duration.isValid || !duration.isNumeric || time < duration else { return }
            // 在 async 上下文里 seek 会解析到返回 Bool 的那个重载，得显式 await
            _ = await self.player.seek(to: time,
                                       toleranceBefore: tolerance, toleranceAfter: tolerance)
            DebugLog.log(String(format: "↻ seek 完成 → %.2fs", time.seconds))
        }
    }

    /// 把静止帧喂给这个单元的所有衬窗。多扇窗共用同一个 `CGImage`，不会按层数翻倍。
    func setBackingFrame(_ image: CGImage?) {
        for v in backingViews { v.frameContents = image }
    }

    func unload() {
        loadGeneration &+= 1
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
        outputAttachedTo = nil
    }

    func teardown() {
        unload()
        for w in backing { w.orderOut(nil) }
        view.playerLayer.player = nil
        window.orderOut(nil)
        window.contentView = nil
    }
}

/// 壁纸引擎：管理每块屏幕 / 每个桌面的窗口与播放器，
/// 并根据设置 + 遮挡 + 当前桌面 + 电源状态决定播还是停。
final class WallpaperEngine {

    private var units: [ScreenUnit] = []
    private let settings = AppSettings.shared
    private let power = PowerMonitor()
    private let selector = MediaSelector()
    private var bag = Set<AnyCancellable>()
    /// 设置 → 引擎的实时中继。持有它订阅才活着。
    private var settingsRelay: LiveSettingsRelay?
    private var currentPath: String = ""
    private var currentLoop: Bool = true
    /// 播放器 / AVAsset 会惰性持续读视频，所以授权必须一直留到换片或卸载。
    private var currentMediaLease: MediaAccess.Lease?

    /// 这一轮窗口是按哪种方式建的。设置改了要整个重建，不能就地改 collectionBehavior。
    private var currentPlacement: SpacePlacement = .followsUser
    /// 私有 API 搬窗失败后本轮锁定公开 API 回退，避免 `applySettings()`
    /// 看到 desired/current 不同又立刻递归重建。手动重建或显示器变化会重试。
    private var placementFallbackActive = false
    /// 这一轮每桌面叠了几扇窗。和 placement 一样，改了只能整个重建。
    private var currentBackingLayers: Int = 1
    /// 上一次见到的桌面清单，用来判断「桌面被新建 / 删除了」
    private var knownDesktops: [String] = []
    /// 低频对账：新建桌面时系统不发任何公开通知，不兜一下的话
    /// 第一次切进那个新桌面仍会露一次底。一次 Mach IPC，开销可以忽略。
    private var reconcileTimer: Timer?
    /// 上一次给衬窗喂帧的时间，用来节流（遮挡通知一次转换会来好几条）
    private var lastBackingPump: TimeInterval = 0
    /// 上一次判定的出声窗口，只用来节流日志
    private var lastSpeakerLine = ""
    /// 对时耗时样本（毫秒）。见 `noteSeekCost`
    private var seekCosts: [Double] = []
    /// 这个视频的对时已经被判定为太贵，不再对时
    private var syncDisabled = false
    /// 每次真正 reload 递增；异步取图 / seek 回调只能修改它自己那一代。
    private var playbackGeneration: UInt64 = 0
    /// 画面可以在 Space 过渡开始时提前恢复，音频必须等过渡落定。
    private var audioResumeGate = AudioResumeGate.State()
    /// 上一轮实时采集的整体可见性，供 Space 落定回调使用。
    private var lastAnyDesktopVisible = true
    /// 同 Space 露出的兜底稳定期到期时补跑一次路由。
    private var audioGateTimer: Timer?
    /// `activeSpaceDidChange` 后等 WindowServer 把遮挡状态收尾，再决定是回到桌面还是落到另一个全屏窗口。
    private var audioSettleWorkItem: DispatchWorkItem?
    /// 系统唤醒和显示器唤醒可能连着到，合并成一次延迟 reload。
    private var wakeReloadWorkItem: DispatchWorkItem?
    /// 复用 —— `CIContext` 建一次就好，每次新建很贵
    /// 复用 —— `CIContext` 建一次就好，每次新建很贵。
    ///
    /// ⚠️ 色彩空间试过三种（默认 sRGB / 关掉色彩管理 / 标成 BT.709），
    /// 切桌面时的画面偏离分别是 −3.2 / −5.0 / −3.3 —— 关掉色彩管理明显更差，
    /// 另外两种在噪声内。所以用默认就行，别再为这个折腾。
    private lazy var ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// 同一时刻最多让几扇窗在播。2 是一次正常切换的下限（新旧两扇要一起亮约 0.9 秒），
    /// 留 3 是给连切时的余量。再多没有画面上的收益，只有解码开销。
    static let maxConcurrentPlayers = 3

    /// 对时耗时的预算（毫秒）。超过就不再对时 —— 见 `noteSeekCost`。
    /// 220 ms 的来历：编码正常的视频实测几十毫秒，关键帧稀的那份中位 882 ms，
    /// 两者差着一个数量级，阈值放中间任何位置都判得开。
    static let seekCostBudgetMs: Double = 220

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

        // 切桌面：先看桌面清单变没变（变了要增删窗口），再更新「谁在前台」
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleActiveSpaceDidChange()
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

        // 「减弱动态效果」是 .auto 档的判据，它一变就得重新决定放置方式。
        // 系统改这个是即时生效的，不重启不重登录，所以不能只在启动时读一次。
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let want = self.desiredStrategy
            guard SpaceStrategy.needsRebuild(
                desired: want, current: (self.currentPlacement, self.currentBackingLayers))
            else { return }
            NSLog("[StarPaper] 减弱动态效果变了 → 重建窗口（%@，%d 层）",
                  want.placement == .singleDesktop ? "每桌面一扇" : "单扇跟随", want.layers)
            self.rebuildScreens()
        }

        // 睡醒后 AVPlayer 经常卡死在 buffer 里，直接重建一次最省事
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                self?.scheduleWakeReload()
            }
        }

        // 设置改动实时落地。调度器为什么必须是 DispatchQueue.main，见 LiveSettingsRelay。
        settingsRelay = LiveSettingsRelay(settings) { [weak self] in
            guard let self else { return }
            self.selector.settingsChanged()
            self.applySettings()
        }

        rebuildScreens()
    }

    private func scheduleWakeReload() {
        wakeReloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reloadVideo(force: true) }
        wakeReloadWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }

    private func handleActiveSpaceDidChange() {
        DebugLog.log("◇ activeSpaceDidChange 收到，等 WindowServer 落定")
        reconcileDesktops()
        audioSettleWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // 再读一轮真实 occlusion：通知到达时 WindowServer 可能还在动画收尾。
            self.updatePlayback()
            self.audioResumeGate.noteSettled(self.audioSample(isVisible: self.lastAnyDesktopVisible))
            DebugLog.log("◇ Space 已落定 桌面可见=\(self.lastAnyDesktopVisible ? "Y" : "N") "
                + "在桌面=\(self.audioResumeGate.lastOnDesktop ? "Y" : "N")")
            self.scheduleAudioGateRelease(now: Date.timeIntervalSinceReferenceDate)
            self.applyAudioRouting()
        }
        audioSettleWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + AudioResumeGate.settleDelay, execute: item)
    }

    // MARK: - 窗口布局

    /// 这一轮的放置方式 + 每桌面叠几扇窗。三个来源合流，规则见 `SpaceStrategy`。
    private var desiredStrategy: (placement: SpacePlacement, layers: Int) {
        if placementFallbackActive { return (.followsUser, 1) }
        return SpaceStrategy.resolve(
            mode: settings.perSpaceMode,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            bridgeAvailable: SpaceBridge.isAvailable,
            requestedLayers: settings.backingLayers,
            maxLayers: AppSettings.maxBackingLayers)
    }

    private var desiredBackingLayers: Int { desiredStrategy.layers }
    private var desiredPlacement: SpacePlacement { desiredStrategy.placement }

    /// 私有 API 那条路走不通时该退回什么。
    ///
    /// ⚠️ **placement 和 layers 必须成对来自同一个纯函数**，不能在回退分支里各写各的：
    /// 只退 placement、把 layers 留在 3，末尾的 `applySettings()` 就会看到
    /// `desiredBackingLayers`(1) ≠ `currentBackingLayers`(3)，再调一次 `rebuildScreens()`，
    /// 而它开头又清掉 `placementFallbackActive` → 重试 → 再失败 → 直接递归爆栈。
    /// 走 `SpaceStrategy.resolve(bridgeAvailable: false)` 之后，SelfTest 里
    /// 「私有API缺失」那两条断言就真的盖住了这条回退路径。
    private var fallbackStrategy: (placement: SpacePlacement, layers: Int) {
        SpaceStrategy.resolve(
            mode: settings.perSpaceMode,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            bridgeAvailable: false,
            requestedLayers: settings.backingLayers,
            maxLayers: AppSettings.maxBackingLayers)
    }

    func rebuildScreens() {
        // ⚠️ 这个函数会 teardown 掉所有 ScreenUnit，播放进度跟着 player 一起没了。
        // 而走到这里的路径全是日常操作：新建 / 关闭桌面、把 App Store 这类窗口切进切出
        // 全屏（全屏会建一个新 Space，退出时又销毁 → 一进一出重建两次）、
        // 改「减弱动态效果」开关。不把进度接回去的话，用户看到的就是
        // 「壁纸和 BGM 每隔一会儿就自己从头开始」。
        let resumePath = currentPath
        // ⚠️ 取「此刻真正在播的那一份」，不能取 units.first ——
        // 每桌面一扇窗时第一扇可能是早就暂停在别处的桌面窗，接回去等于跳到不相干的位置。
        let resumeSource = units.first { $0.player.timeControlStatus != .paused
                                         && $0.player.currentItem != nil }
            ?? units.first { $0.isAudioScreen && $0.player.currentItem != nil }
            ?? units.first { $0.player.currentItem != nil }
        let resumeTime = resumeSource?.player.currentTime()
        DebugLog.log("↻ rebuildScreens 窗数=\(units.count) "
            + "进度=\(resumeTime.map { String(format: "%.2fs", $0.seconds) } ?? "无")")

        placementFallbackActive = false
        let mode = settings.iconLayer
        let placement = desiredPlacement
        let layers = desiredBackingLayers
        units.forEach { $0.teardown() }
        currentPlacement = placement
        currentBackingLayers = layers

        switch placement {
        case .followsUser:
            units = NSScreen.screens.map {
                ScreenUnit(screen: $0, layerMode: mode, placement: .followsUser,
                           screenUUID: SpaceBridge.uuid(of: $0), spaceID: nil,
                           backingLayers: layers)
            }
            knownDesktops = []
        case .singleDesktop:
            units = buildPerDesktopUnits(layerMode: mode, backingLayers: layers)
            // 一个桌面都建不出来（私有 API 变了 / 布局读不到）就退回老行为，
            // 宁可露那 0.9 秒，也不能让屏幕上一扇壁纸都没有
            if units.isEmpty {
                NSLog("[StarPaper] 每桌面窗口建不起来，退回单窗模式")
                let fb = fallbackStrategy          // ⚠️ 见 fallbackStrategy 的注释
                placementFallbackActive = true
                currentPlacement = fb.placement
                currentBackingLayers = fb.layers
                units = NSScreen.screens.map {
                    ScreenUnit(screen: $0, layerMode: mode, placement: fb.placement,
                               screenUUID: SpaceBridge.uuid(of: $0), spaceID: nil,
                               backingLayers: fb.layers)
                }
                knownDesktops = []
            }
        }

        for unit in units {
            // 从下往上：衬窗先挂，主窗最后 —— 层级已经决定了 z 序，
            // 这个顺序只是让同层意外撞车时也是主窗在上
            for w in unit.backing.reversed() { w.orderFrontRegardless() }
            unit.window.orderFrontRegardless()
        }
        // ⚠️ 必须先 orderFront 再搬 —— windowNumber 要窗口真的挂进 WindowServer 才有值
        if !placeUnitsIntoDesktops() {
            // CGS 枚举成功但搬窗被拒绝时，不能留下“某些桌面永久没壁纸”
            // 的半成功状态。整轮原子退回公开 API 的 sticky 窗。
            NSLog("[StarPaper] 每桌面窗口放置不完整，整体退回单窗模式")
            units.forEach { $0.teardown() }
            let fb = fallbackStrategy              // ⚠️ 见 fallbackStrategy 的注释
            placementFallbackActive = true
            currentPlacement = fb.placement
            currentBackingLayers = fb.layers
            units = NSScreen.screens.map {
                ScreenUnit(screen: $0, layerMode: mode, placement: fb.placement,
                           screenUUID: SpaceBridge.uuid(of: $0), spaceID: nil,
                           backingLayers: fb.layers)
            }
            knownDesktops = []
            for unit in units { unit.window.orderFrontRegardless() }
        }
        refreshActiveSpaces()
        scheduleReconcile()

        currentPath = ""
        reloadVideo(force: true)
        restorePlaybackPosition(path: resumePath, time: resumeTime)
        applySettings()
        // 搬完窗、接好进度、设置也落地了，最后才让它们现身。见 WallpaperWindow 里的说明。
        revealWindows()
    }

    /// 把这一轮建出来的窗口统一放出来。
    ///
    /// 窗口是隐形建出来的（`WallpaperWindow.alphaValue = 0`），因为在搬去各自桌面之前
    /// 它们全叠在当前桌面上。等放置、进度、设置都就位了再一起现身，用户就只会看到
    /// 「壁纸出现了」，而不是「好几层画面和好几个时钟闪了一下」。
    private func revealWindows() {
        for unit in units {
            for w in unit.allWindows { w.alphaValue = 1 }
        }
    }

    /// 重建之后把进度接回去。
    ///
    /// 只在**还是同一个视频**时接：重建期间可能正好轮播换了片，那本来就该从头。
    /// 0.25 秒以内不接 —— 跟从头几乎没差别，省一次 seek（4K60 的 seek 要从最近的
    /// 关键帧重解上百帧，见 `noteSeekCost` 的实测数据）。
    private func restorePlaybackPosition(path: String, time: CMTime?) {
        guard PlaybackResume.shouldRestore(previousPath: path, currentPath: currentPath,
                                           time: time),
              let t = time
        else {
            DebugLog.log("↻ 不接回进度（换片 / 无进度 / 起点太靠前）→ 从头播")
            return
        }
        let tol = CMTime(seconds: 0.1, preferredTimescale: 600)
        DebugLog.log(String(format: "↻ 接回进度 %.2fs → %d 扇窗", t.seconds, units.count))
        for unit in units { unit.seekWhenReady(to: t, tolerance: tol) }
    }

    /// 按「每块屏 × 每个普通桌面」建窗
    private func buildPerDesktopUnits(layerMode: IconLayerMode, backingLayers: Int) -> [ScreenUnit] {
        let screens = NSScreen.screens
        var built: [ScreenUnit] = []
        var seen: [String] = []

        let layout = SpaceBridge.layout()
        for display in layout {
            guard let screen = SpaceBridge.screen(for: display.displayIdentifier, among: screens)
            else {
                built.forEach { $0.teardown() }
                return []
            }
            let uuid = SpaceBridge.uuid(of: screen)
            for desktop in display.desktops {
                built.append(ScreenUnit(
                    screen: screen, layerMode: layerMode, placement: .singleDesktop,
                    screenUUID: uuid, spaceID: desktop.id, backingLayers: backingLayers))
                seen.append(desktopKey(display.displayIdentifier, desktop.id))
            }
        }
        knownDesktops = seen.sorted()
        return built
    }

    private func desktopKey(_ display: String, _ space: UInt64) -> String { "\(display)#\(space)" }

    /// 把每扇窗搬到它自己的桌面上。搬不动的窗直接撤掉 ——
    /// 留着会变成一扇跟着当前桌面走的多余窗口，反而遮住别的。
    private func placeUnitsIntoDesktops() -> Bool {
        guard currentPlacement == .singleDesktop else { return true }
        var survivors: [ScreenUnit] = []
        var allMainWindowsPlaced = true
        for unit in units {
            guard let spaceID = unit.spaceID else { survivors.append(unit); continue }
            if SpaceBridge.move(windowNumber: unit.window.windowNumber, to: spaceID) {
                // 衬窗搬不动只是少挡一层，不影响壁纸本身，所以失败只撤那一扇
                for w in unit.backing where !SpaceBridge.move(windowNumber: w.windowNumber, to: spaceID) {
                    NSLog("[StarPaper] 衬窗放不进桌面 %llu，撤掉这一扇", spaceID)
                    w.orderOut(nil)
                }
                survivors.append(unit)
            } else {
                allMainWindowsPlaced = false
                NSLog("[StarPaper] 窗口放不进桌面 %llu，撤掉这一扇", spaceID)
                unit.teardown()
            }
        }
        units = survivors
        return allMainWindowsPlaced && !survivors.isEmpty
    }

    // MARK: - 当前桌面

    /// 桌面清单变了就重建，只是切了个桌面就只更新「谁在前台」
    private func reconcileDesktops() {
        guard currentPlacement == .singleDesktop else {
            refreshActiveSpaces()
            updatePlayback()
            return
        }
        var now: [String] = []
        for display in SpaceBridge.layout() {
            for desktop in display.desktops {
                now.append(desktopKey(display.displayIdentifier, desktop.id))
            }
        }
        now.sort()
        if now != knownDesktops {
            NSLog("[StarPaper] 桌面数变了：%d → %d，重建窗口", knownDesktops.count, now.count)
            rebuildScreens()
        } else {
            refreshActiveSpaces()
            updatePlayback()
        }
    }

    private func scheduleReconcile() {
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        guard currentPlacement == .singleDesktop else { return }
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            self?.reconcileDesktops()
        }
        timer.tolerance = 5                      // 允许系统合并唤醒，别为了对账单独醒
        RunLoop.main.add(timer, forMode: .common)
        reconcileTimer = timer
    }

    /// 更新每扇窗「我这块屏此刻显示的是不是我这个桌面」，
    /// 并把出声 / 播完事件的职责交给此刻真正看得见的那一扇。
    private func refreshActiveSpaces() {
        guard currentPlacement == .singleDesktop else {
            for unit in units { unit.isOnActiveSpace = true }
            designateAudioAndPrimary()
            return
        }
        var currentByDisplay: [String: UInt64] = [:]
        for display in SpaceBridge.layout() {
            currentByDisplay[display.displayIdentifier] = display.currentSpaceID
        }
        for unit in units {
            guard let spaceID = unit.spaceID else { unit.isOnActiveSpace = true; continue }
            unit.isOnActiveSpace = currentByDisplay.values.contains(spaceID)
        }
        designateAudioAndPrimary()
    }

    /// 指派两个职责。**两者的取舍方向相反，别再合并回一个 pick：**
    ///
    /// - `isPrimary`（播完切下一个的事件源）：必须跟着当前桌面走，
    ///   钉死的话人不在那个桌面时它是暂停的，永远报不出「播完了」。
    /// - `isAudioScreen`（出声的那一份）：**必须尽量不换人**。换人 = 音频从另一个
    ///   player 重新起播，听感就是「切一次桌面 BGM 卡一下」（2026-08-23 实测）。
    ///   配合 `updatePlayback()` 里的 `keepsAudioAlive` 豁免，它全程不停，声音完全连续。
    private func designateAudioAndPrimary() {
        let mainUUID = NSScreen.main.flatMap { SpaceBridge.uuid(of: $0) }
        for unit in units { unit.isPrimary = false }

        let visible = units.filter { $0.isOnActiveSpace }
        let pick = visible.first(where: { $0.screenUUID != nil && $0.screenUUID == mainUUID })
            ?? visible.first
            ?? units.first
        pick?.isPrimary = true

        // 已经有人在出声就一直是它。只有重建窗口（那一份根本不存在了）才重新挑，
        // 挑此刻看得见的那一扇 —— 这样常态下「一直在播的那份」就是人正在看的那份，
        // 不会白白多解码一路。
        guard !units.contains(where: { $0.isAudioScreen }) else { return }
        pick?.isAudioScreen = true
    }

    // MARK: - 视频加载

    func reloadVideo(force: Bool = false) {
        let path = selector.currentPath
        let loop = selector.shouldLoop

        guard !path.isEmpty else {
            units.forEach { $0.unload() }
            currentMediaLease = nil
            currentPath = ""
            isPlaying = false
            onStateChange?()
            return
        }
        guard force || path != currentPath || loop != currentLoop else { return }

        guard let lease = MediaAccess.acquire(path: path) else {
            units.forEach { $0.unload() }
            currentMediaLease = nil
            currentPath = ""
            isPlaying = false
            NSLog("[StarPaper] 视频文件不存在: %@", (path as NSString).lastPathComponent)
            onStateChange?()
            return
        }
        // 换视频＝重新评估对时贵不贵（关键帧密度是逐文件的属性）
        if path != currentPath { seekCosts.removeAll(); syncDisabled = false }
        currentPath = path
        currentLoop = loop
        playbackGeneration &+= 1
        let generation = playbackGeneration

        let url = lease.url
        units.forEach { $0.load(url: url, loop: loop) }
        currentMediaLease = lease
        refreshBackingFrame(url: url, generation: generation, lease: lease)
        updatePlayback()
        onStateChange?()
    }

    /// 把「正在播的那一帧」喂给所有衬窗。
    ///
    /// ## 为什么是这个时机
    ///
    /// 第一版只在换视频时抓一次固定帧，实际用起来一眼就看得出 ——
    /// 「切换的时候感觉很多不同时间的画面」：衬窗停在第 1 秒，主窗早播远了，
    /// 透出来的就是两个时间点的画面叠在一起。
    ///
    /// 第二版改成每秒定时喂，帧是跟上了，但 **CPU 1.4% → 5.6%** ——
    /// 这个方案的全部价值就在于几乎不要钱，4 倍 CPU 直接把它否掉。
    ///
    /// 现在只在 **Space 转换刚开始**时喂一次：遮挡通知在按键后约 0.126 秒就到，
    /// 而衬窗真正露脸还有约 0.9 秒（见 `updatePlayback` 里对这两个时刻的说明），
    /// 完全来得及。**静止时一次都不跑。**
    private func pumpBackingFrame() {
        // 取帧优先取「出声的那一份」：它现在是全程不停的那一扇（见 applyAudioRouting），
        // 时钟最稳。退而求其次才随便挑一个在播的 —— 转换期间新旧两扇都在播，
        // 而它们之间允许有 0.1 秒的对齐容差，挑错了衬窗就会比主窗差那 0.1 秒。
        guard desiredBackingLayers > 1,
              let source = units.first(where: {
                  $0.isAudioScreen && $0.player.timeControlStatus == .playing
              }) ?? units.first(where: { $0.player.timeControlStatus == .playing }),
              let buffer = source.copyCurrentPixelBuffer()
        else { return }

        var image = CIImage(cvPixelBuffer: buffer)
        // 缩到屏幕逻辑尺寸：衬窗最多只透出百分之十几，全分辨率纯属浪费内存
        let target = NSScreen.main?.frame.width ?? 1512
        if image.extent.width > target, image.extent.width > 1 {
            let k = target / image.extent.width
            image = image.transformed(by: CGAffineTransform(scaleX: k, y: k))
        }
        guard let cg = ciContext.createCGImage(image, from: image.extent) else { return }
        for unit in units { unit.setBackingFrame(cg) }
    }

    /// 一次转换里连喂几帧，而不是只喂一帧。
    ///
    /// 只喂一帧的问题（2026-08-23 肉眼可见，画面对不齐）：
    /// 抓帧发生在**转换刚开始**（遮挡通知，按键后约 0.126 秒），而衬窗真正被看见
    /// 是在压暗那 0.4 秒里 —— 中间视频已经走了三四百毫秒。画面动得快的时候，
    /// 透出来的衬窗和主窗就是两个时间点，看起来像重影。
    ///
    /// 补喂三次把最坏偏差从约 0.4 秒压到约 0.15 秒。之所以敢补：**只在转换期间跑**
    /// （静止时一次都不跑），一次转换总共 4 次抓帧，每次是一个缩到屏幕逻辑尺寸的
    /// `createCGImage`。当年被否掉的是「每秒定时喂」那版（CPU 1.4% → 5.6%），
    /// 不是这种按事件的短暂突发 —— 别把两者混为一谈。
    private func pumpBackingBurst() {
        pumpBackingFrame()
        for delay in [0.12, 0.25, 0.40] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.pumpBackingFrame()
            }
        }
    }

    /// 换视频时先垫一张底图，免得第一次转换时衬窗还是空的（黑的）。
    /// 之后由 `pumpBackingFrame` 接手跟进度。
    private func refreshBackingFrame(url: URL, generation: UInt64, lease: MediaAccess.Lease) {
        guard desiredBackingLayers > 1 else {
            units.forEach { $0.setBackingFrame(nil) }
            return
        }
        let asset = AVURLAsset(url: url)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let box = NSScreen.screens
            .map(\.frame.size)
            .reduce(CGSize.zero) { CGSize(width: max($0.width, $1.width),
                                          height: max($0.height, $1.height)) }
        let maxSize = CGSize(width: box.width * scale, height: box.height * scale)

        Task { @MainActor [weak self] in
            defer { withExtendedLifetime(lease) {} }
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            // 容差放到无穷大 = 直接用最近的关键帧，不做精确 seek。
            // 衬窗要的是「像这个视频」，不是某一帧，省下的解码时间可观。
            gen.requestedTimeToleranceBefore = .positiveInfinity
            gen.requestedTimeToleranceAfter = .positiveInfinity
            if maxSize.width > 1 { gen.maximumSize = maxSize }
            do {
                let (image, _) = try await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600))
                guard let self, self.playbackGeneration == generation else { return }
                // 抓帧是异步的，回来时窗口可能已经因为改设置 / 增删桌面重建过了
                for unit in self.units { unit.setBackingFrame(image) }
            } catch {
                guard let self, self.playbackGeneration == generation else { return }
                let e = error as NSError
                NSLog("[StarPaper] 衬窗底图抓不到：%@(%ld)", e.domain, e.code)
            }
        }
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
        // 放置方式是建窗时定死的，改了只能整个重建
        if SpaceStrategy.needsRebuild(desired: desiredStrategy,
                                      current: (currentPlacement, currentBackingLayers)) {
            rebuildScreens()
            return
        }
        for unit in units {
            for w in unit.allWindows { w.applyLayerMode(settings.iconLayer) }
            unit.view.apply(settings)
            for v in unit.backingViews { v.apply(settings) }
            unit.player.defaultRate = Float(settings.playbackRate)
            if unit.player.timeControlStatus != .paused {
                unit.player.rate = Float(settings.playbackRate)
            }
        }
        // ⚠️ 音量 / 静音**不在这里**落地，交给 updatePlayback() → applyAudioRouting()。
        //    在这里写一次是曾经的 bug：见 applyAudioRouting() 的注释。
        reloadVideo()
        updatePlayback()
    }

    // MARK: - 遮挡

    private func handleOcclusionChange(for window: WallpaperWindow) {
        guard let unit = units.first(where: { $0.window === window }) else { return }
        unit.isOccluded = !window.occlusionState.contains(.visible)
        // 遮挡状态一变，多半就是 Space 转换刚开始 —— 趁衬窗还有 0.9 秒才露脸，
        // 把它的画面对到当前进度上。一次转换会来好几条通知，所以要节流。
        let now = Date.timeIntervalSinceReferenceDate
        if now - lastBackingPump > 0.5 {
            lastBackingPump = now
            pumpBackingBurst()
        }
        updatePlayback()
    }

    // MARK: - 播放决策

    /// 单一入口：所有「该不该播」的判断都汇总到这里，避免多处 play/pause 打架
    func updatePlayback() {
        let globalOK = power.shouldPlay(with: settings) && !settings.isPaused
        var anyPlaying = false

        // 先把「谁看得见」整体算出来：出声那一份的豁免要看**有没有任何桌面在前台**。
        // 切桌面时始终至少有一扇看得见（转换期间新旧两扇一起亮），所以 BGM 不断；
        // 而进全屏 app 时一扇都看不见，这时该停就停 —— 全屏看视频还放着壁纸 BGM 是骚扰。
        for unit in units {
            // ⚠️ 实时读，不能只信通知攒下来的缓存值。
            // 窗口是在当前桌面建好之后再搬到目标桌面的，被搬走的那些**从来没收到过**
            // 遮挡通知，`isOccluded` 会一直停在初始值 false —— 于是它们永远被判成
            // 「看得见」，四个桌面全在解码（实测 CPU 5% → 11%）。
            // 通知只负责触发重新决策，状态本身每次都从窗口现读。
            let rawOccluded = !unit.window.occlusionState.contains(.visible)
            // ⚠️ 单扇 sticky 窗的 occlusionState 在 Space 转换后会**长时间卡在「不可见」**
            // （2026-08-31 实测 16.3 秒），因为它整扇被换成了系统静态壁纸快照。
            // 直接信它 = 切一次桌面 BGM 断一下。规则见 SpaceStrategy.stickyOccluded。
            unit.isOccluded = currentPlacement == .followsUser
                ? SpaceStrategy.stickyOccluded(
                    rawOccluded: rawOccluded,
                    currentSpaceIsDesktop: SpaceBridge.currentSpaceIsDesktop(),
                    frontmostCoversScreen: ForegroundCoverage.frontmostCoversScreen())
                : rawOccluded
            // 判据是「在当前桌面 **或** 此刻没被遮挡」这个并集，不能只看前者：
            // `activeSpaceDidChangeNotification` 比画面**晚约 0.93 秒**（实测：按键后
            // 0.126s 系统就发了遮挡通知，1.056s 才发 activeSpaceDidChange）。
            // 只等后者的话，人已经站在新桌面上了那个 player 还停着，
            // 表现为切过去先卡 0.1~0.25 秒、再跳一下才恢复。
            //
            // 而 Space 转换一**开始**，系统就把要参与转换的窗口标成「不再被遮挡」——
            // 公开 API，且早得多。于是转换期间有一两扇窗一起播（约 0.9 秒），
            // 转换结束后不在前台的那些重新被标成遮挡，自动停回去。
            // ⚠️ 这个并集**只对每桌面窗口模式成立**。单扇 sticky 窗的 isOnActiveSpace 恒 true，
            // 直接用会让遮挡暂停 100% 失效（2026-08-29）。判据见 SpaceStrategy.isSeen。
        }
        let now = Date.timeIntervalSinceReferenceDate
        let neverPause = UserDefaults.standard.bool(forKey: "debugNeverPause")
        let snapshots = units.map { unit in
            PlaybackUnitState(
                screenID: unit.screenKey,
                isOnActiveSpace: unit.isOnActiveSpace,
                isOccluded: unit.isOccluded,
                isAudioScreen: unit.isAudioScreen,
                visibleSince: unit.visibleSince)
        }
        let decision = PlaybackPolicy.decide(
            units: snapshots, placement: currentPlacement,
            pauseWhenOccluded: settings.pauseWhenOccluded,
            muted: settings.muted, globalOK: globalOK,
            hasMedia: !currentPath.isEmpty, neverPause: neverPause,
            now: now, basePlayerLimit: Self.maxConcurrentPlayers)
        for i in units.indices { units[i].visibleSince = decision.visibleSince[i] }
        let anyDesktopVisible = decision.anyDesktopVisible

        // 一轮决策的抬头：把所有全局输入摆在一起，省得看下面每个 unit 时还要回想设置是什么
        DebugLog.log("""
            ── updatePlayback  放置=\(currentPlacement == .singleDesktop ? "每桌面一扇" : "单扇跟随") \
            窗数=\(units.count) 有桌面可见=\(anyDesktopVisible ? "Y" : "N") 并发上限=\(decision.playerLimit) \
            | 遮挡暂停=\(settings.pauseWhenOccluded ? "开" : "关") \
            静音=\(settings.muted ? "开" : "关") \
            手动暂停=\(settings.isPaused ? "是" : "否") \
            省电准许=\(power.shouldPlay(with: settings) ? "Y" : "N")
            """)

        // ⭐ 画面提前恢复，音频等人真的落到桌面上。判据是「当前 Space 是不是普通桌面」，
        // 不是「壁纸看得见没有」，也不是任何时间常数 —— 规则与三次失败史见 `AudioResumeGate`。
        let sample = audioSample(isVisible: anyDesktopVisible, now: now)
        audioResumeGate.observe(sample)
        if settings.pauseWhenOccluded && anyDesktopVisible {
            DebugLog.log("落定门采样 当前Space是桌面="
                + (sample.currentSpaceIsDesktop.map { $0 ? "Y" : "N" } ?? "判不出")
                + " 前台盖满屏=\(sample.frontmostCoversScreen ? "Y" : "N")"
                + " 判定在桌面=\(audioResumeGate.lastOnDesktop ? "Y" : "N")")
        }
        lastAnyDesktopVisible = anyDesktopVisible
        scheduleAudioGateRelease(now: now)

        for (i, unit) in units.enumerated() {
            // 「被窗口遮挡时暂停」对出声那一份要按**整块屏**判，不能按它自己那个桌面判：
            // 人的理解是「壁纸都看不见了才叫被遮挡」，而不是「我的桌面不在前台」——
            // 按后者的话，每切一次桌面出声那份就停一次，②的卡顿又回来了。
            let occludedStop = settings.pauseWhenOccluded
                && (unit.isAudioScreen ? !anyDesktopVisible : unit.isOccluded)

            // 没人看得见的桌面一律停着 —— 继续解码就是按桌面数量翻倍烧电。
            // 停下不等于变空白：AVPlayerLayer 会留着最后一帧，
            // 切回来的那一瞬间显示的就是它，所以照样不露系统静态壁纸。
            let visibleNow = decision.visual[i]

            // ⭐ 唯一的例外：出声的那一份不跟着桌面停。
            // 它一停，切一次桌面音频就要在另一个 player 上重新起播 —— 听感是「BGM 顿一下」。
            // 代价是人不在它那个桌面时多一路解码，所以只在**真的要出声**时才付这个钱：
            // 静音时（默认）行为和以前完全一样。
            // ⚠️ 只有 `pauseWhenOccluded` 能压过它（上面那行）—— 那是用户明确要求「被挡住就省电」。
            //    反过来，**用户把那个开关关掉了就不许在这里自作主张停**：
            //    2026-08-23 曾加过一条「所有桌面都看不见时也停」，结果是开关关着、
            //    进全屏 app 音频照样断 —— 那等于拿实现的判断覆盖用户的设置，已撤回。
            let keepsAudioAlive = unit.isAudioScreen && !settings.muted
            let shouldPlay = decision.play[i]

            // 诊断：播放状态翻转时打一行，带上判据本身 ——
            // 「切过去画面冻住不动」这类现象只有把 active / occluded 两个位一起看才判得出。
            //
            // ⚠️ NSLog 那条留着（异常排查时 Console.app 还能看），但**它读不出来**：
            // 2026-08-29 用 log show 的三种 predicate 都抓不到，所以真正能用的是 DebugLog。
            if shouldPlay != unit.lastShouldPlay {
                unit.lastShouldPlay = shouldPlay
                NSLog("[StarPaper] 桌面 %llu %@（在当前桌面=%@ 被遮挡=%@ 出声位=%@）",
                      unit.spaceID ?? 0, shouldPlay ? "播" : "停",
                      unit.isOnActiveSpace ? "是" : "否",
                      unit.isOccluded ? "是" : "否",
                      unit.isAudioScreen ? "是" : "否")
            }
            // 每一轮都记，不只记翻转 —— 「为什么该停却没停」恰恰发生在状态**没**翻转的时候，
            // 只记翻转的话那种 bug 在日志里是完全看不见的（就是 perSpaceMode=off
            // 那个遮挡暂停失效的情形）。
            DebugLog.log("""
                unit[\(i)] space=\(unit.spaceID.map(String.init) ?? "-") \
                \(shouldPlay ? "播" : "停") | \
                当前桌面=\(unit.isOnActiveSpace ? "Y" : "N") \
                遮挡=\(unit.isOccluded ? "Y" : "N") \
                看得见=\(visibleNow ? "Y" : "N") \
                出声位=\(unit.isAudioScreen ? "Y" : "N") \
                | 遮挡停=\(occludedStop ? "Y" : "N") \
                护音=\(keepsAudioAlive ? "Y" : "N") \
                全局OK=\(globalOK ? "Y" : "N")
                """)

            if shouldPlay {
                if unit.player.timeControlStatus != .playing {
                    syncToPlayingUnit(unit)
                    unit.player.play()
                    unit.player.rate = Float(settings.playbackRate)
                }
                anyPlaying = true
            } else {
                if unit.player.timeControlStatus != .paused {
                    unit.player.pause()
                }
            }
            // 时钟跟着播放状态走：被遮挡 / 锁屏 / 手动暂停 / 不在当前桌面时没人看得见，
            // 没必要让它每秒醒来。恢复时 setActive(true) 会立刻补一次刷新。
            unit.view.setClockActive(decision.clockActive[i])
        }

        applyAudioRouting()

        if anyPlaying != isPlaying {
            isPlaying = anyPlaying
            onStateChange?()
        }
    }

    /// 组装一次音频门采样。**当前 Space 是不是普通桌面**是主判据，
    /// 前台覆盖率只在私有 API 被裁掉（MAS 构建）时才作数。
    private func audioSample(isVisible: Bool,
                             now: TimeInterval = Date.timeIntervalSinceReferenceDate)
        -> AudioResumeGate.Sample {
        let onDesktop = SpaceBridge.currentSpaceIsDesktop()
        // 主判据可用时就不去翻窗口列表了，省一次全窗枚举
        let covers = onDesktop == nil ? ForegroundCoverage.frontmostCoversScreen() : false
        return AudioResumeGate.Sample(
            isVisible: isVisible,
            enabled: settings.pauseWhenOccluded,
            currentSpaceIsDesktop: onDesktop,
            frontmostCoversScreen: covers,
            now: now)
    }

    /// 静音窗口到期时补跑一次路由。
    ///
    /// ⚠️ 少了这个的话：门关上之后如果没有任何新事件（人划完就不动了），
    /// `applyAudioRouting()` 不会再被调用，BGM 就**再也不出声**了 —— 比原来的 bug 更糟。
    private func scheduleAudioGateRelease(now: TimeInterval) {
        audioGateTimer?.invalidate()
        audioGateTimer = nil
        guard let deadline = audioResumeGate.nextRecheck, deadline > now else { return }
        let t = Timer(timeInterval: deadline - now + 0.02, repeats: false) { [weak self] _ in
            // ⚠️ 到点**重新采样一轮**再决定，不能直接 applyAudioRouting()。
            // 旧实现在这里无条件放行，等于把「等落定」退化成盲超时 —— 那正是 BGM 漏声的出口。
            self?.updatePlayback()
        }
        RunLoop.main.add(t, forMode: .common)
        audioGateTimer = t
    }

    /// 让「出声的那一份」跟着此刻真正在播的那扇窗走。规则见 `AudioRouting`。
    ///
    /// ⚠️ **必须挂在 `updatePlayback()` 里，不能只在 `applySettings()` 里做一次。**
    /// 只在改设置时写 `isMuted` 的话，出声资格会钉死在「上次改设置时所在的那个桌面」上：
    /// 之后切到别的桌面，`designateAudioAndPrimary()` 虽然把 `isAudioScreen` 挪过去了，
    /// 新那一扇的 player 仍然是静音的，而旧那一扇又因为不在当前桌面被暂停 ——
    /// 于是**只有一个桌面有声音**，别的桌面全哑（2026-08-23 实测到的 bug）。
    ///
    /// 教训：`isAudioScreen` 这类「谁负责」的标志位，改标志位的地方和落地到硬件的地方
    /// 必须是同一条路径；分开写就一定会有一边忘了跟。
    private func applyAudioRouting() {
        let mainUUID = NSScreen.main.flatMap { SpaceBridge.uuid(of: $0) }
        let index = AudioRouting.speakerIndex(
            designated: units.map(\.isAudioScreen),
            live: units.map { $0.player.timeControlStatus != .paused },
            onMainScreen: units.map { $0.screenUUID != nil && $0.screenUUID == mainUUID }
        )
        let speaker = index.map { units[$0] }
        let vol = Float(settings.volume)

        // 从「一扇都看不见」变回可见后，等 Space 真正落定再出声。
        let gated = audioResumeGate.shouldSilence(now: Date.timeIntervalSinceReferenceDate)

        for unit in units {
            let wantMuted = settings.muted || unit !== speaker || gated
            if unit.player.isMuted != wantMuted { unit.player.isMuted = wantMuted }
            if unit.player.volume != vol { unit.player.volume = vol }
        }

        // 换人才打一行，别把日志刷爆（updatePlayback 一次切换会跑好几遍）
        let desc = speaker.map { u in u.spaceID.map { "桌面 \($0)" } ?? "屏幕 \(u.screenUUID ?? "?")" }
            ?? "无（没有窗口在播）"
        DebugLog.log("audio 路由=\(desc) 用户静音=\(settings.muted ? "Y" : "N") 落定门=\(gated ? "Y" : "N")")
        let line = "\(desc) muted=\(settings.muted)"
        if line != lastSpeakerLine {
            lastSpeakerLine = line
            NSLog("[StarPaper] 出声的那一份 → %@", line)
        }
    }


    /// 把刚被唤醒的那扇窗对到「此刻正在播的那一份」的进度上。
    ///
    /// 每个桌面各有一个 player，离开时暂停、进度就停在那儿；不对一下的话
    /// 各个桌面会越飘越远，切过去看到的是完全不相干的一段。
    ///
    /// 之所以敢在这里 seek：唤醒发生在 Space 转换**刚开始**的时候（遮挡通知，
    /// 见 `updatePlayback` 里的说明），离这扇窗真正露脸还有约 0.9 秒，
    /// seek 完全来得及，用户看不到跳帧。容差留 0.1 秒 —— 要求逐帧对齐会强制
    /// 从关键帧重解，代价不值得，差 0.1 秒肉眼看不出来。
    private func syncToPlayingUnit(_ target: ScreenUnit) {
        guard !syncDisabled,
              currentPlacement == .singleDesktop,
              let master = units.first(where: {
                  $0 !== target && $0.player.timeControlStatus == .playing
              })
        else { return }
        let t = master.player.currentTime()
        guard t.isValid, t.isNumeric else { return }
        let tol = CMTime(seconds: 0.1, preferredTimescale: 600)
        let t0 = Date.timeIntervalSinceReferenceDate
        let generation = playbackGeneration
        target.player.seek(to: t, toleranceBefore: tol, toleranceAfter: tol) { [weak self] finished in
            guard let self, finished, self.playbackGeneration == generation else { return }
            self.noteSeekCost((Date.timeIntervalSinceReferenceDate - t0) * 1000)
        }
    }

    /// 记一次对时耗时，太贵就自动不再对时。
    ///
    /// ## 为什么要有这个
    ///
    /// H.264 只能从关键帧往后解码，所以「跳到第 X 秒」的代价取决于**从最近的关键帧到 X
    /// 有多少帧**。2026-08-23 实测的那份壁纸：3840×2160、60fps、128 秒，
    /// 关键帧每 4.167 秒一个（GOP=250，很常见的默认值）—— 平均要解 ~125 帧、最坏 250 帧的 4K。
    /// ⚠️ 也就是说这不是「坏文件」，**任何 4K60 视频都会这样**。
    /// 同机实测（同一视频只改关键帧密度，硬件不变）：
    ///
    /// | 关键帧 | 对时耗时（中位 / 最坏） | 被后一次对时取消 |
    /// |---|---|---|
    /// | 每 4.17 秒一个（原文件） | 882 ms / 2545 ms | 29 / 88 次 |
    /// | 每 1 秒一个（重压后） | 345 ms / 1185 ms | 8 / 88 次 |
    ///
    /// 表现就是「切过去画面先不对，然后猛跳一下」，连切时更糟（前一次还没落地就被取消）。
    ///
    /// ## 为什么「不对时」是更好的选择，而不是退而求其次
    ///
    /// 不对时的话，切过去那个 player 从它自己停的地方**立刻**继续播 —— 不解码、不跳帧。
    /// 代价只是各桌面进度不同，转换那 0.4 秒像一次交叉溶解。
    /// 拿 1~2.5 秒的错画面加一次猛跳，去换一个干净的 0.4 秒混合，本来就不划算。
    ///
    /// 所以不写死，而是**实测了再决定**：编码正常的视频（对时几十毫秒）继续对时，
    /// 贵的自动关掉。换视频时重新评估。
    private func noteSeekCost(_ ms: Double) {
        guard !syncDisabled else { return }
        seekCosts.append(ms)
        guard seekCosts.count >= 3 else { return }
        let sorted = seekCosts.sorted()
        let median = sorted[sorted.count / 2]
        if median > Self.seekCostBudgetMs {
            syncDisabled = true
            NSLog("[StarPaper] 对时太贵（中位 %.0f ms > %.0f ms），本视频改为各桌面独立播放。"
                  + "视频关键帧太稀时会这样，重压一份（如 ffmpeg -g 60）可以恢复跨桌面同步",
                  median, Self.seekCostBudgetMs)
        }
        if seekCosts.count > 8 { seekCosts.removeFirst(seekCosts.count - 8) }
    }

    var statusText: String {
        if currentPath.isEmpty { return T("status.noVideo") }
        if settings.isPaused { return T("status.manualPause") }
        if let reason = power.pauseReason(with: settings) {
            return String(format: T("status.pausedFmt"), reason)
        }
        if !isPlaying { return T("status.occluded") }
        // 单窗模式下窗口数就是屏幕数；每桌面一扇时报「屏 × 桌面」更有信息量
        let screenCount = currentPlacement == .singleDesktop
            ? Set(units.compactMap { $0.screenUUID }).count
            : units.count
        if currentPlacement == .singleDesktop && units.count > screenCount {
            return String(format: T("status.playingDesktopsFmt"), screenCount, units.count)
        }
        return String(format: T("status.playingFmt"), units.count)
    }

    func togglePause() {
        settings.isPaused.toggle()
        updatePlayback()
    }
}
