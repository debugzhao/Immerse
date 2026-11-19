// 绘制 Immerse 的 App 图标并输出到 AppIcon.appiconset
// 用法：swift scripts/make-icon.swift
//
// 按 macOS 图标网格：1024 画布、824 主体、圆角约 185，底部留投影空间
import AppKit
import CoreGraphics

let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let corner: CGFloat = 185

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render() -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let shape = CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // 投影：CG 坐标 y 轴向上，负偏移即向下
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.32))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x2A2775))
    ctx.fillPath()
    ctx.restoreGState()

    // 底色：靛蓝到深夜蓝的竖向渐变
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space,
                        colors: [rgb(0x7472F2), rgb(0x4B47CF), rgb(0x1F1B66)] as CFArray,
                        locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])

    // 上方一点柔光，让底色更有层次
    let glow = CGGradient(colorsSpace: space,
                          colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 860), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 860), endRadius: 560, options: [])

    let center = CGPoint(x: 512, y: 512)

    // 涟漪：几圈越来越淡的细环，表达「沉浸」
    for (i, r) in [300.0, 350.0, 400.0].enumerated() {
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.10 - CGFloat(i) * 0.03))
        ctx.setLineWidth(6)
        ctx.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        ctx.strokePath()
    }

    // 进度环轨道
    let ringR: CGFloat = 220
    let ringW: CGFloat = 58
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.16))
    ctx.setLineWidth(ringW)
    ctx.addArc(center: center, radius: ringR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    // 进度弧：从 12 点顺时针走 3/4，带一点白色辉光
    let start = CGFloat.pi / 2
    let end = start - CGFloat.pi * 1.5
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 36, color: rgb(0xFFFFFF, 0.45))
    ctx.setStrokeColor(rgb(0xFFFFFF))
    ctx.setLineWidth(ringW)
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: ringR, startAngle: start, endAngle: end, clockwise: true)
    ctx.strokePath()
    ctx.restoreGState()

    // 中心专注点
    let dot: CGFloat = 46
    ctx.setFillColor(rgb(0xFFFFFF, 0.95))
    ctx.fillEllipse(in: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2))

    // 顶部内高光描边，模拟 macOS 图标的玻璃边缘
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: corner - 1.5,
                       cornerHeight: corner - 1.5, transform: nil))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.18))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, size: Int, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    g.imageInterpolation = .high
    NSGraphicsContext.current = g
    g.cgContext.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let set = root.appendingPathComponent("Immerse/Resources/Assets.xcassets/AppIcon.appiconset")
let master = render()

var images: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        writePNG(master, size: pt * scale, to: set.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
    }
}
let json = try! JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]],
                                       options: [.prettyPrinted, .sortedKeys])
try! json.write(to: set.appendingPathComponent("Contents.json"))
print("✅ \(set.path)")
