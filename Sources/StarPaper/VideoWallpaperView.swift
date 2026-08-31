import AppKit
import AVFoundation
import CoreImage

/// 壁纸窗口里的内容视图，四层 layer：
///
///   container (masksToBounds)
///     ├─ playerLayer   ← 视频，CIFilter 挂在这一层
///     ├─ dimLayer      ← 纯黑遮罩，靠 opacity 压暗
///     └─ clockLayer    ← 桌面时钟叠加层（见 ClockOverlay），默认关
///
/// 时钟必须在 dimLayer **之上** —— 压暗是给视频用的，不该把时钟一起压灰。
///
/// 为什么压暗要单独一层：CIColorControls 的 brightness 是加法偏移，
/// 压暗会让画面发灰；黑遮罩是乘法，压暗后对比度还在，桌面图标也更好认。
final class VideoWallpaperView: NSView {

    let playerLayer = AVPlayerLayer()
    private let dimLayer = CALayer()
    private let clock = ClockOverlay()

    /// 视频原始尺寸。异步拿到后要重新布局 —— 裁剪几何全靠它算。
    ///
    /// ⚠️ 这里**必须**连时钟的锚点矩形一起更新。视频尺寸是异步到的：
    /// 冷启动时 `apply()` 跑在它之前，`videoContentRect` 还是空的，
    /// 时钟只能退回整个窗口；如果这里只重排视频层，时钟就会一直挂在窗口上，
    /// 直到下一次 `layout()` 偶然被触发 —— 表现为「刚开机时钟位置不对，
    /// 动一下窗口/换个屏幕又对了」。
    var videoSize: CGSize = .zero {
        didSet {
            guard videoSize != oldValue else { return }
            layoutVideoLayer()
            clock.updateBounds(clockHostRect, scale: currentScale)
        }
    }

    private var settingsSnapshot: CropGeometry = .default
    private var blurPadding: CGFloat = 0

    /// 视频画面在本视图坐标系里的真实矩形，**不含** blurPadding 的外扩。
    ///
    /// 时钟的「跟随画面」锚点就挂在这个矩形上：画面被裁剪 / 放大 / 平移多少，
    /// 时钟就跟着走多少，于是时钟与画面元素的相对位置在任何屏幕比例下都不变。
    /// 排除 blurPadding 是有意的 —— 模糊只是为了让边缘不露空，不该让时钟跟着漂。
    private var videoContentRect: CGRect = .zero

    /// 布局需要的构图参数，从 AppSettings 抽出来避免视图层直接依赖整个设置对象
    struct CropGeometry: Equatable {
        var scaleMode: ScaleMode
        var focusX: Double
        var focusY: Double
        var zoom: Double
        var clockFollowsVideo: Bool
        static let `default` = CropGeometry(
            scaleMode: .fill, focusX: 0.5, focusY: 0.5, zoom: 1, clockFollowsVideo: false)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // ⚠️ 建出来时是**透明**的，不是黑的 —— 见 applyReady(_:)
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true          // 裁剪 / 模糊溢出都靠它裁回来

        playerLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(playerLayer)

        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.opacity = 0
        layer?.addSublayer(dimLayer)

        layer?.addSublayer(clock.containerLayer)
        startWatchingReadiness()
    }

    /// 当前屏幕的像素密度。时钟按它光栅化，Retina 上才不会糊。
    private var currentScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }

    /// 播放暂停时把时钟的定时器一起停掉
    func setClockActive(_ active: Bool) { clock.setActive(active) }

    // MARK: - 第一帧出来之前

    /// 这扇窗现在有没有画面。
    ///
    /// ⚠️ **冷启动和每次 `rebuildScreens()` 都会经过「窗口已经在了、但视频还没解出
    /// 第一帧」这个状态。** 以前这段时间窗口是 `isOpaque = true` 的纯黑，直接盖在桌面上，
    /// 而时钟已经画上去了 —— 用户看到的是「黑底上浮出一个时钟，然后画面突然亮起来、
    /// 时钟又看不见了」（2026-08-31 两次用户报告，一次在内置 demo 上、一次在自选壁纸上）。
    ///
    /// 现在没画面就让整扇窗透明、时钟不画。透出来的是下面的衬窗（同一段视频的静帧）
    /// 或者系统壁纸 —— 两者都比一块纯黑好，也正是 macOS 自己在做的事。
    private var isReady = false
    private var readyObservation: NSKeyValueObservation?
    private var readyFallback: DispatchWorkItem?

    private func applyReady(_ ready: Bool) {
        guard ready != isReady else { return }
        isReady = ready
        if ready { readyFallback?.cancel(); readyFallback = nil }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bg = ready ? NSColor.black.cgColor : NSColor.clear.cgColor
        layer?.backgroundColor = bg
        playerLayer.backgroundColor = bg
        CATransaction.commit()

        syncWindowOpacity()
        clock.setWindowReady(ready)
        DebugLog.log(ready ? "◻︎ 壁纸窗拿到第一帧" : "◻︎ 壁纸窗还没有画面 → 先透明")
    }

    private func syncWindowOpacity() {
        window?.isOpaque = isReady
        window?.backgroundColor = isReady ? .black : .clear
    }

    /// 窗口是在视图之后才挂上来的，所以透明度要在这里再同步一次
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncWindowOpacity()
    }

    private func startWatchingReadiness() {
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) {
            [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            DispatchQueue.main.async { self?.applyReady(ready) }
        }
        // ⚠️ 兜底：万一 isReadyForDisplay 永远不翻（文件坏了、解不出画面），
        // 也不能让壁纸窗永远透明、时钟永远不出现。3 秒后一律按「有画面」处理，
        // 退回改动之前的行为，最坏情况也只是黑一下。
        let fb = DispatchWorkItem { [weak self] in self?.applyReady(true) }
        readyFallback = fb
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: fb)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layoutVideoLayer()
        clock.updateBounds(clockHostRect, scale: currentScale)
    }

    // MARK: - 裁剪几何

    /// 核心思路：不去动 videoGravity 的居中行为，而是**直接算出视频该占多大、放哪儿**，
    /// 让 playerLayer 的 frame 就等于缩放后的视频矩形，再靠父层 masksToBounds 裁掉多余部分。
    /// 这样 focusX / focusY / zoom 就是纯几何运算，跟滤镜、解码完全解耦。
    private func layoutVideoLayer() {
        let W = bounds.width, H = bounds.height
        guard W > 1, H > 1 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        dimLayer.frame = bounds

        let g = settingsSnapshot
        let vw = videoSize.width, vh = videoSize.height

        // 还不知道视频尺寸（异步加载中），先用 AVPlayerLayer 自己的居中填充顶着
        guard vw > 1, vh > 1, g.scaleMode == .fill else {
            playerLayer.videoGravity = g.scaleMode == .fit ? .resizeAspect
                                     : (g.scaleMode == .stretch ? .resize : .resizeAspectFill)
            playerLayer.frame = bounds.insetBy(dx: -blurPadding, dy: -blurPadding)
            // videoGravity 自己做的居中，这里照它的规则复算一遍画面矩形给时钟用
            videoContentRect = Self.gravityRect(
                mode: g.scaleMode, videoSize: videoSize, in: bounds)
            return
        }

        // layer 的宽高比 == 视频宽高比，所以用 .resize 也不会变形
        playerLayer.videoGravity = .resize

        let rects = Self.fillRects(bounds: bounds, videoSize: videoSize,
                                   zoom: g.zoom, focusX: g.focusX, focusY: g.focusY,
                                   blurPadding: blurPadding)
        videoContentRect = rects.content
        playerLayer.frame = rects.layer
    }

    /// `.fill` 模式下画面该占多大、放哪儿。
    ///
    /// 抽出来是因为**衬窗必须用同一份计算**（见 `BackingWallpaperView`）——
    /// 差一点点，切桌面那 0.4 秒透出来的画面就是错位的，比露壁纸还显眼。
    ///
    /// - Returns: `content` 是画面的真实矩形（时钟锚点用），
    ///            `layer` 额外含 blurPadding 的外扩（图层用）。
    static func fillRects(bounds: CGRect, videoSize: CGSize,
                          zoom: Double, focusX: Double, focusY: Double,
                          blurPadding: CGFloat) -> (content: CGRect, layer: CGRect) {
        let W = bounds.width, H = bounds.height
        let vw = videoSize.width, vh = videoSize.height
        let base = max(W / vw, H / vh) * CGFloat(zoom)
        let w0 = vw * base, h0 = vh * base
        // focus 0 → 贴左/贴上，1 → 贴右/贴下
        let x0 = -(w0 - W) * CGFloat(focusX)
        let y0 = -(h0 - H) * CGFloat(focusY)
        let content = CGRect(x: x0, y: y0, width: w0, height: h0)

        guard blurPadding > 0 else { return (content, content) }
        // 模糊会吃掉边缘一圈，整体以「视图中心」为原点等比放大一点再裁回来
        let k = 1 + (2 * blurPadding) / min(W, H)
        return (content, CGRect(
            x: (x0 - W / 2) * k + W / 2,
            y: (y0 - H / 2) * k + H / 2,
            width: w0 * k,
            height: h0 * k
        ))
    }

    /// 复算 `videoGravity` 的摆放结果。视频尺寸未知时退回整个视图。
    private static func gravityRect(mode: ScaleMode, videoSize: CGSize, in bounds: CGRect) -> CGRect {
        let W = bounds.width, H = bounds.height
        let vw = videoSize.width, vh = videoSize.height
        guard vw > 1, vh > 1 else { return bounds }
        switch mode {
        case .stretch:
            return bounds                                   // 铺满且变形，画面就是整个视图
        case .fit, .fill:
            let s = mode == .fit ? min(W / vw, H / vh) : max(W / vw, H / vh)
            let w = vw * s, h = vh * s
            return CGRect(x: (W - w) / 2, y: (H - h) / 2, width: w, height: h)   // 两种都居中
        }
    }

    /// 时钟锚点该挂在哪个矩形上
    private var clockHostRect: CGRect {
        guard settingsSnapshot.clockFollowsVideo, videoContentRect.width > 1 else { return bounds }
        return videoContentRect
    }

    // MARK: - 应用设置

    func apply(_ s: AppSettings) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        dimLayer.opacity = Float(s.dim)

        // ⚠️ 顺序要紧：不先开 layerUsesCoreImageFilters 就挂 CIFilter，Apple 文档说会抛异常。
        //
        // 这个开关会把整棵图层树从 WindowServer 的进程外合成拉回本进程内渲染，
        // 所以做成按需。不过实测代价没有想象中大 —— 1080p60 全屏、其余条件相同：
        //   无滤镜 5.0% 单核 / 挂滤镜 4.8% 单核（各 20s 窗口，差值在噪声里）
        // 视频解码本身才是大头。按需开着仍然是对的，但别指望它省出什么。
        let needsFilters = s.hasImageAdjustments
        if layerUsesCoreImageFilters != needsFilters {
            layerUsesCoreImageFilters = needsFilters
        }
        playerLayer.filters = needsFilters ? VideoWallpaperView.buildFilters(from: s) : nil

        blurPadding = s.blurRadius > 0.01 ? CGFloat(s.blurRadius) * 3 : 0
        settingsSnapshot = CropGeometry(
            scaleMode: s.scaleMode, focusX: s.focusX, focusY: s.focusY, zoom: s.zoom,
            clockFollowsVideo: s.clockAnchor == .video
        )

        CATransaction.commit()
        layoutVideoLayer()

        clock.apply(
            ClockOverlay.Config(
                enabled: s.clockEnabled,
                x: s.clockX,
                y: s.clockY,
                size: s.clockSize,
                subScale: s.clockSubScale,
                subScale3: s.clockSubScale3,
                opacity: s.clockOpacity,
                glow: s.clockGlow,
                glowColor: NSColor.fromClockHex(s.clockGlowColorHex),
                align: s.clockAlign,
                lineX: [-1, s.clockLine2X, s.clockLine3X],
                lineY: [-1, s.clockLine2Y, s.clockLine3Y],
                fontName: s.clockFontName,
                formats: [s.clockFormat1, s.clockFormat2, s.clockFormat3],
                color: NSColor.fromClockHex(s.clockColorHex) ?? .white,
                color2: NSColor.fromClockHex(s.clockColor2Hex) ?? .white,
                colorCycle: s.clockColorCycle,
                chinese: s.clockUsesChinese
            ),
            bounds: clockHostRect,
            scale: currentScale
        )
    }

    /// 滤镜链。全默认时返回 nil —— 一个滤镜都不挂，走零开销的硬件合成路径。
    ///
    /// ⚠️ Apple 文档：改已挂在 layer.filters 里的 CIFilter 实例属性是 undefined behavior，
    /// 所以每次都整条重建，不做原地改参。
    static func buildFilters(from s: AppSettings) -> [CIFilter]? {
        guard s.hasImageAdjustments else { return nil }
        var chain: [CIFilter] = []

        func add(_ name: String, _ params: [String: Any]) {
            guard let f = CIFilter(name: name) else { return }
            for (k, v) in params { f.setValue(v, forKey: k) }
            chain.append(f)
        }

        if s.exposure != 0 {
            add("CIExposureAdjust", [kCIInputEVKey: s.exposure])
        }
        if s.highlights != 1 || s.shadows != 0 {
            add("CIHighlightShadowAdjust", [
                "inputHighlightAmount": s.highlights,
                "inputShadowAmount": s.shadows,
            ])
        }
        if s.gamma != 1 {
            add("CIGammaAdjust", ["inputPower": s.gamma])
        }
        if s.brightness != 0 || s.contrast != 1 || s.saturation != 1 {
            add("CIColorControls", [
                kCIInputBrightnessKey: s.brightness,
                kCIInputContrastKey: s.contrast,
                kCIInputSaturationKey: s.saturation,
            ])
        }
        if s.vibrance != 0 {
            add("CIVibrance", ["inputAmount": s.vibrance])
        }
        if s.temperature != 6500 || s.tint != 0 {
            // 滤镜把 inputNeutral 这个色温「校正」到 inputTargetNeutral。
            // 所以把滑杆值放在 neutral 一侧，调高 = 声称原片偏冷 = 校正后更暖，
            // 跟 Lightroom 那种「往右更暖」的手感一致。tint 取负同理（往右偏品红）。
            add("CITemperatureAndTint", [
                "inputNeutral": CIVector(x: s.temperature, y: -s.tint),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        if s.vignette > 0.01 {
            // 注意顺序：暗角要在模糊之前，不然模糊会把暗角的边界糊掉
            add("CIVignette", [
                kCIInputIntensityKey: s.vignette,
                kCIInputRadiusKey: s.vignetteRadius,
            ])
        }
        if s.sharpen > 0.01 {
            add("CISharpenLuminance", [kCIInputSharpnessKey: s.sharpen])
        }
        if s.blurRadius > 0.01 {
            add("CIGaussianBlur", [kCIInputRadiusKey: s.blurRadius])
        }

        return chain.isEmpty ? nil : chain
    }
}
