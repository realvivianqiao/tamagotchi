import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Tunables

let defaultPetName = "Mochi"
let scale: CGFloat = 5 // chunkier on-screen = reads cuter
let fps: Double = 30

// MARK: - Pixel canvas

enum Px: UInt8 {
  case outline, gold, light, dark, black, white, pink, red, tag, orange, cream, gray, purple, yellow
}

let palette: [Px: UInt32] = [
  // Softer outline + warmer pastels for a cuter read at small size
  .outline: 0x6B4A32, .gold: 0xF0B85C, .light: 0xFFE6B8, .dark: 0xD4924A,
  .black: 0x2A2220, .white: 0xFFFFFF, .pink: 0xFF9EB5, .red: 0xE85A6A, .tag: 0xFFE066,
  .orange: 0xFFB06B, .cream: 0xFFF0D6, .gray: 0x6E6E6E,
  .purple: 0xD978B0, .yellow: 0xFFE066,
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

  // MARK: Dog — chibi golden, big head, soft cheeks

  private static func drawDog(_ c: inout Canvas, _ look: Look) -> (Int, Int) {
    let head: (Int, Int)
    switch look.pose {
    case .walk(let phase):
      dogTail(&c, wag: look.wag, sit: false)
      dogLegs(&c, phase: phase, legBottom: 23)
      c.ellipse(15.5, 17, 8.5, 4.5, .gold) // smaller body → bigger head feel
      c.ellipse(15, 19.5, 5.5, 1.6, .light)
      c.ellipse(21, 17, 2.5, 3, .light)
      head = (0, -1)
    case .hang:
      dogTail(&c, wag: -1, sit: false)
      dogLegs(&c, phase: 0, legBottom: 25)
      c.ellipse(15.5, 17, 8.5, 4.5, .gold)
      c.ellipse(15, 19.5, 5.5, 1.6, .light)
      head = (0, -1)
    case .sit:
      dogTail(&c, wag: look.wag, sit: true)
      c.rect(20, 16, 22, 23, .dark)
      c.ellipse(12, 20, 4.5, 4, .gold)
      c.ellipse(15.5, 16.5, 5, 5.5, .gold)
      c.ellipse(19, 16, 2.5, 3.5, .light)
      c.rect(11, 23, 16, 23, .light)
      c.rect(18, 16, 20, 23, .gold)
      head = (-4, -2)
    case .lie:
      dogTail(&c, wag: look.wag, sit: true)
      c.ellipse(14.5, 20.5, 9, 3.8, .gold)
      c.rect(26, 23, 35, 24, .gold)
      head = (0, 7)
    }
    let (dx, dy) = (Double(head.0), Double(head.1))
    // oversized round head
    c.ellipse(25.5 + dx, 8.5 + dy, 7.2, 6.5, .gold)
    c.ellipse(31.5 + dx, 11 + dy, 3.6, 2.6, .light)
    if look.tongue { c.rect(30 + head.0, 13 + head.1, 31 + head.0, 16 + head.1, .pink) }
    c.rect(33 + head.0, 10 + head.1, 34 + head.0, 11 + head.1, .black)
    // floppy ear
    c.ellipse(20.5 + dx, 9.5 + dy, 2.6, 4.2, .dark)
    c.ellipse(20.5 + dx, 10 + dy, 1.4, 2.2, .pink) // ear blush
    // tiny bow collar
    c.rect(21 + head.0, 14 + head.1, 24 + head.0, 15 + head.1, .red)
    c[22 + head.0, 16 + head.1] = .tag
    c[23 + head.0, 16 + head.1] = .tag
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

  // MARK: Octopus — soft blob + stubby tentacles + huge eyes

  private static func drawOctopus(_ c: inout Canvas, _ look: Look) -> (Int, Int) {
    let bob = look.wag > 0 ? 1 : 0
    let headY = 10.0 - Double(bob)
    let curls: [(Double, Double, Double)] = [
      (9, 24, 1.6), (12, 25.5, 1.8), (16, 25, 1.7), (20, 25.5, 1.8), (24, 25, 1.7), (28, 24, 1.6),
    ]
    for (i, t) in curls.enumerated() {
      let wave = (look.wag > 0 ? 1 : 0) * (i % 2 == 0 ? 1 : -1)
      c.ellipse(t.0 + Double(wave), 19, 1.4, 2.2, .purple)
      c.ellipse(t.0 + Double(wave), t.1, t.2, t.2, .pink)
    }
    // big soft dome
    c.ellipse(18, headY, 10, 8.2, .purple)
    c.ellipse(18, headY + 2.5, 7, 5, .pink)
    // blush patches on sides of head
    c.ellipse(11, headY + 1, 1.6, 1.2, .pink)
    c.ellipse(25, headY + 1, 1.6, 1.2, .pink)
    // tiny bow
    c.rect(16, Int(headY) + 6, 20, Int(headY) + 7, .red)
    c[18, Int(headY) + 8] = .tag
    if look.tongue { c.rect(21, Int(headY) + 3, 22, Int(headY) + 5, .pink) }
    return (-4, Int(headY) - 8)
  }

  // MARK: Bird — chibi chick, huge head, stubby body

  private static func drawBird(_ c: inout Canvas, _ look: Look) -> (Int, Int) {
    let hop: Int = {
      if case .walk(1) = look.pose { return 1 }
      return 0
    }()
    let bodyY = 16.0 - Double(hop)
    if look.pose == .lie {
      c.ellipse(18, 21, 5.5, 2.8, .yellow)
      c.ellipse(24, 20, 3.5, 2.8, .yellow)
    } else if look.pose == .hang {
      c.ellipse(18, 13, 5, 4.5, .yellow)
      c.rect(16, 18, 16, 23, .orange)
      c.rect(20, 18, 20, 23, .orange)
    } else {
      c.rect(16, Int(bodyY) + 4, 16, 23, .orange)
      c.rect(20, Int(bodyY) + 4, 20, 23, .orange)
      c.rect(15, 23, 17, 23, .orange)
      c.rect(19, 23, 21, 23, .orange)
      // tiny round body
      c.ellipse(17.5, bodyY, 5, 4.2, .yellow)
      let wingUp = look.wag > 0 || hop == 1
      c.ellipse(13, bodyY + (wingUp ? -1.5 : 0.5), 3.2, 2.4, .orange)
      c.ellipse(13, bodyY + (wingUp ? -1.5 : 0.5), 1.6, 1.2, .cream)
    }
    let head = (-5, Int(bodyY) - 12)
    let (dx, dy) = (Double(head.0), Double(head.1))
    // oversized head
    c.ellipse(24 + dx, 7.5 + dy, 5.2, 5, .yellow)
    c.ellipse(24 + dx, 8.5 + dy, 3, 2.5, .cream) // soft cheek
    // stubby beak
    c.rect(29 + head.0, 8 + head.1, 32 + head.0, 9 + head.1, .orange)
    c[32 + head.0, 8 + head.1] = .orange
    if look.tongue { c[30 + head.0, 10 + head.1] = .pink }
    // tiny fluff crest
    c[22 + head.0, 2 + head.1] = .orange
    c[23 + head.0, 1 + head.1] = .orange
    c[24 + head.0, 2 + head.1] = .orange
    c.rect(18 + head.0, 12 + head.1, 20 + head.0, 13 + head.1, .red)
    c[19 + head.0, 14 + head.1] = .tag
    return head
  }

  /// Big sparkly kawaii eyes + double blush for every species.
  private static func drawEyes(_ c: inout Canvas, at o: (x: Int, y: Int), eyes: Eyes, species: Species) {
    let (x, y): (Int, Int) = {
      switch species {
      case .octopus: return (20 + o.x, 7 + o.y)
      case .bird: return (23 + o.x, 6 + o.y)
      case .dog: return (25 + o.x, 7 + o.y)
      }
    }()

    func sparkle(_ ex: Int, _ ey: Int) {
      switch eyes {
      case .open:
        c.rect(ex, ey, ex + 2, ey + 2, .black)
        c[ex, ey] = .white
        c[ex + 2, ey] = .white
      case .closed:
        c.rect(ex - 1, ey + 1, ex + 2, ey + 1, .outline)
      case .happy:
        c[ex - 1, ey + 1] = .outline
        c[ex, ey] = .outline
        c[ex + 1, ey] = .outline
        c[ex + 2, ey + 1] = .outline
      case .sad:
        c.rect(ex - 1, ey, ex + 2, ey, .outline)
        c.rect(ex, ey + 1, ex + 2, ey + 2, .black)
        c[ex, ey + 1] = .white
      case .angry:
        c[ex - 1, ey - 1] = .outline
        c[ex, ey - 1] = .outline
        c[ex + 1, ey - 2] = .outline
        c.rect(ex, ey, ex + 2, ey + 2, .black)
        c[ex, ey] = .white
      }
    }

    sparkle(x, y)
    if species == .octopus { sparkle(x - 7, y) } // second big eye

    // double blush cheeks
    let blush: Px = eyes == .angry ? .red : .pink
    c[x - 2, y + 3] = blush
    c[x - 1, y + 4] = blush
    c[x + 3, y + 3] = blush
    c[x + 4, y + 4] = blush
    if species == .octopus {
      c[x - 9, y + 3] = blush
      c[x + 3, y + 3] = blush
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
  // Species picker lineup — actual in-app sprites.
  let looks = Species.allCases.map { Look(species: $0, pose: .sit, eyes: .happy, tongue: true, wag: 1) }
  let s = 10, pad = 24, labelH = 28
  let cellW = Canvas.w * s + pad
  let cellH = Canvas.h * s + labelH
  let ctx = CGContext(
    data: nil, width: looks.count * cellW + pad, height: cellH + 2 * pad, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.setFillColor(CGColor(red: 0.86, green: 0.92, blue: 1, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
  ctx.interpolationQuality = .none
  for (i, look) in looks.enumerated() {
    let x = pad + i * cellW
    let y = pad + labelH
    ctx.draw(Dog.sprite(look).image, in: CGRect(x: x, y: y, width: Canvas.w * s, height: Canvas.h * s))
  }
  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
  CGImageDestinationFinalize(dest)
}

