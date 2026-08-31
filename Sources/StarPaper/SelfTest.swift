import Foundation
import AppKit
import CoreMedia

/// 设置层自检。
///
///     STARPAPER_SELFTEST=1 ./build/StarPaper.app/Contents/MacOS/StarPaper
///
/// 存在的理由：「点一下设置就弹回去」这个 bug 只有真的去点界面才发现得了，
/// 但它的根因在设置层（写盘期间被自己的通知重入回读），跟界面无关。
/// 有这个自检就能在不碰鼠标的前提下复现和验证。
enum SelfTest {

    private static var failures = 0

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["STARPAPER_SELFTEST"] == "1"
    }

    /// 自检专用的一次性设置域。⚠️ 见 `AppSettings.useDefaultsSuite`
    private static let testSuiteName = "io.github.starsdaisuki.starpaper.selftest"
    private static var testSuite: UserDefaults!
    /// 开测前真实域的快照，跑完要对得上（自检不许改坏用户的配置）
    private static var realDomainBefore: [String: String] = [:]

    private static let managedKeys = [
        "videoPath", "language", "dim", "muted", "scaleMode", "contrast",
        "playlistShuffle", "volume", "fps",
        "clockEnabled", "clockSize", "clockFontName", "clockAnchor", "clockLang",
        "clockAlign", "clockGlowColorHex", "clockLine2Y", "clockSubScale3",
        "perSpaceMode", "backingLayers", "mediaBookmarks", "hasLaunchedBefore",
    ]

    private static func snapshotRealDomain() -> [String: String] {
        let d = UserDefaults.standard
        var snap: [String: String] = [:]
        for k in managedKeys { snap[k] = d.object(forKey: k).map { String(describing: $0) } ?? "<不存在>" }
        return snap
    }

    static func run() {
        // ⚠️⚠️ 先把设置层整个搬到一次性 suite 再开测。
        // 直接翻真实设置域再还原并不安全：另一个正在运行的实例可能读到临时值，
        // 并在测试还原磁盘后把临时值再次保存回来。
        // ⭐⭐ 反例守卫：自检**不许碰用户的屏幕**。
        //
        // 曾经 `engine = WallpaperEngine()` 排在自检判断之前，于是每跑一次
        // `make test`，用户桌面都会闪一下「内置 demo + 两个时钟 + 忽暗忽亮」——
        // 因为自检随后会翻 clockEnabled、改 dim/contrast，而那些改动落到了真窗上。
        // 一旦有人再把自检挪到建引擎之后，这一条立刻红。
        print("=== 自检不碰屏幕 ===")
        check("自检运行时没有壁纸窗",
              NSApp.windows.contains { $0 is WallpaperWindow }, false)
        print("")

        realDomainBefore = snapshotRealDomain()
        testSuite = UserDefaults(suiteName: testSuiteName)!
        testSuite.removePersistentDomain(forName: testSuiteName)
        AppSettings.shared.useDefaultsSuite(testSuite)

        testMainMenu()

        let s = AppSettings.shared
        clockFormatSelfTest()
        audioRoutingSelfTest()
        audioResumeGateSelfTest()
        stickyOcclusionSelfTest()
        foregroundCoverageSelfTest()
        spaceStrategySelfTest()
        playbackPolicySelfTest()
        playbackResumeSelfTest()
        lockStateSelfTest()
        mediaSelectorSelfTest()
        mediaAccessSelfTest()
        liveSettingsRelaySelfTest()

        print("=== StarPaper 设置层自检 ===")

        // 原值留底，测完还原，不弄脏用户配置
        let backup = (
            language: s.language, dim: s.dim, muted: s.muted,
            scaleMode: s.scaleMode, contrast: s.contrast, playlistShuffle: s.playlistShuffle,
            clockEnabled: s.clockEnabled, clockSize: s.clockSize, clockFontName: s.clockFontName,
            clockAlign: s.clockAlign, clockGlowColorHex: s.clockGlowColorHex,
            clockLine2Y: s.clockLine2Y, clockSubScale3: s.clockSubScale3,
            perSpaceMode: s.perSpaceMode,
            backingLayers: s.backingLayers
        )

        // 一次改多个，专门覆盖「save() 逐键写、写到一半被通知打断」那条路径
        let targetLang: Lang = s.language == .zh ? .en : .zh
        s.language = targetLang
        s.dim = 0.42
        s.muted = !backup.muted
        s.scaleMode = s.scaleMode == .fill ? .fit : .fill
        s.contrast = 1.37
        s.playlistShuffle = !backup.playlistShuffle
        // 时钟三项故意分散在 save() 的三条写路径：布尔组 / 数值组 / 单独 defaults.set
        s.clockEnabled = !backup.clockEnabled
        s.clockSize = 96
        s.clockFontName = backup.clockFontName == "AvenirNext-UltraLight"
            ? "HelveticaNeue-Thin" : "AvenirNext-UltraLight"
        // 后加的四个键分布同样要覆盖两条路径：数值组（逐行坐标 / 末行比例）
        // 与单独 defaults.set（对齐方式 / 光晕色）。少写一处 save() 就是静默丢配置。
        s.clockAlign = backup.clockAlign == .right ? .center : .right
        s.clockGlowColorHex = "90DBFF"
        s.clockLine2Y = 0.371
        s.clockSubScale3 = 0.64
        // 默认 true 的布尔：默认值和「没写进磁盘」读出来都是 true，
        // 少写一处 save() 不会露馅，所以必须翻成 false 再验
        s.perSpaceMode = backup.perSpaceMode == .off ? .on : .off
        // 默认 1 的整数，和 perSpaceWindows 是同一类坑：save() 漏写这个键时
        // integer(forKey:) 读出来是 0，而 load() 会把 0 夹回 1 —— 正好等于默认值，
        // 只比值一样抓不到。所以既要翻成非默认值，也要单独验键存在。
        s.backingLayers = backup.backingLayers == 3 ? 5 : 3

        let expected = (
            language: targetLang, dim: 0.42, muted: !backup.muted,
            scaleMode: s.scaleMode, contrast: 1.37, playlistShuffle: !backup.playlistShuffle,
            clockEnabled: !backup.clockEnabled, clockSize: 96.0, clockFontName: s.clockFontName,
            clockAlign: s.clockAlign, clockGlowColorHex: "90DBFF",
            clockLine2Y: 0.371, clockSubScale3: 0.64,
            perSpaceMode: backup.perSpaceMode == .off ? PerSpaceMode.on : PerSpaceMode.off,
            backingLayers: backup.backingLayers == 3 ? 5 : 3
        )

        // 等 debounce(300ms) → save() → didChangeNotification 全部走完
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let d = testSuite!

            check("内存 language",  s.language,        expected.language)
            check("磁盘 language",  d.string(forKey: "language") ?? "", expected.language.rawValue)
            check("内存 dim",       s.dim,             expected.dim)
            check("磁盘 dim",       d.double(forKey: "dim"), expected.dim)
            check("内存 muted",     s.muted,           expected.muted)
            check("磁盘 muted",     d.bool(forKey: "muted"), expected.muted)
            check("内存 scaleMode", s.scaleMode,       expected.scaleMode)
            check("磁盘 scaleMode", d.string(forKey: "scaleMode") ?? "", expected.scaleMode.rawValue)
            check("内存 contrast",  s.contrast,        expected.contrast)
            check("磁盘 contrast",  d.double(forKey: "contrast"), expected.contrast)
            check("内存 shuffle",   s.playlistShuffle, expected.playlistShuffle)
            check("磁盘 shuffle",   d.bool(forKey: "playlistShuffle"), expected.playlistShuffle)
            check("内存 clockEnabled",  s.clockEnabled,  expected.clockEnabled)
            check("磁盘 clockEnabled",  d.bool(forKey: "clockEnabled"), expected.clockEnabled)
            check("内存 clockSize",     s.clockSize,     expected.clockSize)
            check("磁盘 clockSize",     d.double(forKey: "clockSize"), expected.clockSize)
            check("内存 clockFont",     s.clockFontName, expected.clockFontName)
            check("磁盘 clockFont",     d.string(forKey: "clockFontName") ?? "", expected.clockFontName)
            check("内存 clockAlign",    s.clockAlign,    expected.clockAlign)
            check("磁盘 clockAlign",    d.string(forKey: "clockAlign") ?? "", expected.clockAlign.rawValue)
            check("内存 clockGlowColor", s.clockGlowColorHex, expected.clockGlowColorHex)
            check("磁盘 clockGlowColor", d.string(forKey: "clockGlowColorHex") ?? "", expected.clockGlowColorHex)
            check("内存 clockLine2Y",   s.clockLine2Y,   expected.clockLine2Y)
            check("磁盘 clockLine2Y",   d.double(forKey: "clockLine2Y"), expected.clockLine2Y)
            check("内存 clockSubScale3", s.clockSubScale3, expected.clockSubScale3)
            check("磁盘 clockSubScale3", d.double(forKey: "clockSubScale3"), expected.clockSubScale3)
            check("内存 perSpaceMode", s.perSpaceMode.rawValue, expected.perSpaceMode.rawValue)
            check("磁盘 perSpaceMode", d.string(forKey: "perSpaceMode") ?? "<不存在>",
                  expected.perSpaceMode.rawValue)
            // ⚠️ 默认值是 true 的布尔，只比 bool(forKey:) 抓不到「save() 漏写这个键」——
            // 键不存在时读出来也是 false，和翻成 false 长得一模一样。必须单独验存在性。
            // muted 同理（默认也是 true）。
            check("磁盘 perSpaceMode 键存在", d.object(forKey: "perSpaceMode") != nil, true)
            check("磁盘 muted 键存在", d.object(forKey: "muted") != nil, true)
            check("内存 backingLayers", s.backingLayers, expected.backingLayers)
            check("磁盘 backingLayers", d.integer(forKey: "backingLayers"), expected.backingLayers)
            check("磁盘 backingLayers 键存在", d.object(forKey: "backingLayers") != nil, true)

            // 第二轮：验证外部改动仍然能被吃进来（热更新没被两道闸误杀）
            d.set(0.77, forKey: "dim")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                check("外部改动生效 dim", s.dim, 0.77)

                // 还原
                s.language = backup.language
                s.dim = backup.dim
                s.muted = backup.muted
                s.scaleMode = backup.scaleMode
                s.contrast = backup.contrast
                s.playlistShuffle = backup.playlistShuffle
                s.clockEnabled = backup.clockEnabled
                s.clockSize = backup.clockSize
                s.clockFontName = backup.clockFontName
                s.clockAlign = backup.clockAlign
                s.clockGlowColorHex = backup.clockGlowColorHex
                s.perSpaceMode = backup.perSpaceMode
                s.backingLayers = backup.backingLayers
                s.clockLine2Y = backup.clockLine2Y
                s.clockSubScale3 = backup.clockSubScale3

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    s.save()

                    // ⭐ 最后一关：证明这一整轮自检一个字节都没动过用户的真实设置
                    let after = snapshotRealDomain()
                    let changed = managedKeys.filter { realDomainBefore[$0] != after[$0] }
                    check("没碰用户的真实设置（\(managedKeys.count) 项）",
                          changed.joined(separator: ","), "")
                    AppSettings.shared.useDefaultsSuite(.standard)
                    testSuite.removePersistentDomain(forName: testSuiteName)

                    print(failures == 0 ? "\n✅ 全部通过（\(passed) 项）" : "\n❌ \(failures) 项失败")
                    exit(failures == 0 ? 0 : 1)
                }
            }
        }
    }

    /// ⌘W / ⌘A / ⌘V / ⌘X / ⌘Z 全靠 NSApp.mainMenu 的 key equivalent 派发。
    /// 以前这个 app 只建了状态栏菜单（那个不参与派发），所以设置窗口
    /// **只能用鼠标点左上角红点关**，输入框里也没法全选粘贴。
    private static func testMainMenu() {
        let menu = AppDelegate.makeMainMenu(settingsTarget: nil, settingsAction: nil)
        var items: [NSMenuItem] = []
        func walk(_ m: NSMenu) { for i in m.items { items.append(i); if let sub = i.submenu { walk(sub) } } }
        walk(menu)
        func find(_ key: String, _ mods: NSEvent.ModifierFlags) -> NSMenuItem? {
            items.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == mods }
        }
        let expected: [(String, String, Selector, NSEvent.ModifierFlags)] = [
            ("关闭窗口 ⌘W", "w", #selector(NSWindow.performClose(_:)), [.command]),
            ("全选 ⌘A",   "a", #selector(NSText.selectAll(_:)), [.command]),
            ("拷贝 ⌘C",   "c", #selector(NSText.copy(_:)),      [.command]),
            ("粘贴 ⌘V",   "v", #selector(NSText.paste(_:)),     [.command]),
            ("剪切 ⌘X",   "x", #selector(NSText.cut(_:)),       [.command]),
            ("撤销 ⌘Z",   "z", NSSelectorFromString("undo:"),   [.command]),
            ("重做 ⌘⇧Z",  "z", NSSelectorFromString("redo:"),   [.command, .shift]),
        ]
        for (label, key, sel, mods) in expected {
            let item = find(key, mods)
            check("主菜单 \(label)", item?.action.map(NSStringFromSelector) ?? "缺这一项",
                  NSStringFromSelector(sel))
            check("主菜单 \(label) 走响应链", item?.target == nil, true)
        }
        // ⚠️ 上面那份是默认参数（includeQuit: false）＝「仅菜单栏」形态。
        // 保留原来的保护：没有 Dock 图标时，用户在设置窗口前台按 ⌘Q 只想关窗口。
        check("仅菜单栏形态里没有 ⌘Q", find("q", [.command]) == nil, true)

        // ⭐⭐ 但默认形态（显示 Dock 图标）是另一条分支，上面那份**测不到它**。
        // 2026-08-29 为上架把 LSUIElement 改成 false 之后，这条才是用户实际拿到的菜单：
        // 有 Dock 图标却没有 Quit / About，会命中 Guideline 4 (Design) 的
        // 「missing the required App Menu」。
        let dockMenu = AppDelegate.makeMainMenu(settingsTarget: nil, settingsAction: nil,
                                                quitTarget: nil, quitAction: #selector(NSApplication.terminate(_:)),
                                                includeQuit: true)
        var dockItems: [NSMenuItem] = []
        func walk2(_ m: NSMenu) { for i in m.items { dockItems.append(i); if let sub = i.submenu { walk2(sub) } } }
        walk2(dockMenu)
        func has(_ sel: Selector) -> Bool { dockItems.contains { $0.action == sel } }

        check("Dock 形态有 ⌘Q",
              dockItems.contains { $0.keyEquivalent == "q" && $0.keyEquivalentModifierMask == [.command] },
              true)
        check("Dock 形态有「关于」", has(#selector(NSApplication.orderFrontStandardAboutPanel(_:))), true)
        check("Dock 形态有「隐藏」", has(#selector(NSApplication.hide(_:))), true)
        check("Dock 形态有「隐藏其他」", has(#selector(NSApplication.hideOtherApplications(_:))), true)
        check("Dock 形态有「全部显示」", has(#selector(NSApplication.unhideAllApplications(_:))), true)
        // ⭐ 反例：两种形态只应差「分隔符 + Quit」两项（分隔符也算一个 NSMenuItem），
        //    别在加 ⌘Q 的同时把编辑菜单之类的也改动了
        check("两种形态只差分隔符+⌘Q", dockItems.count - items.count, 2)
    }


    /// 拖滑杆时设置改动到底投不投得进来。
    ///
    /// 这条测的是 `LiveSettingsRelay` 用的调度器。拖动期间 AppKit 把主 runloop 切进
    /// `NSEventTrackingRunLoopMode`，而 Combine 的 `RunLoop.main` 调度器只往 default
    /// 模式投递 —— 换回 `RunLoop.main` 这条就会红（投递次数 0）。
    /// 这个 bug 界面上表现为「拖的时候没反应、松手才跳到位」，不测就只能靠手拖发现。
    private static func liveSettingsRelaySelfTest() {
        print("=== 设置实时投递（拖滑杆那一路）===")
        let s = AppSettings.shared
        let backupDim = s.dim

        var applies = 0
        let relay = LiveSettingsRelay(s) { applies += 1 }

        // CFRunLoopRunInMode 在模式里没有 input source 时会立刻返回（空转），
        // 所以先塞一个什么都不做的 source 把模式撑起来 —— 否则会测出假阴性。
        let tracking = CFRunLoopMode("NSEventTrackingRunLoopMode" as CFString)
        var ctx = CFRunLoopSourceContext()
        ctx.perform = { _ in }
        let keepAlive = CFRunLoopSourceCreate(nil, 0, &ctx)
        CFRunLoopAddSource(CFRunLoopGetMain(), keepAlive, tracking)
        defer { CFRunLoopRemoveSource(CFRunLoopGetMain(), keepAlive, tracking) }

        // 模拟一次拖动：连发 5 帧改动，期间主 runloop 只跑事件跟踪模式
        for i in 1...5 { s.dim = Double(i) / 100.0 }
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline { CFRunLoopRunInMode(tracking, 0.02, true) }

        check("拖动期间投递到了", applies >= 1, true)
        check("同一轮合并成一次", applies, 1)
        check("落地的是最后一帧的值", s.dim, 0.05)

        withExtendedLifetime(relay) {}
        s.dim = backupDim
        // 把这一轮改动排空，免得残留的投递落到后面的用例上
        let settle = Date().addingTimeInterval(0.1)
        while Date() < settle { CFRunLoopRunInMode(.defaultMode, 0.02, true) }
    }

    private static var passed = 0

    private static func check<V: Equatable>(_ name: String, _ actual: V, _ expected: V) {
        // Double 比较留点余量，别被浮点表示坑
        if let a = actual as? Double, let e = expected as? Double {
            if abs(a - e) < 0.0001 { pass(name, a) } else { fail(name, a, e) }
            return
        }
        if actual == expected { pass(name, actual) } else { fail(name, actual, expected) }
    }

    private static func pass(_ name: String, _ v: Any) {
        passed += 1
        print("  ✓ \(name) = \(v)")
    }

    private static func fail(_ name: String, _ actual: Any, _ expected: Any) {
        failures += 1
        print("  ✗ \(name)：期望 \(expected)，实际 \(actual)")
    }

    /// SpaceStrategy 的纯函数自检。
    ///
    /// 要钉的是 2026-08-23 实测确认的那件事：每桌面一扇窗 + 叠衬窗这一整套，
    /// **只在 Reduce Motion 开着时有正作用**，关着的时候是纯副作用。
    /// 所以 `.auto` 档下「Reduce Motion 关着」必须完整退回老行为 ——
    /// 不光放置方式要退，衬窗层数也要退到 1，退一半比不退更糟。
    /// 重建窗口之后「接不接播放进度」的判据自检。
    ///
    /// 来源是 2026-08-29 的真实报告：「开一个新 desktop，壁纸 BGM 会从头开始」，
    /// 追问后又补了一条关键线索「有时候开 App Store 也会触发，但不是 100%」——
    /// 全屏 app 会建一个新 Space（退出时又销毁），桌面数一变就重建，而
    /// `rebuildScreens()` 当时把进度直接丢了。窗口模式打开的 App Store 不建 Space，
    /// 所以才显得时有时无。
    private static func playbackResumeSelfTest() {
        print("=== 重建后接回播放进度 ===")
        let p = "/tmp/a.mp4"
        func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }
        func c(_ label: String, _ prev: String, _ cur: String, _ time: CMTime?, _ want: Bool) {
            check(label, PlaybackResume.shouldRestore(previousPath: prev, currentPath: cur,
                                                      time: time), want)
        }

        c("同片播到 10 秒要接回", p, p, t(10), true)
        c("刚好过 0.25 秒要接回", p, p, t(0.26), true)

        // ⭐⭐ 反例：重建期间轮播正好换了片。不比对路径的话，
        //    会把新片 seek 到旧片的时间点 —— 短片还会直接越界。
        c("换片后不接", p, "/tmp/b.mp4", t(10), false)

        // ⭐ 反例：才起播 0.1 秒，接了跟从头没区别，白花一次 4K seek
        c("刚起播不接", p, p, t(0.1), false)
        c("正好 0.25 秒不接", p, p, t(0.25), false)

        // ⭐ 反例：重建之前压根没在播（选片器还空着）
        c("原本没在播不接", "", p, t(10), false)

        // ⭐ 反例：AVPlayerItem 还没 readyToPlay 时 currentTime() 给的是 invalid
        c("时间无效不接", p, p, .invalid, false)
        // ⭐ 反例：直播流一类的 duration/time 是 indefinite
        // ⚠️ 这条**测不到 `isNumeric`**：indefinite.seconds 是 NaN，而 `NaN > 0.25`
        //    本来就是 false，去掉 isNumeric 它照样绿。留着只当边界记录。
        c("时间不是数不接", p, p, .indefinite, false)
        // ⭐⭐ 这条才真正盖住 `isNumeric`：+∞ 的 seconds 是 +Inf，
        //    而 `+Inf > 0.25` 是 **true** —— 少了 isNumeric 就会拿 +∞ 去 seek。
        c("时间正无穷不接", p, p, .positiveInfinity, false)
        c("没拿到时间不接", p, p, nil, false)
        print("")
    }

    /// 出声延迟门的自检。
    ///
    /// 来源是 2026-08-29 的报告：「在全屏 app 里四指左右划动切桌面，BGM 会响一下」。
    /// 根因是画面和音频共用同一个可见性判据，而那个判据为画面刻意做了提前量。
    private static func audioResumeGateSelfTest() {
        print("=== 出声落定门 ===")

        func sample(visible: Bool, onDesktop: Bool?, covers: Bool = false,
                    now: TimeInterval, enabled: Bool = true) -> AudioResumeGate.Sample {
            AudioResumeGate.Sample(isVisible: visible, enabled: enabled,
                                   currentSpaceIsDesktop: onDesktop,
                                   frontmostCoversScreen: covers, now: now)
        }

        // ⭐⭐ 本轮真机 bug（2026-08-30，用户报告）：
        //     两个全屏页面之间横划，**拖到一半悬停不动，BGM 一直响到松手**。
        //     旧实现在这里必红：它把「露出 0.5 秒」当成放行条件，
        //     而悬停可以是任意久 —— 任何固定时长都会被跨过去。
        var hover = AudioResumeGate.State()
        hover.observe(sample(visible: false, onDesktop: false, now: 100))     // 全屏 A，壁纸被盖住
        hover.observe(sample(visible: true, onDesktop: false, now: 100.1))    // 开始拖，壁纸提前露出
        check("全屏→全屏 0.9s 处静音", hover.shouldSilence(now: 101.0), true)
        check("悬停 5 秒仍静音", hover.shouldSilence(now: 105.1), true)
        check("悬停 60 秒仍静音", hover.shouldSilence(now: 160.1), true)
        check("不在桌面时不存在任何 recheck 期限", hover.nextRecheck == nil, true)

        // ⭐ 门必须能**重新关上**。旧实现放行后 pendingSince 不清，
        //   `shouldSilence` 永远返回 false —— 这正是「响一下」变成「一直响」的机制。
        var reclose = AudioResumeGate.State()
        reclose.observe(sample(visible: false, onDesktop: true, now: 200))
        reclose.observe(sample(visible: true, onDesktop: true, now: 200.1))
        check("回到桌面稳定期内先静音", reclose.shouldSilence(now: 200.5), true)
        check("回到桌面稳定期后出声", reclose.shouldSilence(now: 200.7), false)
        reclose.observe(sample(visible: true, onDesktop: false, now: 200.8))  // 又拖进全屏转换
        check("已经出声后仍能重新静音", reclose.shouldSilence(now: 200.9), true)

        // 真正落回桌面：落定通知本身已经等过收尾，不必再等一次稳定期。
        var settle = AudioResumeGate.State()
        settle.observe(sample(visible: false, onDesktop: false, now: 300))
        settle.observe(sample(visible: true, onDesktop: false, now: 300.1))
        check("落定前静音", settle.shouldSilence(now: 300.4), true)
        settle.noteSettled(sample(visible: true, onDesktop: true, now: 300.5))
        check("Space 落定在桌面上立即出声", settle.shouldSilence(now: 300.5), false)

        // 同一 Space 里关掉遮挡窗口不会发 activeSpaceDidChange，靠稳定期兜底。
        var sameSpace = AudioResumeGate.State()
        sameSpace.observe(sample(visible: false, onDesktop: true, now: 400))
        sameSpace.observe(sample(visible: true, onDesktop: true, now: 400.1))
        check("同页露出稳定期内静音", sameSpace.shouldSilence(now: 400.59), true)
        check("同页露出稳定期后恢复", sameSpace.shouldSilence(now: 400.61), false)
        check("在桌面等稳定期时有 recheck 期限",
              sameSpace.nextRecheck.map { abs($0 - 400.6) < 0.001 } ?? false, true)

        // 用户把「遮挡暂停」关掉 = 明确要求一直有声，不许装门。
        var disabled = AudioResumeGate.State()
        disabled.observe(sample(visible: false, onDesktop: false, now: 500, enabled: false))
        disabled.observe(sample(visible: true, onDesktop: false, now: 500.1, enabled: false))
        check("遮挡暂停关闭时不装门", disabled.shouldSilence(now: 500.1), false)

        // MAS 构建裁掉私有 API：onDesktop 判不出，退到「前台是否盖满整屏」。
        var fallback = AudioResumeGate.State()
        fallback.observe(sample(visible: false, onDesktop: nil, covers: true, now: 600))
        fallback.observe(sample(visible: true, onDesktop: nil, covers: true, now: 600.1))
        check("判不出 Space 时前台盖满屏仍静音", fallback.shouldSilence(now: 630), true)
        fallback.observe(sample(visible: true, onDesktop: nil, covers: false, now: 630.1))
        check("判不出 Space 且前台没盖满屏则走稳定期", fallback.shouldSilence(now: 630.9), false)
        print("")
    }

    private static func stickyOcclusionSelfTest() {
        print("=== 单扇跟随窗的假遮挡 ===")
        // ⭐⭐ 2026-08-31 真机：相邻两个普通桌面之间按一次 ⌃→，sticky 壁纸窗被标成
        //     「不可见」并卡住 16.3 秒（整扇被换成系统静态壁纸快照）。旧实现直接信它 →
        //     player 暂停 + 音频门关闭 → 每切一次桌面 BGM 断一下。
        check("桌面上没窗盖满屏时，系统说的遮挡是假的",
              SpaceStrategy.stickyOccluded(rawOccluded: true, currentSpaceIsDesktop: true,
                                           frontmostCoversScreen: false), false)
        check("桌面上真被盖满屏才算遮挡",
              SpaceStrategy.stickyOccluded(rawOccluded: true, currentSpaceIsDesktop: true,
                                           frontmostCoversScreen: true), true)
        check("人在全屏 app 的 Space 里，遮挡是真的",
              SpaceStrategy.stickyOccluded(rawOccluded: true, currentSpaceIsDesktop: false,
                                           frontmostCoversScreen: false), true)
        check("判不出 Space 时退回系统原值（MAS 构建）",
              SpaceStrategy.stickyOccluded(rawOccluded: true, currentSpaceIsDesktop: nil,
                                           frontmostCoversScreen: false), true)
        check("系统说看得见就直接看得见，不做二次确认",
              SpaceStrategy.stickyOccluded(rawOccluded: false, currentSpaceIsDesktop: false,
                                           frontmostCoversScreen: true), false)
        print("")
    }

    private static func foregroundCoverageSelfTest() {
        print("=== 前台覆盖判定（兜底用）===")
        let display = CGSize(width: 1512, height: 982)

        // ⭐⭐ 2026-08-30 真机实测的三个全屏窗尺寸。旧判据要求 ±2pt 内等于屏幕尺寸，
        //     这三条**全部返回 false** —— 于是音频门每次都走短兜底放行。
        //     旧自检里还有一条「1512×907 不算全屏」是绿的，而 907 正是 Ghostty
        //     全屏窗的真实高度：那条测试把 bug 断言成了正确行为。
        check("真实全屏窗 Finder 1512×945", ForegroundCoverage.covers(
            window: CGSize(width: 1512, height: 945), display: display), true)
        check("真实全屏窗 Ghostty 1512×907", ForegroundCoverage.covers(
            window: CGSize(width: 1512, height: 907), display: display), true)
        check("真实全屏窗 Chrome 1512×857", ForegroundCoverage.covers(
            window: CGSize(width: 1512, height: 857), display: display), true)
        check("整屏窗仍然命中", ForegroundCoverage.covers(
            window: display, display: display), true)
        check("窄窗不算覆盖", ForegroundCoverage.covers(
            window: CGSize(width: 900, height: 982), display: display), false)
        check("矮窗不算覆盖", ForegroundCoverage.covers(
            window: CGSize(width: 1512, height: 600), display: display), false)
        print("")
    }

    /// 高风险核心的组合表：遮挡暂停 × 每桌面模式 × 静音 × 单/四屏。
    /// `.auto` 在播放决策前已收敛成两种 placement 之一；这里仍从设置入口
    /// 跑满 24 行，同时由 `spaceStrategySelfTest` 覆盖 auto 的 RM 开/关两条路。
    private static func playbackPolicySelfTest() {
        print("=== 播放策略 24 组合 ===")
        let modes: [PerSpaceMode] = [.off, .auto, .on]
        var rows = 0
        for mode in modes {
            let resolved = SpaceStrategy.resolve(
                mode: mode, reduceMotion: mode != .off, bridgeAvailable: true,
                requestedLayers: 3, maxLayers: 6)
            for pause in [false, true] {
                for muted in [false, true] {
                    for screenCount in [1, 4] {
                        rows += 1
                        let visibleUnits = (0..<screenCount).map { i in
                            PlaybackUnitState(screenID: "screen-\(i)", isOnActiveSpace: true,
                                              isOccluded: false, isAudioScreen: i == 0,
                                              visibleSince: nil)
                        }
                        let shown = PlaybackPolicy.decide(
                            units: visibleUnits, placement: resolved.placement,
                            pauseWhenOccluded: pause, muted: muted, globalOK: true,
                            hasMedia: true, neverPause: false, now: 100,
                            basePlayerLimit: WallpaperEngine.maxConcurrentPlayers)

                        // followsUser 下 isOnActiveSpace 恒 true，这正是今天旧 bug 的形状。
                        let coveredUnits = (0..<screenCount).map { i in
                            PlaybackUnitState(
                                screenID: "screen-\(i)",
                                isOnActiveSpace: resolved.placement == .followsUser,
                                isOccluded: true, isAudioScreen: i == 0, visibleSince: nil)
                        }
                        let covered = PlaybackPolicy.decide(
                            units: coveredUnits, placement: resolved.placement,
                            pauseWhenOccluded: pause, muted: muted, globalOK: true,
                            hasMedia: true, neverPause: false, now: 101,
                            basePlayerLimit: WallpaperEngine.maxConcurrentPlayers)
                        let coveredWant = (!pause && !muted)
                            ? [true] + Array(repeating: false, count: screenCount - 1)
                            : Array(repeating: false, count: screenCount)
                        let ok = shown.visual == Array(repeating: true, count: screenCount)
                            && shown.play == Array(repeating: true, count: screenCount)
                            && shown.clockActive == Array(repeating: true, count: screenCount)
                            && !covered.anyDesktopVisible
                            && covered.play == coveredWant
                        check("\(mode.rawValue) 遮挡\(pause ? "开" : "关") 静音\(muted ? "开" : "关") \(screenCount)屏", ok, true)
                    }
                }
            }
        }
        check("组合行数", rows, 24)

        // ⭐⭐ 四屏回归：四扇当前窗 + 最近两扇转换窗都得保留，
        // 第七扇旧路过窗才该被限流。旧的全局固定上限 3 会先冻掉一块真屏幕。
        let crowded = (0..<7).map { i in
            PlaybackUnitState(screenID: "screen-\(min(i, 3))",
                              isOnActiveSpace: i < 4, isOccluded: false,
                              isAudioScreen: i == 0, visibleSince: Double(i))
        }
        let limited = PlaybackPolicy.decide(
            units: crowded, placement: .singleDesktop, pauseWhenOccluded: true,
            muted: true, globalOK: true, hasMedia: true, neverPause: false,
            now: 100, basePlayerLimit: WallpaperEngine.maxConcurrentPlayers)
        check("四屏并发上限 = 四当前 + 两转换", limited.playerLimit, 6)
        check("四屏不冻任何当前窗", Array(limited.visual.prefix(4)), [true, true, true, true])
        check("只裁掉最旧路过窗", limited.visual, [true, true, true, true, false, true, true])
        print("")
    }

    private static func spaceStrategySelfTest() {
        print("=== SpaceStrategy 自检 ===")
        func c(_ label: String, _ mode: PerSpaceMode, _ rm: Bool, _ bridge: Bool,
               _ layers: Int, _ wantPlacement: String, _ wantLayers: Int) {
            let got = SpaceStrategy.resolve(mode: mode, reduceMotion: rm, bridgeAvailable: bridge,
                                            requestedLayers: layers, maxLayers: 6)
            let name = got.placement == .singleDesktop ? "每桌面一扇" : "单扇跟随"
            check("\(label) 放置", name, wantPlacement)
            check("\(label) 层数", got.layers, wantLayers)
        }
        c("自动+RM开",       .auto, true,  true, 3, "每桌面一扇", 3)
        // ⭐ 本次的核心诉求：RM 关着就该完整退回老行为，衬窗也要退到 1
        c("自动+RM关",       .auto, false, true, 3, "单扇跟随",   1)
        c("一直开+RM关",     .on,   false, true, 3, "每桌面一扇", 3)   // 手动强制，尊重设置
        c("一直关+RM开",     .off,  true,  true, 3, "单扇跟随",   1)   // 手动强制，尊重设置
        // ⭐⭐ 「看不看得见」必须分模式算 —— 2026-08-29 的真实 bug：
        //    把「每桌面一扇壁纸窗」设成「一直关」之后，「被窗口遮挡时暂停」100% 失效。
        //    根因：sticky 窗的 isOnActiveSpace 恒 true，旧写法 `isOnActiveSpace || !isOccluded`
        //    于是恒 true → anyDesktopVisible 恒 true → 出声那份的 occludedStop 恒 false。
        func seen(_ label: String, _ p: SpacePlacement, _ onActive: Bool, _ occluded: Bool, _ want: Bool) {
            check(label, SpaceStrategy.isSeen(placement: p, isOnActiveSpace: onActive,
                                              isOccluded: occluded), want)
        }
        // ⭐ 这一条就是那个 bug 本身：单窗模式 + 被遮挡 → 必须判成「看不见」
        seen("单窗被遮挡要算看不见", .followsUser, true, true, false)
        seen("单窗没遮挡算看得见", .followsUser, true, false, true)
        // 每桌面模式要保留那 0.93 秒的提前量，否则切桌面会先卡一下
        seen("每桌面·在当前桌面即使被遮挡也算看得见", .singleDesktop, true, true, true)
        seen("每桌面·转换中虽不在当前桌面但没遮挡", .singleDesktop, false, false, true)
        seen("每桌面·既不在当前桌面又被遮挡", .singleDesktop, false, true, false)

        // ⭐ 反例：私有 API 没了 → 无论怎么设都只能退回老行为，宁可露也不能没壁纸
        c("私有API缺失",     .on,   true,  false, 3, "单扇跟随",  1)
        // ⭐ 反例：层数越界要夹紧，不能让手改 defaults 的人把窗口开爆
        c("层数超上限",      .on,   true,  true, 99, "每桌面一扇", 6)
        c("层数为0",         .on,   true,  true, 0,  "每桌面一扇", 1)

        // ⭐⭐ 回退路径的收敛性（2026-08-27 的爆栈 bug）。
        // 私有 API 建窗失败时，引擎会把 fallbackStrategy 的结果整对写回；
        // 只要下面第一条成立，applySettings() 就不会再触发一次 rebuildScreens()。
        let fb = SpaceStrategy.resolve(mode: .on, reduceMotion: true, bridgeAvailable: false,
                                       requestedLayers: 3, maxLayers: 6)
        check("回退后不再重建", SpaceStrategy.needsRebuild(desired: fb, current: fb), false)
        // ⭐ 反例：旧写法只退 placement、层数留在 3 —— 这一对必须被判成「还要重建」，
        //    也就是当年那条 rebuildScreens ⇄ applySettings 的无限递归。
        check("只退放置会无限重建",
              SpaceStrategy.needsRebuild(desired: fb, current: (.followsUser, 3)), true)
        print("")
    }

    /// 锁屏 / 切用户两个来源的自检。
    ///
    /// 来源是 2026-08-27 的真实回归：有人把 `com.apple.screenIsLocked` 换成了
    /// `NSWorkspace.sessionDidResignActive`，但后者只在**快速用户切换**时发，
    /// 锁屏根本不触发 —— 界面上「锁屏时暂停」那个开关就此变成死开关。
    /// 两条都收之后，又多出一个坑：它们不能共用一个 Bool（见下面第三条反例）。
    private static func lockStateSelfTest() {
        print("=== 锁屏状态自检 ===")
        func after(_ events: [PowerMonitor.LockState.Event]) -> Bool {
            var st = PowerMonitor.LockState()
            for e in events { st.apply(e) }
            return st.isLocked
        }
        check("什么都没发生", after([]), false)
        check("锁屏", after([.screenLocked]), true)
        check("锁屏再解锁", after([.screenLocked, .screenUnlocked]), false)
        check("切走用户", after([.sessionResigned]), true)
        check("切走再切回", after([.sessionResigned, .sessionActivated]), false)
        // ⭐⭐ 反例：锁着屏被切到别的用户、再切回来 —— 屏幕还锁着，不能恢复播放。
        //    共用一个 Bool 的写法在这里会错判成「没锁」。
        check("锁屏期间切用户往返",
              after([.screenLocked, .sessionResigned, .sessionActivated]), true)
        // ⭐ 反例：反过来也一样 —— 切走期间收到解锁事件，不能把「会话不在」抹掉
        check("切走期间收到解锁",
              after([.sessionResigned, .screenUnlocked]), true)
        print("")
    }

    /// 视频库「下一个是谁」的纯函数自检。
    ///
    /// 这一段以前是 MediaSelector 内部的一个 index，看不见也测不着，
    /// 于是「当前视频不在库里」这种情况一直是靠猜的，而它正好有个很容易写错的
    /// 落点：起点是第 3 个，按一次「下一个」却跳去第 2 个。
    private static func mediaSelectorSelfTest() {
        print("=== 视频库切换自检 ===")
        let list = ["a.mp4", "b.mp4", "c.mp4", "d.mp4"]

        func choose(_ schedule: Bool = false, _ primary: String = "day.mp4",
                    _ fallback: String = "night.mp4", _ selected: String = "picked.mp4",
                    _ library: [String] = ["library.mp4"], _ builtIn: String = "demo.mp4",
                    usable: Set<String>) -> String {
            MediaSelector.choosePath(
                scheduleActive: schedule, schedulePrimary: primary, scheduleFallback: fallback,
                selected: selected, library: library, builtIn: builtIn,
                isUsable: usable.contains)
        }
        // 内置 demo 只能做最后兜底，不能抢老用户的选择。
        check("日程主视频优先", choose(true, usable: ["day.mp4", "picked.mp4", "demo.mp4"]), "day.mp4")
        check("日程主视频失效退备用", choose(true, usable: ["night.mp4", "picked.mp4", "demo.mp4"]), "night.mp4")
        check("用户已选视频不被 demo 覆盖", choose(usable: ["picked.mp4", "demo.mp4"]), "picked.mp4")
        check("当前视频失效退视频库", choose(usable: ["library.mp4", "demo.mp4"]), "library.mp4")
        check("空配置才用内置 demo", choose(usable: ["demo.mp4"]), "demo.mp4")
        check("所有来源都失效返回空", choose(usable: []), "")

        check("顺序 a→b", MediaSelector.nextIndex(after: "a.mp4", in: list), 1)
        check("顺序 c→d", MediaSelector.nextIndex(after: "c.mp4", in: list), 3)
        // ⭐ 反例：最后一个要绕回开头，不是停住
        check("顺序 d→a", MediaSelector.nextIndex(after: "d.mp4", in: list), 0)
        // ⭐ 反例：当前那个根本不在库里（刚从别处挑了个视频）→ 从头开始，不是跳去第 2 个
        check("当前不在库里", MediaSelector.nextIndex(after: "外面的.mp4", in: list), 0)
        // ⭐ 反例：空库不能崩，也不能返回越界下标
        check("空库", MediaSelector.nextIndex(after: "a.mp4", in: []), 0)

        // 随机：一轮之内不许重复，也不许第一步就回到当前这个
        var bag: [String] = []
        var round: [String] = []
        var current = "a.mp4"
        for _ in 0..<3 {
            let next = MediaSelector.shuffleNext(after: current, in: list, bag: &bag)
            round.append(next)
            current = next
        }
        check("随机一轮不重复", Set(round).count, round.count)
        check("随机都在库里", round.allSatisfy(list.contains), true)
        // ⭐ 反例：重洗时要排掉当前那个，不然新一轮开头经常原地不动
        check("随机不从当前那个开始", round.first != "a.mp4", true)
        // ⭐ 反例：库里就一个 → 只能是它，且不能死循环
        var solo: [String] = []
        check("库里只有一个", MediaSelector.shuffleNext(after: "a.mp4", in: ["a.mp4"], bag: &solo), "a.mp4")
        // ⭐ 反例：袋子里留着已经被移出库的旧货，不该被抽中
        var stale = ["已删除.mp4"]
        let picked = MediaSelector.shuffleNext(after: "a.mp4", in: list, bag: &stale)
        check("袋里的旧货被清掉", list.contains(picked), true)
        print("")
    }

    private static func mediaAccessSelfTest() {
        print("=== 媒体授权自检 ===")
        let demoPath = BuiltInMedia.defaultVideoPath
        let demoLease = MediaAccess.acquire(path: demoPath)
        check("内置 demo 已进 bundle", (demoPath as NSString).lastPathComponent,
              "blackhole-demo.mp4")
        check("内置 demo 不需 bookmark 也可读", demoLease.map {
            FileManager.default.isReadableFile(atPath: $0.url.path)
        } ?? false, true)

        // 「内置示例」按钮：能选中它，但**不能**混进视频库 ——
        // 它在 bundle 里，换版本或挪 app 路径就变，留在库里就是一条死项。
        let s0 = AppSettings.shared
        let libraryBefore = s0.playlist
        s0.playBuiltInDemo()
        check("内置示例能被选中", (s0.videoPath as NSString).lastPathComponent,
              "blackhole-demo.mp4")
        check("内置示例不进视频库", s0.playlist, libraryBefore)

        // 启动时弹不弹设置窗
        func popup(_ launched: Bool, _ video: Bool, _ lib: Bool, _ nothing: Bool = false) -> Bool {
            AppDelegate.shouldOpenSettingsOnLaunch(
                hasLaunchedBefore: launched, hasSavedVideo: video,
                hasLibrary: lib, nothingPlaying: nothing)
        }
        check("全新用户首启要弹", popup(false, false, false), true)
        // ⭐ 反例：hasLaunchedBefore 是新加的键，老用户升上来一律 false，不能平白弹
        check("老用户有选好的视频不弹", popup(false, true, false), false)
        check("老用户有视频库不弹", popup(false, false, true), false)
        check("跑过一次就不再弹", popup(true, false, false), false)
        // ⭐ 反例：连内置 demo 都读不到时屏幕上什么都没有，无论如何都要给入口
        check("什么都没在播一定弹", popup(true, true, true, true), true)

        // 首启标记：首启把设置窗口拍脸上全靠它（见 AppDelegate）。
        // ⭐ 反例：它一旦不落盘，每次启动都会弹设置窗，比不弹更烦人。
        check("首启标记默认为假", s0.hasLaunchedBefore, false)
        s0.hasLaunchedBefore = true
        check("首启标记读得回来", s0.hasLaunchedBefore, true)
        check("首启标记落到磁盘", testSuite.bool(forKey: "hasLaunchedBefore"), true)

        guard let executable = Bundle.main.executableURL else {
            fail("找到自己的可执行文件", "nil", "存在")
            return
        }
        let path = MediaAccess.remember(executable)
        let lease = MediaAccess.acquire(path: path)
        check("bookmark 可重新解析", lease?.url.standardizedFileURL.path ?? "", path)
        check("bookmark 解析后可读", lease.map {
            FileManager.default.isReadableFile(atPath: $0.url.path)
        } ?? false, true)
        print("")
    }

    /// AudioRouting 的纯函数自检。
    ///
    /// 来源是 2026-08-23 的真实 bug：切桌面时 `isAudioScreen` 挪了，但没人把它落到
    /// `player.isMuted` 上，于是**只有一个桌面有声音**。落地那一步在 `WallpaperEngine`
    /// 里（离线复现不了一次真的 Space 切换），但「该谁出声」这条规则可以在这里钉死 ——
    /// 尤其是「被选中的那扇没在播」这个反例，它正是切桌面那 0.9 秒里的真实状态。
    private static func audioRoutingSelfTest() {
        print("=== AudioRouting 自检 ===")
        func c(_ label: String, _ designated: [Bool], _ live: [Bool], _ main: [Bool], _ want: Int?) {
            let got = AudioRouting.speakerIndex(designated: designated, live: live, onMainScreen: main)
            check(label, got.map(String.init) ?? "nil", want.map(String.init) ?? "nil")
        }
        let T = true, F = false

        // 常态：选中的那扇在播，就是它
        c("选中且在播",        [F, T, F], [T, T, T], [T, T, T], 1)
        // ⭐ 本次 bug 的形状：人已经在桌面 2 了，选中的还是桌面 0，而桌面 0 已经停了
        c("反例:选中的没在播",  [T, F, F], [F, F, T], [T, T, T], 2)
        // ⭐⭐ 反例（这条是踩出来的）：冷启动时 play() 刚调完、item 还没 ready，
        //     一扇「在播」的都没有。这时必须把出声资格先给选中的那一扇 ——
        //     判成 nil 的话之后没有任何事件会再触发一次 updatePlayback()，整个 app 全程哑。
        c("反例:还没起播",      [F, T, F], [F, F, F], [T, T, T], 1)
        // ⭐ 反例：既没在播也没人被选中 → 退到主屏那一扇，别返回 nil
        c("反例:全停且没选中",  [F, F, F], [F, F, F], [F, T, F], 1)
        // ⭐ 反例：谁都没被选中时（重建窗口的空窗期）优先主屏，别把声音留在副屏
        c("反例:没人被选中",    [F, F, F], [T, T, T], [F, T, F], 1)
        // 多屏：选中的优先级高于「是不是主屏」—— 选中的在播就用它
        c("选中优先于主屏",     [T, F],    [T, T],    [F, T],    0)
        // ⭐ 反例：主屏那扇停着，就退到在播的第一扇，不能因为「不是主屏」就全静音
        c("反例:主屏停了",      [F, F],    [F, T],    [T, F],    1)
        // ⭐ 反例：一个窗口都没有（引擎刚起来）→ nil，不能崩
        c("反例:没有窗口",      [],        [],        [],        nil)
        print("")
    }

    /// ClockFormat 的纯函数自检。含反例 —— 最要命的失败模式是长 token 被短 token 抢先
    /// 吃掉（`yyyy` 拆成两个 `yy`），只测正例是看不出来的。
    private static func clockFormatSelfTest() {
        print("=== ClockFormat 自检 ===")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ se: Int = 0) -> Date {
            cal.date(from: DateComponents(year: y, month: mo, day: d,
                                          hour: h, minute: mi, second: se))!
        }
        // 2026-08-22 是星期六
        let t0 = at(2026, 8, 22, 0, 41, 7)
        let t1 = at(2026, 8, 22, 13, 5)
        let t2 = at(2026, 8, 22, 20, 0)

        func c(_ label: String, _ fmt: String, _ date: Date, _ want: String, zh: Bool = true) {
            let got = ClockFormat.render(fmt, at: date, calendar: cal, zh: zh)
            check("\(label)  \(fmt.isEmpty ? "(空)" : fmt)", got, want)
        }

        c("时分",       "HH:mm",       t0, "00:41")
        c("月日",       "MM|dd",       t0, "08|22")
        c("四位年",     "yyyy-MM-dd",  t0, "2026-08-22")
        c("两位年",     "yy",          t0, "26")
        c("秒",         "HH:mm:ss",    t0, "00:41:07")
        c("12小时制",   "hh:mm",       t1, "1:05")
        c("24小时制",   "HH:mm",       t1, "13:05")
        c("星期",       "[W]",         t0, "周六")
        c("星期(英)",   "[W]",         t0, "Sat", zh: false)
        c("时段-凌晨",  "[P]",         t0, "凌晨")
        c("时段-下午",  "[P]",         t1, "下午")
        c("时段-晚上",  "[P]",         t2, "晚上")
        c("时段(英)",   "[P]",         t2, "Evening", zh: false)
        c("组合",       "MM|dd [W]",   t0, "08|22 周六")
        // ⭐ 反例 1：长 token 优先 —— 写错顺序时这里会变成 "2626"
        c("反例:yyyy不拆", "yyyy",     t0, "2026")
        // ⭐ 反例 2：不含 token 的文本必须原样搬运，一个字符不少
        //（"there" 里的 h 是单个，不构成 hh token）
        c("反例:纯文本", "hi there!",  t0, "hi there!")
        // ⭐ 反例 3：相邻 token 之间不能互相污染
        c("反例:token紧邻", "HHmm",    t0, "0041")
        // ⭐ 反例 4：普通字母只要拼出 token 就会被替换，这是规则不是 bug —— 钉住它
        c("反例:文本含token", "summer", t0, "su41er")
        // ⭐ 反例 5：空格式返回空串，不能崩也不能塞默认值
        c("反例:空",     "",           t0, "")
        print("")
    }
}
