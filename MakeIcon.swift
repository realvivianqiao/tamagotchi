import AppKit
import ImageIO
import UniformTypeIdentifiers

@main
enum MakeIcon {
  static func main() {
    let out = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
    let size = CommandLine.arguments.dropFirst(2).first.flatMap(Int.init) ?? 1024
    writeAppIconPNG(to: out, size: size)
    print("Wrote \(out) (\(size)×\(size))")
  }

  /// Renders the sit-happy dog into a square PNG (nearest-neighbor) for AppIcon / favicon.
  static func writeAppIconPNG(to path: String, size: Int = 1024) {
    let look = Look(species: .dog, pose: .sit, eyes: .happy, tongue: true, wag: 1)
    let sprite = Dog.sprite(look).image

    let ctx = CGContext(
      data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Warm cream — matches the dog palette, reads cute in Dock / Finder.
    ctx.setFillColor(CGColor(red: 1.0, green: 0.94, blue: 0.86, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.interpolationQuality = .none

    // Keep pixel proportions; leave ~18% margin so the dog isn’t clipped by the squircle mask.
    let margin = CGFloat(size) * 0.18
    let maxW = CGFloat(size) - margin * 2
    let maxH = CGFloat(size) - margin * 2
    let scale = min(maxW / CGFloat(Canvas.w), maxH / CGFloat(Canvas.h))
    let drawW = CGFloat(Canvas.w) * scale
    let drawH = CGFloat(Canvas.h) * scale
    let x = (CGFloat(size) - drawW) / 2
    let y = (CGFloat(size) - drawH) / 2 + CGFloat(size) * 0.02
    ctx.draw(sprite, in: CGRect(x: x, y: y, width: drawW, height: drawH))

    let dest = CGImageDestinationCreateWithURL(
      URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
  }
}
