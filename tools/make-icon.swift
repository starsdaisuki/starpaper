#!/usr/bin/env swift
//
// StarPaper 应用图标生成器。
//
//   swift tools/make-icon.swift
//
// 每个尺寸单独按矢量渲染（不是渲染 1024 再缩），这样 16px 那档也不会糊成一团。
// 生成 Resources/AppIcon.iconset/ 然后交给 iconutil 打包成 .icns。
//
// 设计：深蓝→紫的对角渐变方胜形（squircle），一道斜向光带，正中一颗四角星
// —— 跟菜单栏那个 sparkles.tv 图标是同一套语言。星形轮廓够粗，缩到 16px 仍认得出。

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 形状

/// 方胜形（超椭圆）。Apple 的圆角不是标准圆角矩形而是连续曲率，
/// n≈5 的超椭圆是很接近的近似，比 roundedRect 像得多。
func squirclePath(in rect: CGRect, n: Double = 5.0) -> CGPath {
    let path = CGMutablePath()
    let a = Double(rect.width / 2), b = Double(rect.height / 2)
    let cx = Double(rect.midX), cy = Double(rect.midY)
    let steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2.0 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2.0 / n), st)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
        else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// 四角星。waist 越小尖角越锐利。
func sparklePath(center c: CGPoint, radius r: CGFloat, waist: CGFloat = 0.165) -> CGPath {
    let w = r * waist
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x, y: c.y - r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + w, y: c.y - w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + w, y: c.y + w))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - w, y: c.y + w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - w, y: c.y - w))
    p.closeSubpath()
    return p
}

// MARK: - 绘制

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func drawIcon(size S: CGFloat, into ctx: CGContext) {
    let space = CGColorSpaceCreateDeviceRGB()
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // macOS 图标网格：1024 画布里内容大约占 824，上下各留白
    let inset = S * 0.098
    let body = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let shape = squirclePath(in: body)

    // 投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.010),
                  blur: S * 0.022, color: rgb(0x000000, 0.28))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x1A2350))
    ctx.fillPath()
    ctx.restoreGState()

    // 主体渐变（左上深蓝 → 右下紫）
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    let grad = CGGradient(colorsSpace: space, colors: [
        rgb(0x0D1636), rgb(0x25409B), rgb(0x5A4AC6), rgb(0xA96FDC),
    ] as CFArray, locations: [0.0, 0.42, 0.72, 1.0])!
    ctx.drawLinearGradient(grad,
        start: CGPoint(x: body.minX, y: body.maxY),
        end: CGPoint(x: body.maxX, y: body.minY),
        options: [])

    // 右上角一团青色辉光，模拟壁纸的高光
    let glow = CGGradient(colorsSpace: space, colors: [
        rgb(0x7FE3FF, 0.42), rgb(0x7FE3FF, 0.0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow,
        startCenter: CGPoint(x: body.maxX - body.width * 0.18, y: body.maxY - body.height * 0.16),
        startRadius: 0,
        endCenter: CGPoint(x: body.maxX - body.width * 0.18, y: body.maxY - body.height * 0.16),
        endRadius: body.width * 0.62, options: [])

    // 两道斜向光带，暗示「画面在动」。宽窄不一才不显得死板。
    ctx.saveGState()
    for (offset, width, alpha) in [(-0.34, 0.19, 0.13), (0.16, 0.085, 0.09)] as [(CGFloat, CGFloat, CGFloat)] {
        let bw = body.width * width
        let ox = body.width * offset
        let band = CGMutablePath()
        band.move(to: CGPoint(x: body.minX + ox, y: body.minY))
        band.addLine(to: CGPoint(x: body.minX + ox + bw, y: body.minY))
        band.addLine(to: CGPoint(x: body.maxX + ox + bw, y: body.maxY))
        band.addLine(to: CGPoint(x: body.maxX + ox, y: body.maxY))
        band.closeSubpath()
        ctx.addPath(band)
        ctx.setFillColor(rgb(0xFFFFFF, alpha))
        ctx.fillPath()
    }
    ctx.restoreGState()

    // 顶部一道细高光边，让方胜形有「玻璃感」
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.setLineWidth(S * 0.008)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.22))
    ctx.strokePath()
    ctx.restoreGState()

    ctx.restoreGState()

    // MARK: 主星
    let c = CGPoint(x: body.midX, y: body.midY)
    let R = body.width * 0.305

    // 星星背后的柔光
    ctx.saveGState()
    let halo = CGGradient(colorsSpace: space, colors: [
        rgb(0xFFFFFF, 0.55), rgb(0xBFD8FF, 0.16), rgb(0xBFD8FF, 0.0),
    ] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(halo, startCenter: c, startRadius: 0,
                           endCenter: c, endRadius: R * 1.45, options: [])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: S * 0.035, color: rgb(0x8FD4FF, 0.9))
    ctx.addPath(sparklePath(center: c, radius: R))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // 两颗小星做配重。16px 那档会糊，所以小尺寸直接不画。
    if S >= 64 {
        let small: [(CGPoint, CGFloat)] = [
            (CGPoint(x: body.minX + body.width * 0.775, y: body.minY + body.height * 0.775), R * 0.335),
            (CGPoint(x: body.minX + body.width * 0.235, y: body.minY + body.height * 0.235), R * 0.235),
        ]
        for (p, r) in small {
            ctx.addPath(sparklePath(center: p, radius: r))
            ctx.setFillColor(rgb(0xFFFFFF, 0.88))
            ctx.fillPath()
        }
    }
}

// MARK: - 输出

func render(size: Int, to url: URL) {
    let S = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("建不了 CGContext") }

    drawIcon(size: S, into: ctx)

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("写不出 PNG") }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// .icns 要求的全套尺寸
let variants: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for v in variants {
    render(size: v.px, to: iconset.appendingPathComponent("\(v.name).png"))
    print("  \(v.name).png  (\(v.px)px)")
}
print("→ \(iconset.path)")
