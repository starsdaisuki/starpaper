import Foundation
import AVFoundation
import Combine

/// 缩放方式
enum ScaleMode: String, CaseIterable, Identifiable {
    case fill      // 填充：铺满屏幕，超出部分裁掉（唯一支持自定义裁剪的模式）
    case fit       // 适应：完整显示，两侧留黑边
    case stretch   // 拉伸：铺满但会变形

    var id: String { rawValue }
    var localizedLabel: String {
        switch self {
        case .fill: return T("scale.fill")
        case .fit: return T("scale.fit")
        case .stretch: return T("scale.stretch")
        }
    }
}

/// 时钟里 `[W]` / `[P]` 用哪种语言。
///
/// 和界面语言分开，是因为「界面英文 + 时钟中文」是真实存在的搭配 ——
/// 系统语言是英文但用户本身是中文使用者时就会撞上。壁纸原作也提供了独立的时钟语言设置。
enum ClockLang: String, CaseIterable, Identifiable {
    case auto, zh, en
    var id: String { rawValue }
    var localizedLabel: String {
        switch self {
        case .auto: return T("clockLang.auto")
        case .zh: return "中文"
        case .en: return "English"
        }
    }
}

/// 桌面时钟的锚点挂在哪儿
enum ClockAnchor: String, CaseIterable, Identifiable {
    /// 相对屏幕：时钟固定在屏幕上，画面怎么裁剪都不动（像一层 UI）
    case screen
    /// 相对画面：时钟跟着视频一起被裁剪 / 缩放 / 平移，
    /// 于是它与画面元素的相对位置在任何屏幕比例下都保持一致
    case video

    var id: String { rawValue }
    var localizedLabel: String {
        switch self {
        case .screen: return T("clockAnchor.screen")
        case .video: return T("clockAnchor.video")
        }
    }
}

/// 时钟每行相对锚点的水平对齐方式。
///
/// 锚点是「基线 × 对齐边」那一个点：左对齐时锚点在行首，右对齐时在行尾，居中时在行心。
/// 有了它，锚点在不同行长下才是稳定的 —— 右对齐的时钟从 `09:59` 跳到 `10:00`
/// 不会因为字宽变化而整体左右抖动。
enum ClockAlign: String, CaseIterable, Identifiable {
    case left
    case center
    case right

    var id: String { rawValue }
    var localizedLabel: String {
        switch self {
        case .left: return T("clockAlign.left")
        case .center: return T("clockAlign.center")
        case .right: return T("clockAlign.right")
        }
    }
}

/// 壁纸窗口相对桌面图标的层级
/// 「每个桌面单独一扇壁纸窗」的三档开关。见 `AppSettings.perSpaceMode`。
enum PerSpaceMode: String, CaseIterable, Identifiable {
    case auto   // 跟着系统的「减弱动态效果」走：开着才用每桌面一扇（默认）
    case on     // 一直用每桌面一扇
    case off    // 一直用老的单扇 sticky 窗

    var id: String { rawValue }
    var localizedLabel: String {
        switch self {
        case .auto: return T("perSpace.auto")
        case .on:   return T("perSpace.on")
        case .off:  return T("perSpace.off")
        }
    }
}

enum IconLayerMode: String, CaseIterable, Identifiable {
    case belowIcons   // 壁纸在图标下方 → 桌面图标正常可见（默认）
    case aboveIcons   // 壁纸盖住图标 → 纯展示面

    var id: String { rawValue }
    var localizedLabel: String {
        switch self {
        case .belowIcons: return T("iconLayer.below")
        case .aboveIcons: return T("iconLayer.above")
        }
    }
}

/// 播放列表切到下一个的时机
enum AdvanceMode: String, CaseIterable, Identifiable {
    case onEnd      // 播完一遍就切
    case interval   // 定时切（期间正常循环）

    var id: String { rawValue }
    var localizedLabel: String {
        switch self {
        case .onEnd: return T("playlist.onEnd")
        case .interval: return T("playlist.interval")
        }
    }
}

/// 能绑全局快捷键的动作
enum HotkeyAction: String, CaseIterable, Identifiable {
    case togglePause, next, toggleMute, openSettings

    var id: String { rawValue }
    var localizedLabel: String {
        switch self {
        case .togglePause: return T("hotkey.togglePause")
        case .next: return T("hotkey.next")
        case .toggleMute: return T("hotkey.toggleMute")
        case .openSettings: return T("hotkey.openSettings")
        }
    }
}

/// 一个快捷键组合。modifiers 存 NSEvent.ModifierFlags 的 rawValue。
struct HotkeySpec: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt
}

/// 全局设置。写进 UserDefaults，改动通过 @Published 推给 SwiftUI 和播放引擎。
///
/// ⚠️ 类名不能叫 Settings —— SwiftUI 有个同名的 `Settings<Content>` scene，
/// 同一文件 import SwiftUI 之后会解析到它。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// 每桌面最多叠几扇窗。3 是实测最优，留到 6 是因为最优值和视频本身有关
    /// （衬窗比主窗暗多少取决于画面），让人能自己试（见 `backingLayers`）。
    static let maxBackingLayers = 6

    /// ⚠️ 是 var 不是 let —— 自检要把整个设置层切到一次性 suite，
    /// 绝对不能碰用户的真实设置域。见 `useDefaultsSuite(_:)`。
    private var defaults = UserDefaults.standard
    private var defaultsObserver: NSObjectProtocol?
    private var loading = true
    /// 正在写盘。写盘过程中 UserDefaults 会逐键发通知，必须挡住重入的 load()。
    private var isSaving = false
    /// 内存里有还没写盘的改动。这段时间内不能从磁盘回读 —— 磁盘上是旧值。
    private var hasUnsavedChanges = false
    /// 路径只用作用户可读的稳定 key；真正的沙盒授权存在 bookmark data 里。
    private var mediaBookmarks: [String: Data] = [:]

    // MARK: 内容
    @Published var videoPath: String = ""
    @Published var language: Lang = .zh

    // MARK: 构图
    @Published var scaleMode: ScaleMode = .fill
    @Published var iconLayer: IconLayerMode = .belowIcons
    /// 裁剪焦点（0 = 最左/最上，0.5 = 居中，1 = 最右/最下）
    @Published var focusX: Double = 0.5
    @Published var focusY: Double = 0.5
    /// 1.0 = 刚好铺满；>1 进一步放大、裁掉更多
    @Published var zoom: Double = 1.0

    // MARK: 影调
    @Published var exposure: Double = 0.0      // CIExposureAdjust inputEV, -2 ... 2
    @Published var brightness: Double = 0.0    // CIColorControls, -1 ... 1
    @Published var contrast: Double = 1.0      // CIColorControls, 0.25 ... 4
    @Published var highlights: Double = 1.0    // CIHighlightShadowAdjust, 0 ... 1（越小高光压得越狠）
    @Published var shadows: Double = 0.0       // CIHighlightShadowAdjust, -1 ... 1（越大暗部提得越亮）
    @Published var gamma: Double = 1.0         // CIGammaAdjust, 0.25 ... 3

    // MARK: 色彩
    @Published var saturation: Double = 1.0    // CIColorControls, 0 ... 2
    @Published var vibrance: Double = 0.0      // CIVibrance, -1 ... 1
    @Published var temperature: Double = 6500  // CITemperatureAndTint, 2000 ... 11000
    @Published var tint: Double = 0.0          // CITemperatureAndTint, -100 ... 100

    // MARK: 效果
    @Published var blurRadius: Double = 0.0    // CIGaussianBlur, 0 ... 60
    @Published var sharpen: Double = 0.0       // CISharpenLuminance, 0 ... 2
    @Published var vignette: Double = 0.0      // CIVignette inputIntensity, 0 ... 2
    @Published var vignetteRadius: Double = 1.0 // CIVignette inputRadius, 0.3 ... 3
    @Published var dim: Double = 0.0           // 黑色遮罩不透明度 0 ... 0.9

    // MARK: 播放
    @Published var playbackRate: Double = 1.0  // 0.25 ... 2.0
    @Published var isPaused: Bool = false
    /// 命令通道：给命令行触发「没法用状态表达」的动作（目前只有「下一个」）。
    /// 格式 "动作:随机串"，随机串只是为了让每次写入都算一次变化。
    @Published var command: String = ""

    // MARK: 声音
    @Published var muted: Bool = true
    @Published var volume: Double = 0.5

    // MARK: 视频库
    ///
    /// `videoPath` 是**正在播的那个**，`playlist` 是**库**（可以一键切过去的那些）。
    /// 两者不是并列的两条通道：当前播的那个通常就是库里的某一项。
    /// 这个关系由 `play(_:)` 维持，别在别处直接写 `videoPath`。
    @Published var playlistEnabled: Bool = false
    @Published var playlist: [String] = []
    @Published var playlistShuffle: Bool = false
    @Published var playlistAdvance: AdvanceMode = .onEnd
    @Published var playlistIntervalMinutes: Double = 30

    // MARK: 日程（白天 / 夜间）
    @Published var scheduleEnabled: Bool = false
    @Published var dayVideoPath: String = ""
    @Published var nightVideoPath: String = ""
    @Published var dayStartMinutes: Int = 7 * 60     // 07:00
    @Published var nightStartMinutes: Int = 19 * 60  // 19:00

    // MARK: 桌面时钟
    // 默认坐标以 1920×1080 为基准标定，取自一张自带时钟图层的动态壁纸。
    @Published var clockEnabled: Bool = false
    @Published var clockAnchor: ClockAnchor = .video
    @Published var clockX: Double = 415.0 / 1920.0   // 主行基线左端，相对宽度
    @Published var clockY: Double = 710.0 / 1080.0   // 从顶部算，相对高度
    @Published var clockSize: Double = 74             // 以 1920 宽为基准的主行字号
    @Published var clockSubScale: Double = 0.38       // 副行相对主行的字号比例
    @Published var clockOpacity: Double = 0.95
    @Published var clockGlow: Double = 1.0            // 0 = 不发光
    @Published var clockFontName: String = ClockOverlay.FontChoice.systemRoundedLight
    // 三行格式，空串 = 不显示该行。token 规则见 ClockFormat。
    @Published var clockAlign: ClockAlign = .left
    /// 第 3 行相对主行的字号比例。第 2、3 行常常不是同一个层级
    /// （例：主行时间、次行日期、末行时间段），所以两行各有各的比例。
    @Published var clockSubScale3: Double = 0.38
    /// 第 2、3 行的独立锚点。`< 0` = 跟随主行自动堆叠（默认行为）。
    /// 有些排版里各行并不共用一条对齐线，这时才需要逐行给坐标。
    @Published var clockLine2X: Double = -1
    @Published var clockLine2Y: Double = -1
    @Published var clockLine3X: Double = -1
    @Published var clockLine3Y: Double = -1
    /// 光晕颜色。空串 = 跟随文字色（旧行为）。
    /// 分开可调是有依据的：壁纸原作常用「浅色字 + 另一种冷色光晕」，
    /// 两者同色时光晕只是把字涂厚，出不来那种「字待在场景里」的感觉。
    @Published var clockGlowColorHex: String = ""

    @Published var clockFormat1: String = "HH:mm"
    @Published var clockFormat2: String = "MM|dd"
    @Published var clockFormat3: String = ""
    @Published var clockColorHex: String = "FFFCF7"
    @Published var clockColor2Hex: String = "90DBFF"
    @Published var clockColorCycle: Bool = false
    @Published var clockLang: ClockLang = .auto

    /// 时钟的 `[W]` / `[P]` 最终该不该用中文
    var clockUsesChinese: Bool {
        switch clockLang {
        case .zh: return true
        case .en: return false
        case .auto: return language == .zh
        }
    }

    // MARK: 快捷键（默认全空）
    @Published var hotkeys: [String: HotkeySpec] = [:]

    // MARK: 桌面
    /// 要不要「每个桌面各一扇 `.managed` 壁纸窗」。默认 `.auto`。
    ///
    /// ⚠️ **这一整套只在「减弱动态效果」(Reduce Motion) 开着时才有用**，
    /// 因为它要挡的那个毛病（切桌面先露 0.9 秒系统静态壁纸）只在 crossfade 路径下发生；
    /// Reduce Motion 关掉走的是 slide 路径，两个 Space 实时并排合成，本来就不露。
    ///
    /// 所以关着 Reduce Motion 时开这套 = **只有副作用没有正作用**：
    /// 每个桌面多几扇窗、多几 MB 内存、Mission Control 里还会多出几张壁纸缩略图
    /// （`.managed` 窗会当成普通窗口参与 Exposé）。
    /// `.auto` 就是替人做这个判断 —— Reduce Motion 开着才启用，关着退回老的单扇 sticky 窗。
    @Published var perSpaceMode: PerSpaceMode = .auto

    /// 每个桌面叠几扇壁纸窗（1 = 只有主窗，就是老行为）。
    ///
    /// 切桌面那 0.4 秒，系统会把桌面层的窗口压暗一下，露出它下面的系统静态壁纸
    /// —— 实测一扇静止的、完全不透明的纯色窗照样被混进 ~26%，与画什么无关，
    /// 也不是 crossfade 干的（关掉 Reduce Motion 一模一样）。既然挡不住，
    /// 那就在自己下面多垫几扇：透出来的就是我们自己的窗，而不是壁纸。
    ///
    /// ⚠️ **不是越多越好，3 是实测甜点。**
    ///
    /// 两股相反的效应在这里打架 —— 在真实 StarPaper 上量切桌面时的画面偏离：
    ///
    /// | 层数 | 1 | 2 | 3 | 4 | 6 |
    /// |---|---|---|---|---|---|
    /// | 画面偏离 | +10.6 | +4.5 | **+1.9** | −2.0 | −3.2 |
    ///
    /// **符号在 3 和 4 之间翻转**：层数少时是壁纸透出占上风（壁纸更亮 → 变亮），
    /// 层数多时是衬窗自己偏暗占上风（衬窗那张图比主窗画面暗，色彩空间试过三种都消不掉）。
    /// 3 层刚好互相抵消。
    @Published var backingLayers: Int = 3

    /// 只在菜单栏显示、不占 Dock。
    ///
    /// ⚠️ **默认 false（＝显示 Dock 图标）**，这是为上架改的，不是审美取舍：
    /// Apple 的 HIG 明确要求「Let people — not your app — decide whether to put your
    /// menu bar extra in the menu bar」，而 Amphetamine 就因为**默认**藏 Dock 图标被拒过
    /// （现在它默认显示、隐藏做成用户开关）；在架的 MAS 沙盒壁纸 app Wallnetic 的
    /// `LSUIElement` 也是 false。所以形态本身允许，但**不能由 app 替用户决定**。
    ///
    /// 打开这一项 = 运行时 `NSApp.setActivationPolicy(.accessory)`，回到原来那个纯菜单栏形态。
    @Published var hideDockIcon: Bool = false

    // MARK: 省电
    @Published var pauseWhenOccluded: Bool = true
    @Published var pauseOnBattery: Bool = false
    @Published var pauseOnLowPower: Bool = true
    @Published var pauseWhenScreenLocked: Bool = true

    private var bag = Set<AnyCancellable>()

    private init() {
        load()
        loading = false
        // 立刻标记「有未写盘的改动」，不能等 debounce —— 那 300ms 正是危险窗口
        objectWillChange
            .sink { [weak self] in self?.hasUnsavedChanges = true }
            .store(in: &bag)

        objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in self?.save() }
            .store(in: &bag)

        // 外部（比如命令行 defaults write）改了配置就即时生效，不用重启 app。
        //
        // ⚠️ 两道闸都是必须的，缺一个就会出「点了立刻弹回去」：
        //   isSaving          —— save() 是逐键写的，写第一个键就发通知；不挡住的话
        //                        load() 会把后面还没写的键按磁盘旧值倒回去，
        //                        然后 save() 接着把倒回去的旧值写进磁盘。
        //   hasUnsavedChanges —— 用户刚改完、debounce 还没触发 save 的那 300ms 里，
        //                        磁盘上是旧值，这时候任何一条通知（比如 NSStatusItem
        //                        写自己的位置）都会把用户的改动冲掉。
        observeDefaults()
    }

    private func observeDefaults() {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            guard let self, !self.isSaving, !self.hasUnsavedChanges else { return }
            self.load()
        }
    }

    /// 把整个设置层切到另一个 UserDefaults suite。**只给自检用。**
    ///
    /// 自检要翻转设置才能验证读写，不能临时改真实设置域再还原。如果另一个 app
    /// 实例正在运行，它可能在测试期间读到临时值，并在测试还原磁盘后把临时值再次
    /// 保存回来。正确做法是让测试从一开始就只接触一次性 suite。
    func useDefaultsSuite(_ suite: UserDefaults) {
        let wasLoading = loading
        loading = true
        defaults = suite
        observeDefaults()
        loading = wasLoading
        load()
    }

    /// 只在值真的变了时才赋值 —— 让 load() 幂等，这样外部改了 UserDefaults
    /// 可以直接重跑 load()，不会因为「赋同样的值也会触发 objectWillChange」
    /// 而跟自己的 save() 打成死循环。
    private func setIfChanged<V: Equatable>(_ kp: ReferenceWritableKeyPath<AppSettings, V>, _ new: V) {
        if self[keyPath: kp] != new { self[keyPath: kp] = new }
    }

    private func d(_ key: String, _ fallback: Double) -> Double {
        defaults.object(forKey: key) as? Double ?? fallback
    }
    private func i(_ key: String, _ fallback: Int) -> Int {
        defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
    }

    private func b(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    private func load() {
        mediaBookmarks = defaults.data(forKey: "mediaBookmarks")
            .flatMap { try? PropertyListDecoder().decode([String: Data].self, from: $0) } ?? [:]
        setIfChanged(\.videoPath, defaults.string(forKey: "videoPath") ?? "")
        // 首次启动跟随系统语言：中文环境用中文，其余一律英文
        let systemPrefersChinese = (Locale.preferredLanguages.first ?? "").hasPrefix("zh")
        setIfChanged(\.language, Lang(rawValue: defaults.string(forKey: "language") ?? "")
            ?? (systemPrefersChinese ? .zh : .en))

        setIfChanged(\.scaleMode, ScaleMode(rawValue: defaults.string(forKey: "scaleMode") ?? "") ?? .fill)
        setIfChanged(\.iconLayer, IconLayerMode(rawValue: defaults.string(forKey: "iconLayer") ?? "") ?? .belowIcons)
        setIfChanged(\.focusX, d("focusX", 0.5))
        setIfChanged(\.focusY, d("focusY", 0.5))
        setIfChanged(\.zoom, d("zoom", 1.0))

        setIfChanged(\.exposure, d("exposure", 0.0))
        setIfChanged(\.brightness, d("brightness", 0.0))
        setIfChanged(\.contrast, d("contrast", 1.0))
        setIfChanged(\.highlights, d("highlights", 1.0))
        setIfChanged(\.shadows, d("shadows", 0.0))
        setIfChanged(\.gamma, d("gamma", 1.0))

        setIfChanged(\.saturation, d("saturation", 1.0))
        setIfChanged(\.vibrance, d("vibrance", 0.0))
        setIfChanged(\.temperature, d("temperature", 6500))
        setIfChanged(\.tint, d("tint", 0.0))

        setIfChanged(\.blurRadius, d("blurRadius", 0.0))
        setIfChanged(\.sharpen, d("sharpen", 0.0))
        setIfChanged(\.vignette, d("vignette", 0.0))
        setIfChanged(\.vignetteRadius, d("vignetteRadius", 1.0))
        setIfChanged(\.dim, d("dim", 0.0))

        setIfChanged(\.playlistEnabled, b("playlistEnabled", false))
        setIfChanged(\.playlist, defaults.stringArray(forKey: "playlist") ?? [])
        setIfChanged(\.playlistShuffle, b("playlistShuffle", false))
        setIfChanged(\.playlistAdvance, AdvanceMode(rawValue: defaults.string(forKey: "playlistAdvance") ?? "") ?? .onEnd)
        setIfChanged(\.playlistIntervalMinutes, d("playlistIntervalMinutes", 30))

        setIfChanged(\.scheduleEnabled, b("scheduleEnabled", false))
        setIfChanged(\.dayVideoPath, defaults.string(forKey: "dayVideoPath") ?? "")
        setIfChanged(\.nightVideoPath, defaults.string(forKey: "nightVideoPath") ?? "")
        setIfChanged(\.dayStartMinutes, defaults.object(forKey: "dayStartMinutes") as? Int ?? 7 * 60)
        setIfChanged(\.nightStartMinutes, defaults.object(forKey: "nightStartMinutes") as? Int ?? 19 * 60)

        setIfChanged(\.clockEnabled, b("clockEnabled", false))
        setIfChanged(\.clockAnchor, ClockAnchor(rawValue: defaults.string(forKey: "clockAnchor") ?? "") ?? .video)
        setIfChanged(\.clockX, d("clockX", 415.0 / 1920.0))
        setIfChanged(\.clockY, d("clockY", 710.0 / 1080.0))
        setIfChanged(\.clockSize, d("clockSize", 74))
        setIfChanged(\.clockSubScale, d("clockSubScale", 0.38))
        setIfChanged(\.clockSubScale3, d("clockSubScale3", d("clockSubScale", 0.38)))
        setIfChanged(\.clockAlign, ClockAlign(rawValue: defaults.string(forKey: "clockAlign") ?? "") ?? .left)
        setIfChanged(\.clockLine2X, d("clockLine2X", -1))
        setIfChanged(\.clockLine2Y, d("clockLine2Y", -1))
        setIfChanged(\.clockLine3X, d("clockLine3X", -1))
        setIfChanged(\.clockLine3Y, d("clockLine3Y", -1))
        setIfChanged(\.clockGlowColorHex, defaults.string(forKey: "clockGlowColorHex") ?? "")
        setIfChanged(\.clockOpacity, d("clockOpacity", 0.95))
        setIfChanged(\.clockGlow, d("clockGlow", 1.0))
        setIfChanged(\.clockFontName, defaults.string(forKey: "clockFontName") ?? ClockOverlay.FontChoice.systemRoundedLight)
        setIfChanged(\.clockFormat1, defaults.string(forKey: "clockFormat1") ?? "HH:mm")
        setIfChanged(\.clockFormat2, defaults.string(forKey: "clockFormat2") ?? "MM|dd")
        setIfChanged(\.clockFormat3, defaults.string(forKey: "clockFormat3") ?? "")
        setIfChanged(\.clockColorHex, defaults.string(forKey: "clockColorHex") ?? "FFFCF7")
        setIfChanged(\.clockColor2Hex, defaults.string(forKey: "clockColor2Hex") ?? "90DBFF")
        setIfChanged(\.clockColorCycle, b("clockColorCycle", false))
        setIfChanged(\.clockLang, ClockLang(rawValue: defaults.string(forKey: "clockLang") ?? "") ?? .auto)

        let decodedHotkeys = defaults.data(forKey: "hotkeys")
            .flatMap { try? JSONDecoder().decode([String: HotkeySpec].self, from: $0) } ?? [:]
        setIfChanged(\.hotkeys, decodedHotkeys)

        setIfChanged(\.playbackRate, d("playbackRate", 1.0))
        setIfChanged(\.isPaused, b("isPaused", false))
        setIfChanged(\.command, defaults.string(forKey: "command") ?? "")
        setIfChanged(\.muted, b("muted", true))
        setIfChanged(\.volume, d("volume", 0.5))

        // 迁移：老版本只有 perSpaceWindows 这个布尔。明确关掉过的人保持关，
        // 其余（开着 / 从没设过）一律给 .auto —— 老的「开」其实等价于「Reduce Motion
        // 开着时才需要」，交给 .auto 判断比原样搬过来更接近本意。
        let migrated: PerSpaceMode = (defaults.object(forKey: "perSpaceWindows") as? Bool) == false
            ? .off : .auto
        setIfChanged(\.perSpaceMode,
                     PerSpaceMode(rawValue: defaults.string(forKey: "perSpaceMode") ?? "") ?? migrated)
        setIfChanged(\.backingLayers, min(Self.maxBackingLayers, max(1, i("backingLayers", 3))))
        setIfChanged(\.hideDockIcon, b("hideDockIcon", false))
        setIfChanged(\.pauseWhenOccluded, b("pauseWhenOccluded", true))
        setIfChanged(\.pauseOnBattery, b("pauseOnBattery", false))
        setIfChanged(\.pauseOnLowPower, b("pauseOnLowPower", true))
        setIfChanged(\.pauseWhenScreenLocked, b("pauseWhenScreenLocked", true))
    }

    /// 「现在就播这个」。手点选片的唯一入口。
    ///
    /// 顺手把它收进库：内容页选的、托盘选的，下次想切回来点一下就行。
    /// **自动换片（轮播 / 日程）不走这里** —— 那些片子自动进库的话，
    /// 库会被日程那两个视频反复污染，删掉下次又自己回来。
    func play(_ path: String) {
        guard !path.isEmpty else { return }
        if !playlist.contains(path) { playlist.append(path) }
        videoPath = path
        save()
    }

    /// 播放内置示例（黑洞）。
    ///
    /// ⚠️ **不进视频库**，跟 `play(_:)` 不一样：它在 app bundle 里，
    /// 换版本或把 app 挪个位置路径就变了，留在库里只会变成一条打不开的死项。
    /// 路径失效时 `MediaSelector.choosePath` 会自己退到库 / 再退到内置 demo，不会卡住。
    func playBuiltInDemo() {
        let path = BuiltInMedia.defaultVideoPath
        guard !path.isEmpty else { return }
        videoPath = path
        save()
    }

    /// 是不是已经启动过一次。
    ///
    /// **故意不是 `@Published`** —— 它不是用户设置，只是「首启要不要把设置窗口拍脸上」
    /// 的一次性标记，不该触发一整轮 `applySettings()`，也不该进 `save()` 的批量写。
    var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: "hasLaunchedBefore") }
        set { defaults.set(newValue, forKey: "hasLaunchedBefore") }
    }

    func rememberMediaBookmark(_ data: Data, forPath path: String) {
        guard !path.isEmpty else { return }
        mediaBookmarks[path] = data
        persistMediaBookmarks()
    }

    func mediaBookmark(forPath path: String) -> Data? {
        mediaBookmarks[path]
    }

    private func persistMediaBookmarks() {
        defaults.set(try? PropertyListEncoder().encode(mediaBookmarks), forKey: "mediaBookmarks")
    }

    func save() {
        guard !loading else { return }
        isSaving = true
        defer {
            isSaving = false
            hasUnsavedChanges = false
        }
        defaults.set(videoPath, forKey: "videoPath")
        // 只保留还被当前视频 / 库 / 日程引用的授权，避免用户删库项后无限积累。
        let referencedPaths = Set(playlist + [videoPath, dayVideoPath, nightVideoPath])
            .subtracting([""])
        mediaBookmarks = mediaBookmarks.filter { referencedPaths.contains($0.key) }
        persistMediaBookmarks()
        defaults.set(language.rawValue, forKey: "language")
        defaults.set(scaleMode.rawValue, forKey: "scaleMode")
        defaults.set(iconLayer.rawValue, forKey: "iconLayer")
        for (k, v) in [
            "focusX": focusX, "focusY": focusY, "zoom": zoom,
            "exposure": exposure, "brightness": brightness, "contrast": contrast,
            "highlights": highlights, "shadows": shadows, "gamma": gamma,
            "saturation": saturation, "vibrance": vibrance,
            "temperature": temperature, "tint": tint,
            "blurRadius": blurRadius, "sharpen": sharpen, "dim": dim,
            "vignette": vignette, "vignetteRadius": vignetteRadius,
            "playlistIntervalMinutes": playlistIntervalMinutes,
            "playbackRate": playbackRate, "volume": volume,
            "clockX": clockX, "clockY": clockY,
            "clockSize": clockSize, "clockOpacity": clockOpacity,
            "clockSubScale": clockSubScale, "clockGlow": clockGlow,
            "clockSubScale3": clockSubScale3,
            "clockLine2X": clockLine2X, "clockLine2Y": clockLine2Y,
            "clockLine3X": clockLine3X, "clockLine3Y": clockLine3Y,
        ] {
            defaults.set(v, forKey: k)
        }
        defaults.set(playlist, forKey: "playlist")
        defaults.set(playlistAdvance.rawValue, forKey: "playlistAdvance")
        defaults.set(dayVideoPath, forKey: "dayVideoPath")
        defaults.set(nightVideoPath, forKey: "nightVideoPath")
        defaults.set(dayStartMinutes, forKey: "dayStartMinutes")
        defaults.set(nightStartMinutes, forKey: "nightStartMinutes")
        defaults.set(try? JSONEncoder().encode(hotkeys), forKey: "hotkeys")
        defaults.set(command, forKey: "command")
        defaults.set(clockFontName, forKey: "clockFontName")
        defaults.set(clockAnchor.rawValue, forKey: "clockAnchor")
        defaults.set(clockFormat1, forKey: "clockFormat1")
        defaults.set(clockFormat2, forKey: "clockFormat2")
        defaults.set(clockFormat3, forKey: "clockFormat3")
        defaults.set(clockColorHex, forKey: "clockColorHex")
        defaults.set(clockColor2Hex, forKey: "clockColor2Hex")
        defaults.set(clockGlowColorHex, forKey: "clockGlowColorHex")
        defaults.set(clockAlign.rawValue, forKey: "clockAlign")
        defaults.set(clockLang.rawValue, forKey: "clockLang")
        defaults.set(perSpaceMode.rawValue, forKey: "perSpaceMode")
        for (k, v) in [
            "muted": muted,
            "isPaused": isPaused,
            "playlistEnabled": playlistEnabled,
            "playlistShuffle": playlistShuffle,
            "scheduleEnabled": scheduleEnabled,
            "backingLayers": backingLayers,
            "hideDockIcon": hideDockIcon,
            "pauseWhenOccluded": pauseWhenOccluded,
            "pauseOnBattery": pauseOnBattery,
            "pauseOnLowPower": pauseOnLowPower,
            "pauseWhenScreenLocked": pauseWhenScreenLocked,
            "clockEnabled": clockEnabled,
            "clockColorCycle": clockColorCycle,
        ] {
            defaults.set(v, forKey: k)
        }
    }

    func resetImageAdjustments() {
        exposure = 0; brightness = 0; contrast = 1
        highlights = 1; shadows = 0; gamma = 1
        saturation = 1; vibrance = 0
        temperature = 6500; tint = 0
        blurRadius = 0; sharpen = 0; dim = 0
        vignette = 0; vignetteRadius = 1
    }

    func resetCrop() {
        focusX = 0.5; focusY = 0.5; zoom = 1.0
    }

    /// 时钟恢复到默认标定位置
    func resetClock() {
        clockX = 415.0 / 1920.0; clockY = 710.0 / 1080.0
        clockSize = 74; clockSubScale = 0.38; clockSubScale3 = 0.38
        clockAlign = .left
        clockLine2X = -1; clockLine2Y = -1; clockLine3X = -1; clockLine3Y = -1
        clockGlowColorHex = ""
        clockOpacity = 0.95; clockGlow = 1.0
        clockFontName = ClockOverlay.FontChoice.systemRoundedLight
        clockFormat1 = "HH:mm"; clockFormat2 = "MM|dd"; clockFormat3 = ""
        clockColorHex = "FFFCF7"; clockColor2Hex = "90DBFF"; clockColorCycle = false
        clockAnchor = .video
        clockLang = .auto
    }

    /// 画面参数是不是全是默认值 —— 全默认时一个滤镜都不挂，走零开销的硬件合成路径
    var hasImageAdjustments: Bool {
        exposure != 0 || brightness != 0 || contrast != 1
            || highlights != 1 || shadows != 0 || gamma != 1
            || saturation != 1 || vibrance != 0
            || temperature != 6500 || tint != 0
            || blurRadius > 0.01 || sharpen > 0.01 || vignette > 0.01
    }
}
