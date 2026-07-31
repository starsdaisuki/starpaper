import AppKit
import AVFoundation
import CoreImage

/// 壁纸窗口里的内容视图，三层 layer：
///
///   container (masksToBounds)
///     ├─ playerLayer   ← 视频，CIFilter 挂在这一层
///     └─ dimLayer      ← 纯黑遮罩，靠 opacity 压暗
///
/// 为什么压暗要单独一层：CIColorControls 的 brightness 是加法偏移，
/// 压暗会让画面发灰；黑遮罩是乘法，压暗后对比度还在，桌面图标也更好认。
final class VideoWallpaperView: NSView {

    let playerLayer = AVPlayerLayer()
    private let dimLayer = CALayer()

    /// 视频原始尺寸。异步拿到后要重新布局 —— 裁剪几何全靠它算。
    var videoSize: CGSize = .zero {
        didSet { if videoSize != oldValue { layoutVideoLayer() } }
    }

    private var settingsSnapshot: CropGeometry = .default
    private var blurPadding: CGFloat = 0

    /// 布局需要的构图参数，从 AppSettings 抽出来避免视图层直接依赖整个设置对象
    struct CropGeometry: Equatable {
        var scaleMode: ScaleMode
        var focusX: Double
        var focusY: Double
        var zoom: Double
        static let `default` = CropGeometry(scaleMode: .fill, focusX: 0.5, focusY: 0.5, zoom: 1)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true          // 裁剪 / 模糊溢出都靠它裁回来

        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)

        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.opacity = 0
        layer?.addSublayer(dimLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layoutVideoLayer()
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
            return
        }

        // layer 的宽高比 == 视频宽高比，所以用 .resize 也不会变形
        playerLayer.videoGravity = .resize

        let base = max(W / vw, H / vh) * CGFloat(g.zoom)
        let w0 = vw * base, h0 = vh * base
        // focus 0 → 贴左/贴上，1 → 贴右/贴下
        let x0 = -(w0 - W) * CGFloat(g.focusX)
        let y0 = -(h0 - H) * CGFloat(g.focusY)

        if blurPadding > 0 {
            // 模糊会吃掉边缘一圈，整体以「视图中心」为原点等比放大一点再裁回来
            let k = 1 + (2 * blurPadding) / min(W, H)
            playerLayer.frame = CGRect(
                x: (x0 - W / 2) * k + W / 2,
                y: (y0 - H / 2) * k + H / 2,
                width: w0 * k,
                height: h0 * k
            )
        } else {
            playerLayer.frame = CGRect(x: x0, y: y0, width: w0, height: h0)
        }
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
            scaleMode: s.scaleMode, focusX: s.focusX, focusY: s.focusY, zoom: s.zoom
        )

        CATransaction.commit()
        layoutVideoLayer()
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
