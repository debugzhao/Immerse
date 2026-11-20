// Draws the Immerse app icon and writes it to AppIcon.appiconset
// Usage: swift scripts/make-icon.swift                  → app icon
//        swift scripts/make-icon.swift --brand <dir>    → website / brand assets (PNG, SVG, favicons)
//        swift scripts/make-icon.swift --ios            → iPhone app icon (1024, opaque, no alpha channel)
//
// Follows the macOS icon grid: 1024 canvas, 824 body, corner radius ~185, room left at the bottom for the shadow.
// All drawing happens in that 1024 "icon space"; brand variants just crop to the body and drop the shadow.
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

/// Variants of the same artwork
enum Layout {
    /// macOS app icon: body inset in the 1024 grid with a drop shadow
    case appIcon
    /// Brand logo: the rounded body fills the whole canvas, transparent corners, no shadow
    case logo
    /// Opaque full-bleed square (apple-touch-icon); iOS applies its own corner mask
    case square
}

func render(size: Int = Int(canvas), layout: Layout = .appIcon) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Map icon space onto the output: the whole 1024 grid for the app icon, just the 824 body otherwise
    if layout == .appIcon {
        ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    } else {
        ctx.scaleBy(x: CGFloat(size) / body.width, y: CGFloat(size) / body.height)
        ctx.translateBy(x: -body.minX, y: -body.minY)
    }
    let shape = layout == .square
        ? CGPath(rect: body, transform: nil)
        : CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Shadow: CG's y axis points up, so a negative offset moves it down
    ctx.saveGState()
    if layout == .appIcon {
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.32))
    }
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x2A2775))
    ctx.fillPath()
    ctx.restoreGState()

    // Base color: vertical gradient from indigo to midnight blue
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space,
                        colors: [rgb(0x7472F2), rgb(0x4B47CF), rgb(0x1F1B66)] as CFArray,
                        locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])

    // A bit of soft light on top to give the base some depth
    let glow = CGGradient(colorsSpace: space,
                          colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 860), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 860), endRadius: 560, options: [])

    let center = CGPoint(x: 512, y: 512)

    // Ripples: a few thin rings fading outward, expressing "immersion"
    for (i, r) in [300.0, 350.0, 400.0].enumerated() {
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.10 - CGFloat(i) * 0.03))
        ctx.setLineWidth(6)
        ctx.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        ctx.strokePath()
    }

    // Progress ring track
    let ringR: CGFloat = 220
    let ringW: CGFloat = 58
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.16))
    ctx.setLineWidth(ringW)
    ctx.addArc(center: center, radius: ringR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    // Progress arc: sweeps 3/4 clockwise from 12 o'clock, with a slight white glow
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

    // Center focus dot
    let dot: CGFloat = 46
    ctx.setFillColor(rgb(0xFFFFFF, 0.95))
    ctx.fillEllipse(in: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2))

    // Top inner highlight stroke, mimicking the glass edge of macOS icons (not on the square, whose edge gets masked)
    if layout != .square {
        ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: corner - 1.5,
                           cornerHeight: corner - 1.5, transform: nil))
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.18))
        ctx.setLineWidth(3)
        ctx.strokePath()
    }
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

/// Writes a CGImage rendered at its final size (no resampling)
func writeExact(_ image: CGImage, to url: URL) {
    try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
}

/// The logo as SVG, drawn in the same icon-space coordinates (y flipped: SVG's y axis points down)
func logoSVG() -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="100 100 824 824" width="824" height="824">
      <defs>
        <clipPath id="body"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
        <linearGradient id="bg" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse">
          <stop offset="0" stop-color="#7472F2"/><stop offset="0.5" stop-color="#4B47CF"/><stop offset="1" stop-color="#1F1B66"/>
        </linearGradient>
        <radialGradient id="glow" cx="512" cy="164" r="560" gradientUnits="userSpaceOnUse">
          <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.22"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
        </radialGradient>
        <filter id="arcGlow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="18"/></filter>
      </defs>
      <g clip-path="url(#body)">
        <rect x="100" y="100" width="824" height="824" fill="url(#bg)"/>
        <rect x="100" y="100" width="824" height="824" fill="url(#glow)"/>
        <g fill="none" stroke="#FFFFFF" stroke-width="6">
          <circle cx="512" cy="512" r="300" stroke-opacity="0.10"/>
          <circle cx="512" cy="512" r="350" stroke-opacity="0.07"/>
          <circle cx="512" cy="512" r="400" stroke-opacity="0.04"/>
        </g>
        <circle cx="512" cy="512" r="220" fill="none" stroke="#FFFFFF" stroke-opacity="0.16" stroke-width="58"/>
        <path d="M512 292 A220 220 0 1 1 292 512" fill="none" stroke="#FFFFFF" stroke-opacity="0.45" stroke-width="58" stroke-linecap="round" filter="url(#arcGlow)"/>
        <path d="M512 292 A220 220 0 1 1 292 512" fill="none" stroke="#FFFFFF" stroke-width="58" stroke-linecap="round"/>
        <circle cx="512" cy="512" r="46" fill="#FFFFFF" fill-opacity="0.95"/>
      </g>
      <rect x="101.5" y="101.5" width="821" height="821" rx="183.5" fill="none" stroke="#FFFFFF" stroke-opacity="0.18" stroke-width="3"/>
    </svg>

    """
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let args = CommandLine.arguments

if let flag = args.firstIndex(of: "--brand") {
    let dir = URL(fileURLWithPath: args.count > flag + 1 ? args[flag + 1] : "brand",
                  relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let outputs: [(String, Int, Layout)] = [
        ("immerse-logo-1024.png", 1024, .logo),
        ("immerse-logo-512.png", 512, .logo),
        ("immerse-logo-256.png", 256, .logo),
        ("immerse-app-icon-1024.png", 1024, .appIcon),
        ("apple-touch-icon.png", 180, .square),
        ("favicon-32.png", 32, .logo),
        ("favicon-16.png", 16, .logo),
    ]
    for (name, size, layout) in outputs {
        writeExact(render(size: size, layout: layout), to: dir.appendingPathComponent(name))
    }
    try! logoSVG().write(to: dir.appendingPathComponent("immerse-logo.svg"), atomically: true, encoding: .utf8)
    print("✅ \(dir.standardizedFileURL.path)")
    exit(0)
}

if args.contains("--ios") {
    // App Store Connect rejects iOS icons that carry an alpha channel, so redraw the full-bleed square without one
    let square = render(size: 1024, layout: .square)
    let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(square, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    let url = root.appendingPathComponent("ImmerseiOS/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
    writeExact(ctx.makeImage()!, to: url)
    print("✅ \(url.path)")
    exit(0)
}

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
