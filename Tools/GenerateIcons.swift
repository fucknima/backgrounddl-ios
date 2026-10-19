import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Reproducible, resolution-independent 1024px App Store icons.
// No embedded fonts, network downloads, or third-party dependencies.
let side = 1024
let space = CGColorSpaceCreateDeviceRGB()

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 255) / 255,
        CGFloat((hex >> 8) & 255) / 255,
        CGFloat(hex & 255) / 255,
        alpha
    ])!
}

func gradient(_ ctx: CGContext, _ top: CGColor, _ bottom: CGColor,
              start: CGPoint, end: CGPoint) {
    let g = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray,
                       locations: [0, 1])!
    ctx.drawLinearGradient(g, start: start, end: end, options: [])
}

func cloudShape() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 278, y: 744))
    p.addCurve(to: CGPoint(x: 126, y: 588),
               control1: CGPoint(x: 188, y: 744), control2: CGPoint(x: 126, y: 679))
    p.addCurve(to: CGPoint(x: 269, y: 427),
               control1: CGPoint(x: 126, y: 506), control2: CGPoint(x: 185, y: 440))
    p.addCurve(to: CGPoint(x: 510, y: 245),
               control1: CGPoint(x: 304, y: 303), control2: CGPoint(x: 400, y: 245))
    p.addCurve(to: CGPoint(x: 746, y: 438),
               control1: CGPoint(x: 633, y: 245), control2: CGPoint(x: 729, y: 329))
    p.addCurve(to: CGPoint(x: 897, y: 595),
               control1: CGPoint(x: 837, y: 445), control2: CGPoint(x: 897, y: 511))
    p.addCurve(to: CGPoint(x: 742, y: 744),
               control1: CGPoint(x: 897, y: 679), control2: CGPoint(x: 834, y: 744))
    p.closeSubpath()
    return p
}

func arrowShape() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 480, y: 346))
    p.addQuadCurve(to: CGPoint(x: 496, y: 332), control: CGPoint(x: 480, y: 332))
    p.addLine(to: CGPoint(x: 529, y: 332))
    p.addQuadCurve(to: CGPoint(x: 545, y: 348), control: CGPoint(x: 545, y: 332))
    p.addLine(to: CGPoint(x: 545, y: 554))
    p.addLine(to: CGPoint(x: 609, y: 554))
    p.addQuadCurve(to: CGPoint(x: 615, y: 571), control: CGPoint(x: 628, y: 554))
    p.addLine(to: CGPoint(x: 526, y: 689))
    p.addQuadCurve(to: CGPoint(x: 498, y: 690), control: CGPoint(x: 512, y: 709))
    p.addLine(to: CGPoint(x: 408, y: 571))
    p.addQuadCurve(to: CGPoint(x: 416, y: 554), control: CGPoint(x: 396, y: 554))
    p.addLine(to: CGPoint(x: 480, y: 554))
    p.closeSubpath()
    return p
}

func generate(dark: Bool, to file: URL) throws {
    guard let ctx = CGContext(data: nil, width: side, height: side,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: space,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw NSError(domain: "Icon", code: 1) }

    // Top-left coordinate system, with an opaque light/dark background.
    ctx.translateBy(x: 0, y: CGFloat(side))
    ctx.scaleBy(x: 1, y: -1)
    gradient(ctx,
             color(dark ? 0x101F38 : 0xFBFDFF),
             color(dark ? 0x071020 : 0xE8F4FF),
             start: CGPoint(x: 0, y: 0),
             end: CGPoint(x: 1024, y: 1024))
    let cloud = cloudShape()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 20), blur: 40,
                  color: color(dark ? 0x000B29 : 0x164B89, alpha: dark ? 0.55 : 0.24))
    ctx.addPath(cloud)
    ctx.setFillColor(color(dark ? 0x165EDE : 0x1665FE))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(cloud)
    ctx.clip()
    gradient(ctx, color(dark ? 0x48A9FF : 0x2879FF),
             color(dark ? 0x1559D7 : 0x10C8EF),
             start: CGPoint(x: 360, y: 250), end: CGPoint(x: 680, y: 760))
    ctx.restoreGState()

    // Large unmistakable downward arrow, visible at 60x60 home-screen size.
    let arrow = arrowShape()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 20,
                  color: color(0x12366E, alpha: 0.42))
    ctx.addPath(arrow)
    ctx.setFillColor(color(dark ? 0x7FF7FF : 0xF8FDFF))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(arrow)
    ctx.clip()
    gradient(ctx, color(dark ? 0x77F4FF : 0xFFFFFF),
             color(dark ? 0xB6F9FF : 0xE6F6FF),
             start: CGPoint(x: 512, y: 330), end: CGPoint(x: 512, y: 710))
    ctx.restoreGState()

    guard let image = ctx.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            file as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "Icon", code: 2) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "Icon", code: 3)
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("BackgroundDL/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
try generate(dark: false, to: root.appendingPathComponent("AppIcon-1024.png"))
try generate(dark: true, to: root.appendingPathComponent("AppIcon-Dark-1024.png"))
print("Generated light and dark 1024px app icons.")
