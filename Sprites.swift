import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Tunables

let defaultPetName = "Mochi"
let scale: CGFloat = 4 // screen points per sprite pixel
let fps: Double = 30

// MARK: - Pixel canvas

enum Px: UInt8 { case outline, gold, light, dark, black, white, pink, red, tag }

let palette: [Px: UInt32] = [
  .outline: 0x4A2C12, .gold: 0xE8A84C, .light: 0xF8D99C, .dark: 0xC07C2E,
  .black: 0x1E1612, .white: 0xFFFFFF, .pink: 0xFF8FA3, .red: 0xD9434E, .tag: 0xFFD84A,
]

struct Canvas {
  static let w = 38, h = 28
  var px = [Px?](repeating: nil, count: w * h)

  static func contains(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h }

  subscript(x: Int, y: Int) -> Px? {
    get { Self.contains(x, y) ? px[y * Self.w + x] : nil }
    set { if Self.contains(x, y) { px[y * Self.w + x] = newValue } }
  }

  mutating func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ c: Px) {
    for y in 0..<Self.h {
      for x in 0..<Self.w {
        let dx = (Double(x) + 0.5 - cx) / rx, dy = (Double(y) + 0.5 - cy) / ry
        if dx * dx + dy * dy <= 1 { self[x, y] = c }
      }
    }
  }

  mutating func rect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: Px) {
    for y in y0...y1 { for x in x0...x1 { self[x, y] = c } }
  }

  /// Wraps every filled region in a 1px outline.
  mutating func outline() {
    let before = self
    for y in 0..<Self.h {
      for x in 0..<Self.w where before[x, y] == nil {
        if [(1, 0), (-1, 0), (0, 1), (0, -1)].contains(where: { before[x + $0.0, y + $0.1] != nil }) {
          self[x, y] = .outline
        }
      }
    }
  }

  /// Lowest filled row, so every pose stands on the same ground line.
  var bottomRow: Int {
    (0..<Self.h).last { y in (0..<Self.w).contains { self[$0, y] != nil } } ?? Self.h - 1
  }

  func cgImage() -> CGImage {
    var bytes = [UInt8](repeating: 0, count: Self.w * Self.h * 4)
    for (i, p) in px.enumerated() {
      guard let p, let rgb = palette[p] else { continue }
      bytes[i * 4] = UInt8(rgb >> 16 & 0xFF)
      bytes[i * 4 + 1] = UInt8(rgb >> 8 & 0xFF)
      bytes[i * 4 + 2] = UInt8(rgb & 0xFF)
      bytes[i * 4 + 3] = 255
    }
    return CGImage(
      width: Self.w, height: Self.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Self.w * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
      shouldInterpolate: false, intent: .defaultIntent)!
  }
}

// MARK: - The dog

enum Pose: Hashable { case walk(Int), sit, lie, hang }
enum Eyes: Hashable { case open, closed, happy, sad }

struct Look: Hashable {
  var pose = Pose.sit
  var eyes = Eyes.open
  var tongue = false
  var wag = 0
}

struct Sprite {
  let canvas: Canvas
  let image: CGImage
  let head: (x: Int, y: Int) // head offset from the standing pose
}

/// Draws the golden retriever facing right; the view mirrors it to face left.
enum Dog {
  static func sprite(_ look: Look) -> Sprite {
    var c = Canvas()
    let head: (x: Int, y: Int)
    switch look.pose {
    case .walk(let phase): head = standing(&c, phase: phase, wag: look.wag, legBottom: 23)
    case .hang: head = standing(&c, phase: 0, wag: -1, legBottom: 25)
    case .sit: head = sitting(&c, wag: look.wag)
    case .lie: head = lying(&c, wag: look.wag)
    }
    drawHead(&c, at: head, tongue: look.tongue)
    c.outline()
    drawFace(&c, at: head, eyes: look.eyes)
    return Sprite(canvas: c, image: c.cgImage(), head: head)
  }

  private static func standing(_ c: inout Canvas, phase: Int, wag: Int, legBottom: Int) -> (Int, Int) {
    switch wag {
    case -1: tail(&c, [(8, 15), (7, 17), (6.5, 19)]) // dangling
    case 0: tail(&c, [(8, 14), (6.5, 12), (5.5, 10)])
    default: tail(&c, [(8, 14), (6, 13), (4.5, 11.5)])
    }
    let (nearBack, farBack, farFront, nearFront) = phase == 0 ? (7, 11, 19, 23) : (10, 8, 22, 20)
    leg(&c, x: farBack, top: 17, bottom: legBottom, near: false)
    leg(&c, x: farFront, top: 17, bottom: legBottom, near: false)
    leg(&c, x: nearBack, top: 17, bottom: legBottom, near: true)
    leg(&c, x: nearFront, top: 17, bottom: legBottom, near: true)
    c.ellipse(15.5, 16, 9.5, 5, .gold)     // body
    c.ellipse(15, 19, 6.5, 1.8, .light)    // belly
    c.ellipse(21.5, 16.5, 2.8, 3.5, .light) // chest fluff
    return (0, 0)
  }

  private static func sitting(_ c: inout Canvas, wag: Int) -> (Int, Int) {
    tail(&c, wag <= 0 ? [(7.5, 23), (5.5, 23), (3.5, 22.5)] : [(7.5, 23), (5.5, 22), (4, 20.5)])
    leg(&c, x: 21, top: 15, bottom: 23, near: false)
    c.ellipse(11.5, 19.5, 5, 4.5, .gold) // haunch
    c.ellipse(15.5, 15.5, 5.5, 6.5, .gold) // torso
    c.ellipse(19, 15, 2.8, 4, .light)      // chest fluff
    c.rect(11, 23, 16, 23, .light)         // back paw
    leg(&c, x: 18, top: 15, bottom: 23, near: true)
    return (-4, -1)
  }

  private static func lying(_ c: inout Canvas, wag: Int) -> (Int, Int) {
    tail(&c, wag <= 0 ? [(6, 22), (4, 22.5), (2.5, 22.5)] : [(6, 22), (4, 21.5), (2.5, 20.5)])
    c.ellipse(14.5, 20, 10, 4.2, .gold)
    c.rect(26, 23, 36, 24, .gold) // front paws stretched out
    c.rect(35, 23, 36, 24, .light)
    return (0, 8)
  }

  private static func tail(_ c: inout Canvas, _ pts: [(Double, Double)]) {
    for (i, p) in pts.enumerated() {
      let r = 2.0 - Double(i) * 0.25
      c.ellipse(p.0, p.1, r, r, i == pts.count - 1 ? .light : .gold)
    }
  }

  private static func leg(_ c: inout Canvas, x: Int, top: Int, bottom: Int, near: Bool) {
    c.rect(x, top, x + 2, bottom, near ? .gold : .dark)
    c.rect(x, bottom, x + 2, bottom, near ? .light : .dark)
  }

  private static func drawHead(_ c: inout Canvas, at o: (x: Int, y: Int), tongue: Bool) {
    let (dx, dy) = (Double(o.x), Double(o.y))
    c.ellipse(25.5 + dx, 9.5 + dy, 6.2, 5.8, .gold)
    c.ellipse(31 + dx, 11.5 + dy, 3.3, 2.3, .light) // snout
    if tongue { c.rect(30 + o.x, 13 + o.y, 31 + o.x, 15 + o.y, .pink) }
    c.rect(33 + o.x, 10 + o.y, 34 + o.x, 11 + o.y, .black) // nose
    c.rect(21 + o.x, 14 + o.y, 23 + o.x, 15 + o.y, .red)   // collar
    c[22 + o.x, 16 + o.y] = .tag
    c.ellipse(21.5 + dx, 10.5 + dy, 2.2, 3.8, .dark)       // floppy ear
  }

  private static func drawFace(_ c: inout Canvas, at o: (x: Int, y: Int), eyes: Eyes) {
    let (x, y) = (26 + o.x, 8 + o.y)
    switch eyes {
    case .open:
      c.rect(x, y, x + 1, y + 1, .black)
      c[x + 1, y] = .white
    case .closed:
      c.rect(x - 1, y + 1, x + 1, y + 1, .outline)
    case .happy:
      c[x - 1, y + 1] = .outline
      c[x, y] = .outline
      c[x + 1, y + 1] = .outline
    case .sad: // heavy lid, looking down
      c.rect(x - 1, y, x + 1, y, .outline)
      c.rect(x, y + 1, x + 1, y + 1, .black)
    }
    c[x, y + 3] = .pink // blush
  }
}

// MARK: - Window geometry

let spriteSize = CGSize(width: CGFloat(Canvas.w) * scale, height: CGFloat(Canvas.h) * scale)
let windowSize = CGSize(width: 300, height: spriteSize.height + 120)
let spriteOrigin = CGPoint(x: (windowSize.width - spriteSize.width) / 2, y: 0)

struct Particle {
  var text: String
  var pos: CGPoint
  var vel: CGVector
  var life: Int
  let maxLife: Int
}

// MARK: - Sprite sheet preview (for tweaking the art without launching the app)

func writePreview(to path: String) {
  let looks = [
    Look(pose: .walk(0)), Look(pose: .walk(1), wag: 1), Look(pose: .sit),
    Look(pose: .sit, eyes: .happy, tongue: true, wag: 1), Look(pose: .lie, eyes: .closed), Look(pose: .hang), Look(pose: .sit, eyes: .sad, wag: -1),
  ]
  let s = 8, pad = 16, cellW = Canvas.w * s + pad
  let ctx = CGContext(
    data: nil, width: looks.count * cellW + pad, height: Canvas.h * s + 2 * pad, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.setFillColor(CGColor(red: 0.86, green: 0.92, blue: 1, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
  ctx.interpolationQuality = .none
  for (i, look) in looks.enumerated() {
    ctx.draw(Dog.sprite(look).image, in: CGRect(x: pad + i * cellW, y: pad, width: Canvas.w * s, height: Canvas.h * s))
  }
  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
  CGImageDestinationFinalize(dest)
}

