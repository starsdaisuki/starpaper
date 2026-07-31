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

/// 壁纸窗口相对桌面图标的层级
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

    /// ⚠️ 是 var 不是 let —— 自检要把整个设置层切到一次性 suite，
    /// 绝对不能碰用户的真实设置域。见 `useDefaultsSuite(_:)`。
    private var defaults = UserDefaults.standard
    private var defaultsObserver: NSObjectProtocol?
    private var loading = true
    /// 正在写盘。写盘过程中 UserDefaults 会逐键发通知，必须挡住重入的 load()。
    private var isSaving = false
    /// 内存里有还没写盘的改动。这段时间内不能从磁盘回读 —— 磁盘上是旧值。
    private var hasUnsavedChanges = false

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

    // MARK: 播放列表
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

    // MARK: 快捷键（默认全空）
    @Published var hotkeys: [String: HotkeySpec] = [:]

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
    private func b(_ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    private func load() {
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

        if let raw = defaults.data(forKey: "hotkeys"),
           let decoded = try? JSONDecoder().decode([String: HotkeySpec].self, from: raw) {
            setIfChanged(\.hotkeys, decoded)
        }

        setIfChanged(\.playbackRate, d("playbackRate", 1.0))
        setIfChanged(\.isPaused, b("isPaused", false))
        setIfChanged(\.command, defaults.string(forKey: "command") ?? "")
        setIfChanged(\.muted, b("muted", true))
        setIfChanged(\.volume, d("volume", 0.5))

        setIfChanged(\.pauseWhenOccluded, b("pauseWhenOccluded", true))
        setIfChanged(\.pauseOnBattery, b("pauseOnBattery", false))
        setIfChanged(\.pauseOnLowPower, b("pauseOnLowPower", true))
        setIfChanged(\.pauseWhenScreenLocked, b("pauseWhenScreenLocked", true))
    }

    func save() {
        guard !loading else { return }
        isSaving = true
        defer {
            isSaving = false
            hasUnsavedChanges = false
        }
        defaults.set(videoPath, forKey: "videoPath")
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
        for (k, v) in [
            "muted": muted,
            "isPaused": isPaused,
            "playlistEnabled": playlistEnabled,
            "playlistShuffle": playlistShuffle,
            "scheduleEnabled": scheduleEnabled,
            "pauseWhenOccluded": pauseWhenOccluded,
            "pauseOnBattery": pauseOnBattery,
            "pauseOnLowPower": pauseOnLowPower,
            "pauseWhenScreenLocked": pauseWhenScreenLocked,
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

    /// 画面参数是不是全是默认值 —— 全默认时一个滤镜都不挂，走零开销的硬件合成路径
    var hasImageAdjustments: Bool {
        exposure != 0 || brightness != 0 || contrast != 1
            || highlights != 1 || shadows != 0 || gamma != 1
            || saturation != 1 || vibrance != 0
            || temperature != 6500 || tint != 0
            || blurRadius > 0.01 || sharpen > 0.01 || vignette > 0.01
    }
}
