import AppKit
import AVFoundation

/// 衬窗的内容视图：一张静止的视频画面，没有 player、没有时钟。
///
/// ## 为什么需要它
///
/// 切桌面那 0.4 秒，系统会把桌面层的窗口压暗一下，露出下面的东西。挡不住
/// （见 `AppSettings.backingLayers`），所以在主窗下面多垫几扇 —— 透出来的
/// 就是我们自己。**但垫的东西必须像视频**：实测垫纯黑窗时，
/// 「露出更亮的壁纸」会变成「闪一下黑」（画面 65.4 → 38.7），比原来更显眼。
///
/// 所以这个视图显示的是**同一个视频的一帧**，并且：
///
///   - 用 `VideoWallpaperView.fillRects` 算几何 —— 必须和主窗**同一份计算**，
///     差一点点透出来的画面就是错位的；
///   - 同样吃 dim 和调色滤镜，否则透出来的颜色和主窗对不上。
///
/// 它不解码、不重绘，只在换视频时被喂一张图，所以 24 扇窗的持续开销接近零。
final class BackingWallpaperView: NSView {

    private let imageLayer = CALayer()
    private let dimLayer = CALayer()

    /// 视频原始尺寸，裁剪几何靠它算（和主窗一样是异步回填的）
    var videoSize: CGSize = .zero {
        didSet { if videoSize != oldValue { layoutImageLayer() } }
    }

    private var geometry = VideoWallpaperView.CropGeometry.default
    private var blurPadding: CGFloat = 0

    /// 要显示的那一帧。`CGImage` 或 `IOSurface` 都行 —— 多扇衬窗共用同一个对象，
    /// 所以叠 6 层也只有一份画面数据。
    var frameContents: Any? {
        get { imageLayer.contents }
        set {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = newValue
            CATransaction.commit()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true

        imageLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(imageLayer)

        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.opacity = 0
        layer?.addSublayer(dimLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layoutImageLayer()
    }

    private func layoutImageLayer() {
        let W = bounds.width, H = bounds.height
        guard W > 1, H > 1 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        dimLayer.frame = bounds

        let g = geometry
        // 还不知道视频尺寸，或者不是 .fill —— 交给 contentsGravity 摆，
        // 和主窗那边「退回 videoGravity」的分支一一对应
        guard videoSize.width > 1, videoSize.height > 1, g.scaleMode == .fill else {
            imageLayer.contentsGravity = g.scaleMode == .fit ? .resizeAspect
                                       : (g.scaleMode == .stretch ? .resize : .resizeAspectFill)
            imageLayer.frame = bounds.insetBy(dx: -blurPadding, dy: -blurPadding)
            return
        }

        // layer 的宽高比 == 视频宽高比，所以 .resize 不会变形（同主窗）
        imageLayer.contentsGravity = .resize
        imageLayer.frame = VideoWallpaperView.fillRects(
            bounds: bounds, videoSize: videoSize,
            zoom: g.zoom, focusX: g.focusX, focusY: g.focusY,
            blurPadding: blurPadding).layer
    }

    func apply(_ s: AppSettings) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        dimLayer.opacity = Float(s.dim)

        // 和主窗同样的调色，否则透出来的颜色对不上。
        // 衬窗是静止的，滤镜只在内容变化时算一次，不像主窗那样每帧都过。
        let needsFilters = s.hasImageAdjustments
        if layerUsesCoreImageFilters != needsFilters {
            layerUsesCoreImageFilters = needsFilters
        }
        imageLayer.filters = needsFilters ? VideoWallpaperView.buildFilters(from: s) : nil

        blurPadding = s.blurRadius > 0.01 ? CGFloat(s.blurRadius) * 3 : 0
        geometry = VideoWallpaperView.CropGeometry(
            scaleMode: s.scaleMode, focusX: s.focusX, focusY: s.focusY, zoom: s.zoom,
            clockFollowsVideo: false)

        CATransaction.commit()
        layoutImageLayer()
    }
}
