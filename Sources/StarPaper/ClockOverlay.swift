import AppKit
import CoreText

/// 桌面时钟叠加层。
///
/// 起因：有些动态壁纸自带时钟图层，但一旦被导出成视频，整个场景就会被**烘焙**进画面 ——
/// 时钟压成了像素，永远停在导出的那一刻。想要活的时钟，只能在播放侧重新叠一层。
///
/// 图层结构（挂在 VideoWallpaperView 的根 layer 上，位于 dimLayer 之上）：
///
///   containerLayer (CALayer)
///     ├─ glow[i]   ← CATextLayer，只负责发光，文字本身被光晕淹没
///     ├─ solid[i]  ← CATextLayer，实体字，压在光晕正上方
///     └─ halo[i]   ← CATextLayer，**加光**层（additionCompositing），叠在最上面
///
/// 每行内容由各自的格式字符串决定（见 ClockFormat），空串表示该行不显示。
/// 三行独立成层而不是一层塞多行，是因为各行字号和透明度都不同，
/// 而 CATextLayer 不支持逐行样式。
///
/// ⚠️ 两个关键点，任缺一个都会让时钟看起来像「贴上去的字」而不是画面的一部分：
///
/// 1. `contentsScale` 必须跟着屏幕的 backingScaleFactor 走，否则 Retina 上文字按 1x
///    光栅化再放大 —— 那就退化成跟烘焙版一样糊了。
/// 2. **要外发光，不要投影**。深色阴影会把字压成贴纸；壁纸原作用的都是亮色光晕，
///    让字融进背景。所以 shadow 用亮色 + 零偏移 + 大半径，而不是黑色 + 下偏移。
final class ClockOverlay {

    /// 位置和字号的设计基准宽度。默认值按一张 16:9 参考壁纸的时钟位置实测标定。
    static let designWidth: CGFloat = 1920

    /// 最多几行。三行够表达「时间 / 日期星期 / 时间段」这种常见排版。
    static let lineCount = 3

    let containerLayer = CALayer()
    private var glow: [CATextLayer] = []
    private var solid: [CATextLayer] = []
    private var halo: [CATextLayer] = []

    private var timer: Timer?
    private var lastTexts = [String](repeating: "", count: ClockOverlay.lineCount)

    private var config: Config = .default
    private var hostBounds: CGRect = .zero
    private var contentsScale: CGFloat = 2.0

    /// 时钟的全部可调项。从 AppSettings 抽出来，避免图层直接依赖整个设置对象。
    struct Config: Equatable {
        var enabled: Bool
        /// 相对位置，0...1。锚点是**主行的左下角**（基线左端）。
        var x: Double
        var y: Double
        /// 主行字号，以 designWidth 为基准；实际字号按宿主矩形宽度等比缩放。
        var size: Double
        /// 副行相对主行的字号比例。不同壁纸排版差别很大，所以可调。
        var subScale: Double
        /// 末行相对主行的字号比例。与 `subScale` 分开，因为「日期」和「时间段」
        /// 常常不是同一个层级。
        var subScale3: Double
        var opacity: Double
        /// 发光强度，0 = 不发光（退化成纯文字）
        var glow: Double
        /// 光晕颜色。nil = 跟随文字色。
        var glowColor: NSColor?
        /// 各行相对锚点的水平对齐方式
        var align: ClockAlign
        /// 第 2、3 行的独立锚点，`< 0` = 跟随主行自动堆叠。
        /// 索引 0 恒为 `-1`（主行永远用 `x` / `y`），保留只为下标对齐。
        var lineX: [Double]
        var lineY: [Double]
        var fontName: String
        /// 三行各自的格式字符串，空串 = 该行不显示
        var formats: [String]
        var color: NSColor
        /// 双色循环的目标色
        var color2: NSColor
        var colorCycle: Bool
        /// 界面语言，决定 `[W]` / `[P]` 输出中文还是英文
        var chinese: Bool

        static let `default` = Config(
            enabled: false,
            x: 415.0 / 1920.0,     // 参考壁纸里时钟的基线左端
            y: 710.0 / 1080.0,
            size: 74,
            subScale: 0.38,
            subScale3: 0.38,
            opacity: 0.95,
            glow: 1.0,
            glowColor: nil,
            align: .left,
            lineX: [-1, -1, -1],
            lineY: [-1, -1, -1],
            fontName: FontChoice.systemRoundedLight,
            formats: ["HH:mm", "MM|dd", ""],
            color: NSColor(red: 1.0, green: 0.99, blue: 0.97, alpha: 1),
            color2: NSColor(red: 0.565, green: 0.859, blue: 1.0, alpha: 1),
            colorCycle: false,
            chinese: true
        )
    }

    /// 字体选择。
    ///
    /// SF Rounded 拿不到稳定的 PostScript 名（它是系统私有字体，`.SF NS Rounded` 那种带点
    /// 前缀的名字不保证可用），所以用哨兵字符串走 `fontDescriptor.withDesign(.rounded)`
    /// 这条官方路径，其余则按 PostScript 名直接创建。
    enum FontChoice {
        static let systemRoundedLight = "system-rounded-light"
        static let systemRoundedThin = "system-rounded-thin"
    }

    /// 候选字体。系统自带的两项恒在；其余按 PostScript 名探测，
    /// 装了才列出来 —— 列一个选了却没有的名字，只会让人以为是软件坏了。
    ///
    /// ⚠️ `CTFontCreateWithName` 找不到字体时**不报错**，它会安静地回退到别的字体。
    /// 所以「装没装」只能靠回读 PostScript 名比对，不能靠判空。
    static let availableFonts: [(id: String, label: String)] = {
        var list: [(id: String, label: String)] = [
            (FontChoice.systemRoundedLight, "SF Rounded Light"),
            (FontChoice.systemRoundedThin, "SF Rounded Thin"),
        ]
        for (name, label) in [
            ("Monofur", "monofur"),
            ("HelveticaNeue-Thin", "Helvetica Neue Thin"),
            ("HelveticaNeue-UltraLight", "Helvetica Neue UltraLight"),
            ("HelveticaNeue-Light", "Helvetica Neue Light"),
            ("AvenirNext-UltraLight", "Avenir Next UltraLight"),
        ] where isInstalled(name) {
            list.append((name, label))
        }
        return list
    }()

    static func isInstalled(_ postScriptName: String) -> Bool {
        let f = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        return (CTFontCopyPostScriptName(f) as String).caseInsensitiveCompare(postScriptName) == .orderedSame
    }

    static func makeFont(_ name: String, size: CGFloat) -> CTFont {
        switch name {
        case FontChoice.systemRoundedLight, FontChoice.systemRoundedThin:
            let w: NSFont.Weight = name == FontChoice.systemRoundedThin ? .thin : .light
            let base = NSFont.systemFont(ofSize: size, weight: w)
            if let d = base.fontDescriptor.withDesign(.rounded),
               let f = NSFont(descriptor: d, size: size) {
                return f
            }
            return base                                  // 拿不到圆体就退回系统字体，不要没字
        default:
            return CTFontCreateWithName(name as CFString, size, nil)
        }
    }

    /// 双色循环一个来回的时长。做成常量而不是设置项 —— 再多一个滑块不抵界面复杂度。
    private static let colorCycleDuration: CFTimeInterval = 8

    init() {
        containerLayer.isHidden = true
        // 时钟是纯展示层，绝不能拦事件（宿主窗口本身也 ignoresMouseEvents）。
        // 也不裁剪：锚在视频矩形上时，超出部分交给上层视图裁到屏幕边界即可。
        containerLayer.masksToBounds = false

        for _ in 0..<ClockOverlay.lineCount {
            let g = CATextLayer(), s = CATextLayer(), h = CATextLayer()
            for l in [g, s, h] {
                l.alignmentMode = .left
                l.truncationMode = .none
                l.isWrapped = false
                containerLayer.addSublayer(l)
            }
            glow.append(g)
            solid.append(s)
            halo.append(h)
        }
        // 先挂的在下层，但上面循环是交替添加的，这里按 glow → solid → halo 重排一次
        for s in solid { containerLayer.addSublayer(s) }
        for h in halo { containerLayer.addSublayer(h) }
    }

    deinit { timer?.invalidate() }

    // MARK: - 外部接口

    func apply(_ c: Config, bounds: CGRect, scale: CGFloat) {
        let configChanged = c != config
        config = c
        hostBounds = bounds
        contentsScale = scale

        containerLayer.isHidden = !c.enabled || !windowReady
        guard c.enabled else {
            stopTimer()
            return
        }
        if configChanged {
            // 换了格式或语言，缓存的文本就不能再用来判重
            lastTexts = [String](repeating: "", count: ClockOverlay.lineCount)
        }
        style()
        refreshText()
        startTimer()
    }

    /// 宿主窗口拿到第一帧了没有。
    ///
    /// ⚠️ 冷启动和每次 `rebuildScreens()` 之后，壁纸窗要过一会儿才有画面。
    /// 以前这段时间里窗口是纯黑的，而时钟已经画上去了 —— 用户看到的是
    /// 「黑底上浮出一个时钟，然后画面突然亮起来、时钟又看不见了」。
    /// 见 `VideoWallpaperView.applyReady(_:)`。
    private var windowReady = false

    func setWindowReady(_ ready: Bool) {
        guard ready != windowReady else { return }
        windowReady = ready
        containerLayer.isHidden = !config.enabled || !ready
    }

    func updateBounds(_ bounds: CGRect, scale: CGFloat) {
        guard bounds != hostBounds || scale != contentsScale else { return }
        hostBounds = bounds
        contentsScale = scale
        guard config.enabled else { return }
        style()
        layoutLines()
    }

    /// 壁纸暂停时一起停 —— 没人看的时候不必每秒醒来
    func setActive(_ active: Bool) {
        if active && config.enabled {
            refreshText()
            startTimer()
        } else {
            stopTimer()
        }
    }

    // MARK: - 内部

    private var scaleFactor: CGFloat {
        guard hostBounds.width > 1 else { return 1 }
        return hostBounds.width / ClockOverlay.designWidth
    }

    private func fontSize(_ i: Int) -> CGFloat {
        let base = CGFloat(config.size) * scaleFactor
        switch i {
        case 0:  return base
        case 1:  return base * CGFloat(config.subScale)
        default: return base * CGFloat(config.subScale3)
        }
    }

    private func font(_ i: Int) -> CTFont {
        ClockOverlay.makeFont(config.fontName, size: fontSize(i))
    }

    private func alpha(_ i: Int) -> CGFloat {
        CGFloat(config.opacity) * (i == 0 ? 1.0 : 0.84)
    }

    private func style() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        containerLayer.frame = hostBounds
        let g = CGFloat(config.glow)

        for i in 0..<ClockOverlay.lineCount {
            let hidden = config.formats[i].isEmpty
            let f = font(i), fs = fontSize(i), a = alpha(i)

            for l in [glow[i], solid[i], halo[i]] {
                l.font = f
                l.fontSize = fs
                // ⭐ 决定清晰度的一行：不设就按 1x 光栅化，Retina 上直接糊掉
                l.contentsScale = contentsScale
                l.isHidden = hidden
                l.foregroundColor = config.color.withAlphaComponent(a).cgColor
            }

            // 发光层：亮色、零偏移、半径随字号走，所以放大字不会显得光晕变小
            if g > 0.01 {
                glow[i].isHidden = hidden
                glow[i].shadowColor = (config.glowColor ?? config.color).cgColor
                glow[i].shadowOffset = .zero
                glow[i].shadowRadius = fs * 0.36 * g
                glow[i].shadowOpacity = Float(min(1.0, 0.85 * g))
            } else {
                glow[i].isHidden = true
            }
            // 实体层不带任何阴影，保证字心是干净锐利的
            solid[i].shadowOpacity = 0

            // ⭐⭐ 加光层：解决「颜色、位置、字体都对了，字看着还是比原版实」那个问题。
            //
            // 原作的发光是一条多趟 bloom（降采样 → 上色 → 高斯 → **叠回**），叠回时是
            // 加光：笔画中心被自己的光晕冲淡到近白，只有边缘留住颜色。
            // CALayer 的 shadow 永远画在字**背后**，字心一点不变 —— 所以光晕再强，
            // 紫字也还是纯紫，这正是肉眼一眼看出「像贴上去的」的来源。
            //
            // 这一层用 `additionCompositing` 叠在实体字**上面**，把光真正加进字心。
            // 它同时带一圈同色阴影，于是内发光和外光晕来自同一次绘制，不会脱节。
            if g > 0.01 {
                let lit = config.glowColor ?? config.color
                halo[i].isHidden = hidden
                // ⭐ 字心用**接近白**的光，外圈才用光晕本色 —— 这是 bloom 的物理：
                // 光足够强时相加会**削顶到白**，颜色只在能量衰减后的边缘才看得见。
                // 早先字心直接用光晕色，结果整行偏冷（原作是暖白），就是漏了这一步。
                //
                // 两个系数都是照着原壁纸的烘焙帧标定的：太低字心还是纯色（像贴纸），
                // 太高整行糊成一团光。
                let core = lit.blended(withFraction: 0.75, of: .white) ?? lit
                halo[i].foregroundColor = core.withAlphaComponent(min(1.0, 0.55 * g)).cgColor
                halo[i].shadowColor = lit.cgColor
                halo[i].shadowOffset = .zero
                halo[i].shadowRadius = fs * 0.30 * g
                halo[i].shadowOpacity = Float(min(1.0, 0.85 * g))
                halo[i].compositingFilter = "additionCompositing"
            } else {
                halo[i].isHidden = true
            }
        }
        applyColorCycle()
    }

    /// 双色循环。交给 CABasicAnimation 在渲染层做，不占 CPU ——
    /// 手动插值要么每帧唤醒，要么跳变，两头不讨好。
    private func applyColorCycle() {
        for i in 0..<ClockOverlay.lineCount {
            for l in [glow[i], solid[i]] { l.removeAnimation(forKey: "clockColorCycle") }
            glow[i].removeAnimation(forKey: "clockGlowCycle")
            guard config.colorCycle, !config.formats[i].isEmpty else { continue }
            let a = alpha(i)
            for l in [glow[i], solid[i]] {
                let anim = CABasicAnimation(keyPath: "foregroundColor")
                anim.fromValue = config.color.withAlphaComponent(a).cgColor
                anim.toValue = config.color2.withAlphaComponent(a).cgColor
                anim.duration = ClockOverlay.colorCycleDuration
                anim.autoreverses = true
                anim.repeatCount = .infinity
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                l.add(anim, forKey: "clockColorCycle")
            }
            // 光晕本身也跟着换色，否则渐变到冷色时会残留一圈暖光。
            // 但光晕色被单独指定时不跟 —— 那是作者定死的一种光，不该被文字色拖着走。
            guard config.glowColor == nil else { continue }
            let ga = CABasicAnimation(keyPath: "shadowColor")
            ga.fromValue = config.color.cgColor
            ga.toValue = config.color2.cgColor
            ga.duration = ClockOverlay.colorCycleDuration
            ga.autoreverses = true
            ga.repeatCount = .infinity
            ga.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow[i].add(ga, forKey: "clockGlowCycle")
        }
    }

    /// 按当前文本重新测量并摆放各行。
    ///
    /// 锚点是「**基线 × 对齐边**」那一个点，不是图层左上角。这样定义有两个好处：
    ///
    /// - 换字号、换字体、换内容，锚点指的都还是同一个视觉位置；
    /// - 右对齐 / 居中时，`09:59 → 10:00` 这种宽度变化不会让整行左右抖。
    ///
    /// 宽度用**排版宽度（advance）**而不是墨迹（ink）宽度：字形两侧的空白也是版式的一部分，
    /// 原作壁纸的文字框同样按 advance 对齐，用 ink 会让右对齐整体右移半个字身。
    private func layoutLines() {
        func advanceWidth(_ s: String, _ f: CTFont) -> CGFloat {
            guard !s.isEmpty else { return 0 }
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: s, attributes: [.font: f]))
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // 自动堆叠时的游标：下一行基线该落在哪儿（从顶部算，宿主视图 isFlipped）
        var cursorBaseline = CGFloat(config.y) * hostBounds.height

        for i in 0..<ClockOverlay.lineCount {
            guard !config.formats[i].isEmpty else {
                glow[i].frame = .zero; solid[i].frame = .zero; halo[i].frame = .zero; continue
            }
            let f = font(i), fs = fontSize(i)
            let asc = CTFontGetAscent(f), desc = CTFontGetDescent(f)
            let w = advanceWidth(lastTexts[i], f)

            // 逐行独立锚点；负数 = 沿用主行的 x / 自动往下堆
            let hasOwnY = i > 0 && config.lineY[i] >= 0
            let baseline = hasOwnY
                ? CGFloat(config.lineY[i]) * hostBounds.height
                : (i == 0 ? cursorBaseline : cursorBaseline + asc + fs * 0.10)
            let anchorX = (i > 0 && config.lineX[i] >= 0 ? CGFloat(config.lineX[i]) : CGFloat(config.x))
                * hostBounds.width

            let left: CGFloat
            switch config.align {
            case .left:   left = anchorX
            case .center: left = anchorX - w / 2
            case .right:  left = anchorX - w
            }

            // frame 只需容下文字本身：光晕是 CALayer shadow，画在 bounds 之外，不受裁剪。
            // 右侧仍留一点余量 —— 个别字体的斜体右缘会溢出 advance。
            let rect = CGRect(x: left, y: baseline - asc,
                              width: w + fs * 0.08, height: asc + desc)
            glow[i].frame = rect
            solid[i].frame = rect
            halo[i].frame = rect

            if !hasOwnY { cursorBaseline = baseline }
        }
    }

    private func refreshText() {
        let now = Date()
        var texts = [String](repeating: "", count: ClockOverlay.lineCount)
        for i in 0..<ClockOverlay.lineCount {
            texts[i] = ClockFormat.render(config.formats[i], at: now, zh: config.chinese)
        }
        // 只在真的变了才动 layer —— 每秒 tick，但通常每分钟才重绘一次
        guard texts != lastTexts else { return }
        lastTexts = texts

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<ClockOverlay.lineCount {
            glow[i].string = texts[i]
            solid[i].string = texts[i]
            halo[i].string = texts[i]
        }
        CATransaction.commit()

        layoutLines()
    }

    private func startTimer() {
        guard timer == nil else { return }
        // 含秒的格式要每秒重绘；否则 1 秒 tick 只是为了跨分钟时及时翻牌，
        // refreshText 内部判重，绝大多数 tick 什么都不做。
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshText()
        }
        t.tolerance = config.formats.contains(where: ClockFormat.needsSecondTick) ? 0.05 : 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - 颜色与 hex 互转

/// 时钟颜色存成 6 位 hex 而不是 `NSColor` 归档 ——
/// UserDefaults 里存一串人眼可读的字符，比 NSKeyedArchiver 的 blob 好调试得多，
/// 手动改 `defaults write` 也方便。
extension NSColor {
    /// 解析 `RRGGBB` / `#RRGGBB`。解析不出来时返回 nil，由调用方决定退回什么。
    static func fromClockHex(_ hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(
            red: CGFloat((v >> 16) & 0xFF) / 255.0,
            green: CGFloat((v >> 8) & 0xFF) / 255.0,
            blue: CGFloat(v & 0xFF) / 255.0,
            alpha: 1
        )
    }

    /// 转成 `RRGGBB`。先转到 sRGB —— 直接读 catalog color 的分量会抛异常。
    var clockHex: String {
        guard let c = usingColorSpace(.sRGB) else { return "FFFFFF" }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }
}
