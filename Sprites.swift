import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Tunables

let defaultPetName = "Mochi"
let scale: CGFloat = 5 // chunky pixels on the dock
let fps: Double = 30

// MARK: - Pixel canvas

enum Px: UInt8 {
  case outline, gold, light, dark, black, white, pink, red, tag, orange, cream, gray, purple, yellow
}

let palette: [Px: UInt32] = [
  // Classic handmade pixel palette (matches the zoomies dog)
  .outline: 0x4A2C12, .gold: 0xE8A84C, .light: 0xF8D99C, .dark: 0xC07C2E,
  .black: 0x1E1612, .white: 0xFFFFFF, .pink: 0xFF8FA3, .red: 0xD9434E, .tag: 0xFFD84A,
  .orange: 0xF08A3A, .cream: 0xFFF3D6, .gray: 0x6E6E6E,
  .purple: 0xC86BB0, .yellow: 0xFFD45A,
]

enum Species: String, CaseIterable, Codable, Hashable {
  case dog, octopus, bird

  var title: String {
    switch self {
    case .dog: "Dog"
    case .octopus: "Octopus"
    case .bird: "Bird"
    }
  }

  var emoji: String {
    switch self {
    case .dog: "🐶"
    case .octopus: "🐙"
    case .bird: "🐦"
    }
  }

  static func parse(_ raw: String?) -> Species {
    guard let raw, !raw.isEmpty else { return .dog }
    if let s = Species(rawValue: raw) { return s }
    // retired species → dog
    return .dog
  }
}

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
enum Eyes: Hashable { case open, closed, happy, sad, angry }

struct Look: Hashable {
  var species = Species.dog
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

/// Pixel pets facing right; the view mirrors them to face left.
enum Dog {
  static func sprite(_ look: Look) -> Sprite {
    var c = Canvas()
    let head: (x: Int, y: Int)
    switch look.species {
    case .dog:
      head = drawDog(&c, look)
    case .octopus:
      head = drawOctopus(&c, look)
    case .bird:
      head = drawBird(&c, look)
    }
    c.outline()
    drawEyes(&c, at: head, eyes: look.eyes, species: look.species)
    return Sprite(canvas: c, image: c.cgImage(), head: head)
  }

  // MARK: Dog — classic side-profile golden (the zoomies look)

  private static func drawDog(_ c: inout Canvas, _ look: Look) -> (Int, Int) {
    let head: (Int, Int)
    switch look.pose {
    case .walk(let phase):
      dogTail(&c, wag: look.wag, sit: false)
      dogLegs(&c, phase: phase, legBottom: 23)
      c.ellipse(15.5, 16, 9.5, 5, .gold)
      c.ellipse(15, 19, 6.5, 1.8, .light)
      c.ellipse(21.5, 16.5, 2.8, 3.5, .light)
      head = (0, 0)
    case .hang:
      dogTail(&c, wag: -1, sit: false)
      dogLegs(&c, phase: 0, legBottom: 25)
      c.ellipse(15.5, 16, 9.5, 5, .gold)
      c.ellipse(15, 19, 6.5, 1.8, .light)
      c.ellipse(21.5, 16.5, 2.8, 3.5, .light)
      head = (0, 0)
    case .sit:
      dogTail(&c, wag: look.wag, sit: true)
      c.rect(21, 15, 22, 23, .dark)
      c.ellipse(11.5, 19.5, 5, 4.5, .gold)
      c.ellipse(15.5, 15.5, 5.5, 6.5, .gold)
      c.ellipse(19, 15, 2.8, 4, .light)
      c.rect(11, 23, 16, 23, .light)
      c.rect(18, 15, 20, 23, .gold)
      c.rect(18, 23, 20, 23, .light)
      head = (-4, -1)
    case .lie:
      dogTail(&c, wag: look.wag, sit: true)
      c.ellipse(14.5, 20, 10, 4.2, .gold)
      c.ellipse(14.5, 21, 5.5, 1.5, .light)
      c.rect(26, 23, 36, 24, .gold)
      c.rect(35, 23, 36, 24, .light)
      head = (0, 8)
    }
    let (dx, dy) = (Double(head.0), Double(head.1))
    // round head + cream muzzle
    c.ellipse(25.5 + dx, 9.5 + dy, 6.2, 5.8, .gold)
    c.ellipse(31 + dx, 11.5 + dy, 3.3, 2.3, .light)
    // long floppy ear with pink inside (the cute napping look)
    let earLong = look.pose == .lie
    c.ellipse(21.5 + dx, 10.5 + dy + (earLong ? 1.5 : 0), 2.4, earLong ? 5.2 : 3.8, .dark)
    c.ellipse(21.5 + dx, 11.2 + dy + (earLong ? 1.8 : 0), 1.2, earLong ? 3.2 : 2.2, .pink)
    // nose
    c.rect(33 + head.0, 10 + head.1, 34 + head.0, 11 + head.1, .black)
    if look.tongue {
      c.rect(30 + head.0, 13 + head.1, 31 + head.0, 15 + head.1, .pink)
    }
    // thin red collar + gold tag
    c.rect(21 + head.0, 14 + head.1, 23 + head.0, 15 + head.1, .red)
    c[22 + head.0, 16 + head.1] = .tag
    return head
  }

  private static func dogTail(_ c: inout Canvas, wag: Int, sit: Bool) {
    let pts: [(Double, Double)] =
      if sit {
        wag <= 0 ? [(7.5, 23), (5.5, 23), (3.5, 22.5)] : [(7.5, 23), (5.5, 22), (4, 20.5)]
      } else {
        switch wag {
        case -1: [(8, 15), (7, 17), (6.5, 19)]
        case 0: [(8, 14), (6.5, 12), (5.5, 10)]
        default: [(8, 14), (6, 13), (4.5, 11.5)]
        }
      }
    for (i, p) in pts.enumerated() {
      let r = 2.0 - Double(i) * 0.25
      c.ellipse(p.0, p.1, r, r, i == pts.count - 1 ? .light : .gold)
    }
  }

  private static func dogLegs(_ c: inout Canvas, phase: Int, legBottom: Int) {
    let (nearBack, farBack, farFront, nearFront) = phase == 0 ? (7, 11, 19, 23) : (10, 8, 22, 20)
    for (x, near) in [(farBack, false), (farFront, false), (nearBack, true), (nearFront, true)] {
      c.rect(x, 17, x + 2, legBottom, near ? .gold : .dark)
      c.rect(x, legBottom, x + 2, legBottom, near ? .light : .dark)
    }
  }

  // MARK: Octopus — chubby pixel blob + stubby legs (same language as the dog)

  private static func drawOctopus(_ c: inout Canvas, _ look: Look) -> (Int, Int) {
    let bob = look.wag > 0 ? 1 : 0
    let headY = 10.0 - Double(bob)
    // four clear stubby tentacles (not a soft jelly fringe)
    let feet: [(Double, Double)] = [(10, 24), (15, 25.5), (21, 25.5), (26, 24)]
    for (i, t) in feet.enumerated() {
      let wave = (look.wag > 0 ? 1.0 : 0) * (i % 2 == 0 ? 1 : -1)
      c.ellipse(t.0 + wave, 19.5, 1.8, 3.2, .purple)
      c.ellipse(t.0 + wave, t.1, 2.2, 2.0, .purple)
      c[Int(t.0 + wave), Int(t.1) + 1] = .pink // sucker
    }
    // round head + lighter belly
    c.ellipse(18, headY, 9.2, 7.5, .purple)
    c.ellipse(18, headY + 2.2, 6.2, 4.2, .pink)
    // tiny collar
    c.rect(15, Int(headY) + 6, 21, Int(headY) + 7, .red)
    c[18, Int(headY) + 8] = .tag
    if look.tongue { c.rect(20, Int(headY) + 3, 21, Int(headY) + 5, .pink) }
    return (-4, Int(headY) - 8)
  }

  // MARK: Bird — tiny chick, same crisp silhouette language

  private static func drawBird(_ c: inout Canvas, _ look: Look) -> (Int, Int) {
    let hop: Int = {
      if case .walk(1) = look.pose { return 1 }
      return 0
    }()
    let bodyY = 16.0 - Double(hop)
    if look.pose == .lie {
      c.ellipse(18, 21, 5.5, 2.8, .yellow)
      c.ellipse(24, 20, 3.5, 2.8, .yellow)
      c.ellipse(24, 20.5, 2, 1.2, .cream)
    } else if look.pose == .hang {
      c.ellipse(18, 13, 5, 4.5, .yellow)
      c.rect(16, 18, 16, 23, .orange)
      c.rect(20, 18, 20, 23, .orange)
    } else {
      c.rect(16, Int(bodyY) + 4, 16, 23, .orange)
      c.rect(20, Int(bodyY) + 4, 20, 23, .orange)
      c.rect(15, 23, 17, 23, .orange)
      c.rect(19, 23, 21, 23, .orange)
      c.ellipse(17.5, bodyY, 5, 4.2, .yellow)
      c.ellipse(17.5, bodyY + 1.2, 2.8, 2.0, .cream)
      let wingUp = look.wag > 0 || hop == 1
      c.ellipse(13, bodyY + (wingUp ? -1.5 : 0.5), 3.0, 2.2, .orange)
    }
    let head = (-5, Int(bodyY) - 12)
    let (dx, dy) = (Double(head.0), Double(head.1))
    c.ellipse(24 + dx, 7.5 + dy, 5.0, 4.8, .yellow)
    c.ellipse(24 + dx, 8.5 + dy, 2.8, 2.2, .cream)
    // stubby beak
    c.rect(29 + head.0, 8 + head.1, 32 + head.0, 9 + head.1, .orange)
    if look.tongue { c[30 + head.0, 10 + head.1] = .pink }
    // little crest
    c[22 + head.0, 2 + head.1] = .orange
    c[23 + head.0, 1 + head.1] = .orange
    c[24 + head.0, 2 + head.1] = .orange
    c.rect(18 + head.0, 12 + head.1, 20 + head.0, 13 + head.1, .red)
    c[19 + head.0, 14 + head.1] = .tag
    return head
  }

  /// Tiny classic eyes + one blush freckle (desktop-pet energy, not sparkle spam).
  private static func drawEyes(_ c: inout Canvas, at o: (x: Int, y: Int), eyes: Eyes, species: Species) {
    let (x, y): (Int, Int) = {
      switch species {
      case .octopus: return (20 + o.x, 7 + o.y)
      case .bird: return (23 + o.x, 6 + o.y)
      case .dog: return (26 + o.x, 8 + o.y)
      }
    }()

    func face(_ ex: Int, _ ey: Int) {
      switch eyes {
      case .open:
        c.rect(ex, ey, ex + 1, ey + 1, .black)
        c[ex + 1, ey] = .white
      case .closed:
        c.rect(ex - 1, ey + 1, ex + 1, ey + 1, .outline)
      case .happy:
        // classic ^ ^
        c[ex - 1, ey + 1] = .outline
        c[ex, ey] = .outline
        c[ex + 1, ey + 1] = .outline
      case .sad:
        c.rect(ex - 1, ey, ex + 1, ey, .outline)
        c.rect(ex, ey + 1, ex + 1, ey + 1, .black)
      case .angry:
        c[ex - 1, ey - 1] = .outline
        c[ex, ey - 1] = .outline
        c.rect(ex, ey, ex + 1, ey + 1, .black)
      }
    }

    face(x, y)
    if species == .octopus { face(x - 7, y) }

    let blush: Px = eyes == .angry ? .red : .pink
    c[x - 1, y + 3] = blush
    c[x, y + 3] = blush
    c[x + 1, y + 4] = blush
    if species == .octopus {
      c[x - 8, y + 3] = blush
      c[x - 7, y + 3] = blush
    }
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
  // Hero: standing pets on a desk edge (the zoomies vibe), dog mid-happy.
  let looks: [Look] = [
    Look(species: .dog, pose: .walk(0), eyes: .happy, tongue: true, wag: 1),
    Look(species: .octopus, pose: .walk(0), eyes: .happy, tongue: true, wag: 1),
    Look(species: .bird, pose: .walk(0), eyes: .happy, tongue: true, wag: 1),
  ]
  let w = 1200, h = 720
  let s = 16
  let ctx = CGContext(
    data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

  // warm desk-sky (flat, not gradient soup)
  ctx.setFillColor(CGColor(red: 0.96, green: 0.90, blue: 0.82, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
  // soft paper clouds (chunky ovals)
  ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.7))
  for cloud in [(140, 560, 70), (420, 610, 55), (780, 540, 80), (1020, 590, 60)] as [(CGFloat, CGFloat, CGFloat)] {
    let (cx, cy, r) = cloud
    ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r * 0.4, width: r * 2, height: r * 0.8))
    ctx.fillEllipse(in: CGRect(x: cx - r * 0.45, y: cy - r * 0.7, width: r, height: r * 0.7))
  }
  // grass strip
  ctx.setFillColor(CGColor(red: 0.48, green: 0.78, blue: 0.48, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: w, height: 140))
  ctx.setFillColor(CGColor(red: 0.40, green: 0.68, blue: 0.40, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: w, height: 52))
  // wood desk lip
  ctx.setFillColor(CGColor(red: 0.72, green: 0.52, blue: 0.32, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: w, height: 28))
  ctx.setFillColor(CGColor(red: 0.58, green: 0.40, blue: 0.24, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: w, height: 10))

  ctx.interpolationQuality = .none
  let petW = CGFloat(Canvas.w * s)
  let petH = CGFloat(Canvas.h * s)
  let gap = (CGFloat(w) - CGFloat(looks.count) * petW) / CGFloat(looks.count + 1)
  var dogOrigin = CGPoint.zero
  for (i, look) in looks.enumerated() {
    let x = gap + CGFloat(i) * (petW + gap)
    let y: CGFloat = 48
    if look.species == .dog { dogOrigin = CGPoint(x: x, y: y) }
    ctx.setFillColor(CGColor(red: 0.25, green: 0.35, blue: 0.2, alpha: 0.22))
    ctx.fillEllipse(in: CGRect(x: x + 28, y: y - 4, width: petW - 56, height: 22))
    // mirror like the live app (face left toward the dock vibe)
    ctx.saveGState()
    ctx.translateBy(x: x + petW, y: y)
    ctx.scaleBy(x: -1, y: 1)
    ctx.draw(Dog.sprite(look).image, in: CGRect(x: 0, y: 0, width: petW, height: petH))
    ctx.restoreGState()
  }

  // speech bubble over the dog — "zoomies!!" (dog faces left after mirror)
  let bw: CGFloat = 220, bh: CGFloat = 64
  let bx = max(24, dogOrigin.x + petW * 0.35 - bw * 0.5)
  let by = dogOrigin.y + petH + 28
  ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
  ctx.setStrokeColor(CGColor(red: 0.29, green: 0.17, blue: 0.07, alpha: 1))
  ctx.setLineWidth(4)
  let bubble = CGRect(x: bx, y: by, width: bw, height: bh)
  let bubblePath = CGPath(roundedRect: bubble, cornerWidth: 18, cornerHeight: 18, transform: nil)
  ctx.addPath(bubblePath)
  ctx.drawPath(using: .fillStroke)
  // little pointer
  ctx.move(to: CGPoint(x: bx + 40, y: by))
  ctx.addLine(to: CGPoint(x: bx + 28, y: by - 16))
  ctx.addLine(to: CGPoint(x: bx + 58, y: by))
  ctx.closePath()
  ctx.drawPath(using: .fillStroke)

  let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = nsCtx
  let text = "zoomies!!" as NSString
  let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont(name: "Helvetica Neue Bold", size: 28) ?? NSFont.boldSystemFont(ofSize: 28),
    .foregroundColor: NSColor(red: 0.29, green: 0.17, blue: 0.07, alpha: 1),
  ]
  let size = text.size(withAttributes: attrs)
  text.draw(at: CGPoint(x: bx + (bw - size.width) / 2, y: by + (bh - size.height) / 2 - 2), withAttributes: attrs)
  NSGraphicsContext.restoreGraphicsState()

  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
  CGImageDestinationFinalize(dest)
}

