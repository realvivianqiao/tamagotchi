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

  // MARK: Dog — dumpling golden retriever, huge head, tiny paws

  private static func drawDog(_ c: inout Canvas, _ look: Look) -> (Int, Int) {
    let head: (Int, Int)
    switch look.pose {
    case .walk(let phase):
      dogTail(&c, wag: look.wag, sit: false)
      dogLegs(&c, phase: phase, legBottom: 23)
      c.ellipse(16, 18, 7.5, 4.2, .gold)
      c.ellipse(16, 19.8, 4.5, 1.5, .cream)
      head = (0, -2)
    case .hang:
      dogTail(&c, wag: -1, sit: false)
      dogLegs(&c, phase: 0, legBottom: 25)
      c.ellipse(16, 17.5, 7.5, 4.2, .gold)
      c.ellipse(16, 19.5, 4.5, 1.5, .cream)
      head = (0, -2)
    case .sit:
      dogTail(&c, wag: look.wag, sit: true)
      // loaf haunch + round tummy
      c.ellipse(12.5, 20.5, 5.2, 3.8, .gold)
      c.ellipse(17, 17.5, 5.5, 5.2, .gold)
      c.ellipse(17.5, 19.5, 3.2, 2.2, .cream)
      c.rect(12, 23, 17, 23, .light)
      c.rect(19, 18, 21, 23, .gold)
      c.rect(19, 23, 21, 23, .light)
      head = (-3, -3)
    case .lie:
      dogTail(&c, wag: look.wag, sit: true)
      c.ellipse(15, 21, 9.5, 3.6, .gold)
      c.ellipse(15, 21.5, 5, 1.6, .cream)
      c.rect(26, 23, 34, 24, .gold)
      head = (0, 6)
    }
    let (dx, dy) = (Double(head.0), Double(head.1))
    // mega round head + soft muzzle
    c.ellipse(25.5 + dx, 8.2 + dy, 8.0, 7.2, .gold)
    c.ellipse(25.5 + dx, 9.5 + dy, 5.5, 4.5, .light)
    c.ellipse(31.5 + dx, 11.2 + dy, 3.8, 2.8, .cream)
    // both floppy ears (front + back)
    c.ellipse(18.5 + dx, 9 + dy, 2.8, 4.6, .dark)
    c.ellipse(18.5 + dx, 9.5 + dy, 1.5, 2.4, .pink)
    c.ellipse(31.5 + dx, 8.2 + dy, 2.4, 3.8, .dark)
    c.ellipse(31.5 + dx, 8.6 + dy, 1.2, 1.8, .pink)
    // heart-ish nose
    c.rect(33 + head.0, 10 + head.1, 34 + head.0, 11 + head.1, .black)
    c[34 + head.0, 9 + head.1] = .black
    if look.tongue {
      c.rect(30 + head.0, 13 + head.1, 31 + head.0, 16 + head.1, .pink)
      c[31 + head.0, 16 + head.1] = .red
    }
    // ribbon collar
    c.rect(21 + head.0, 14 + head.1, 25 + head.0, 15 + head.1, .red)
    c[23 + head.0, 16 + head.1] = .tag
    c[22 + head.0, 16 + head.1] = .tag
    return head
  }

  private static func dogTail(_ c: inout Canvas, wag: Int, sit: Bool) {
    let pts: [(Double, Double)] =
      if sit {
        wag <= 0 ? [(7.5, 22.5), (5, 22), (3, 20.5)] : [(7.5, 22.5), (5, 21), (3.5, 18.5)]
      } else {
        switch wag {
        case -1: [(8, 15), (6.5, 17), (5.5, 19.5)]
        case 0: [(8, 14), (6, 12), (5, 10)]
        default: [(8, 14), (5.5, 12.5), (4, 10.5)]
        }
      }
    for (i, p) in pts.enumerated() {
      let r = 2.2 - Double(i) * 0.3
      c.ellipse(p.0, p.1, r, r, i == pts.count - 1 ? .cream : .gold)
    }
  }

  private static func dogLegs(_ c: inout Canvas, phase: Int, legBottom: Int) {
    let (nearBack, farBack, farFront, nearFront) = phase == 0 ? (8, 12, 20, 24) : (11, 9, 23, 21)
    for (x, near) in [(farBack, false), (farFront, false), (nearBack, true), (nearFront, true)] {
      c.rect(x, 18, x + 2, legBottom, near ? .gold : .dark)
      c.rect(x, legBottom, x + 2, legBottom, .pink) // tiny toe beans
    }
  }

  // MARK: Octopus — round jelly blob, chubby tentacles, heart blush

  private static func drawOctopus(_ c: inout Canvas, _ look: Look) -> (Int, Int) {
    let bob = look.wag > 0 ? 1 : 0
    let headY = 9.5 - Double(bob)
    // curly tentacles with pink suckers
    let curls: [(Double, Double, Double)] = [
      (8.5, 24.5, 1.8), (12, 25.8, 2.0), (16, 26, 2.1), (20.5, 25.8, 2.0), (24.5, 25.5, 1.9), (28.5, 24.2, 1.7),
    ]
    for (i, t) in curls.enumerated() {
      let wave = (look.wag > 0 ? 1.2 : 0) * (i % 2 == 0 ? 1 : -1)
      c.ellipse(t.0 + Double(wave), 18.5, 1.6, 2.6, .purple)
      c.ellipse(t.0 + Double(wave), t.1, t.2, t.2, .purple)
      c.ellipse(t.0 + Double(wave), t.1 + 0.4, t.2 * 0.55, t.2 * 0.55, .pink)
    }
    // rounder dome + belly glow
    c.ellipse(18.5, headY, 10.5, 8.6, .purple)
    c.ellipse(18.5, headY + 2.8, 7.5, 5.2, .pink)
    c.ellipse(18.5, headY + 1.2, 4.5, 3.2, .cream)
    // chubby cheek blush
    c.ellipse(10.5, headY + 1.5, 2.0, 1.5, .pink)
    c.ellipse(26.5, headY + 1.5, 2.0, 1.5, .pink)
    // tiny bow + bell
    c.rect(16, Int(headY) + 6, 21, Int(headY) + 7, .red)
    c[18, Int(headY) + 8] = .tag
    c[19, Int(headY) + 8] = .tag
    if look.tongue { c.rect(21, Int(headY) + 3, 22, Int(headY) + 5, .pink) }
    return (-4, Int(headY) - 8)
  }

  // MARK: Bird — butter chick, melon head, stubby wings

  private static func drawBird(_ c: inout Canvas, _ look: Look) -> (Int, Int) {
    let hop: Int = {
      if case .walk(1) = look.pose { return 1 }
      return 0
    }()
    let bodyY = 16.5 - Double(hop)
    if look.pose == .lie {
      c.ellipse(18, 21.5, 6, 2.6, .yellow)
      c.ellipse(25, 20.5, 4, 2.6, .yellow)
      c.ellipse(25, 20.5, 2.2, 1.4, .cream)
    } else if look.pose == .hang {
      c.ellipse(18, 13.5, 5.5, 4.8, .yellow)
      c.rect(15, 18, 16, 23, .orange)
      c.rect(20, 18, 21, 23, .orange)
    } else {
      // matchstick legs + bean feet
      c.rect(16, Int(bodyY) + 4, 16, 23, .orange)
      c.rect(20, Int(bodyY) + 4, 20, 23, .orange)
      c.rect(14, 23, 17, 23, .orange)
      c.rect(19, 23, 22, 23, .orange)
      c.ellipse(17.5, bodyY, 5.5, 4.5, .yellow)
      c.ellipse(17.5, bodyY + 1, 3.2, 2.4, .cream)
      let wingUp = look.wag > 0 || hop == 1
      c.ellipse(12.5, bodyY + (wingUp ? -2 : 0.2), 3.6, 2.6, .orange)
      c.ellipse(12.5, bodyY + (wingUp ? -2 : 0.2), 1.8, 1.3, .cream)
    }
    let head = (-4, Int(bodyY) - 13)
    let (dx, dy) = (Double(head.0), Double(head.1))
    // giant melon head
    c.ellipse(24 + dx, 7.2 + dy, 6.0, 5.6, .yellow)
    c.ellipse(24 + dx, 8.4 + dy, 3.6, 2.8, .cream)
    // stubby carrot beak
    c.rect(29 + head.0, 8 + head.1, 33 + head.0, 9 + head.1, .orange)
    c[33 + head.0, 8 + head.1] = .orange
    if look.tongue { c[30 + head.0, 10 + head.1] = .pink }
    // fluffy crest
    c[21 + head.0, 2 + head.1] = .orange
    c[22 + head.0, 1 + head.1] = .orange
    c[23 + head.0, 0 + head.1] = .orange
    c[24 + head.0, 1 + head.1] = .orange
    c[25 + head.0, 2 + head.1] = .orange
    // ribbon
    c.rect(18 + head.0, 12 + head.1, 21 + head.0, 13 + head.1, .red)
    c[19 + head.0, 14 + head.1] = .tag
    return head
  }

  /// Oversized kawaii eyes + freckle blush.
  private static func drawEyes(_ c: inout Canvas, at o: (x: Int, y: Int), eyes: Eyes, species: Species) {
    let (x, y): (Int, Int) = {
      switch species {
      case .octopus: return (21 + o.x, 7 + o.y)
      case .bird: return (23 + o.x, 6 + o.y)
      case .dog: return (25 + o.x, 7 + o.y)
      }
    }()

    func sparkle(_ ex: Int, _ ey: Int) {
      switch eyes {
      case .open:
        c.rect(ex - 1, ey - 1, ex + 3, ey + 3, .black)
        c.rect(ex, ey, ex + 2, ey + 2, .black)
        c[ex, ey] = .white
        c[ex + 2, ey] = .white
        c[ex + 1, ey + 2] = .white // tiny lower sparkle
      case .closed:
        c.rect(ex - 1, ey + 1, ex + 3, ey + 1, .outline)
        c[ex, ey] = .outline
        c[ex + 2, ey] = .outline
      case .happy:
        c[ex - 1, ey + 1] = .outline
        c[ex, ey] = .outline
        c[ex + 1, ey] = .outline
        c[ex + 2, ey] = .outline
        c[ex + 3, ey + 1] = .outline
      case .sad:
        c.rect(ex - 1, ey, ex + 3, ey, .outline)
        c.rect(ex, ey + 1, ex + 2, ey + 3, .black)
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
    if species == .octopus { sparkle(x - 8, y) }

    let blush: Px = eyes == .angry ? .red : .pink
    c[x - 3, y + 3] = blush
    c[x - 2, y + 4] = blush
    c[x - 1, y + 4] = blush
    c[x + 3, y + 3] = blush
    c[x + 4, y + 4] = blush
    c[x + 5, y + 4] = blush
    if species == .octopus {
      c[x - 10, y + 3] = blush
      c[x - 9, y + 4] = blush
      c[x + 3, y + 4] = blush
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
  // Full-bleed hero: sky, soft hills, three sit-happy pets.
  let looks = Species.allCases.map { Look(species: $0, pose: .sit, eyes: .happy, tongue: true, wag: 1) }
  let w = 1200, h = 720
  let s = 14
  let ctx = CGContext(
    data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  // soft peach → mint sky
  let colors = [
    CGColor(red: 1.0, green: 0.86, blue: 0.72, alpha: 1),
    CGColor(red: 0.78, green: 0.93, blue: 0.92, alpha: 1),
  ] as CFArray
  let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
  ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
  // clouds
  ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
  for cloud in [(120, 520, 90), (380, 580, 70), (720, 540, 100), (980, 600, 80)] as [(CGFloat, CGFloat, CGFloat)] {
    let (cx, cy, r) = cloud
    ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r * 0.45, width: r * 2, height: r * 0.9))
    ctx.fillEllipse(in: CGRect(x: cx - r * 0.5, y: cy - r * 0.75, width: r * 1.2, height: r * 0.85))
  }
  // grassy hill
  ctx.setFillColor(CGColor(red: 0.55, green: 0.82, blue: 0.55, alpha: 1))
  ctx.fillEllipse(in: CGRect(x: -80, y: -40, width: CGFloat(w) + 160, height: 280))
  ctx.setFillColor(CGColor(red: 0.45, green: 0.72, blue: 0.42, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: w, height: 90))
  // ground stripe
  ctx.setFillColor(CGColor(red: 0.92, green: 0.78, blue: 0.55, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: w, height: 48))

  ctx.interpolationQuality = .none
  let petW = CGFloat(Canvas.w * s)
  let petH = CGFloat(Canvas.h * s)
  let gap = (CGFloat(w) - CGFloat(looks.count) * petW) / CGFloat(looks.count + 1)
  for (i, look) in looks.enumerated() {
    let x = gap + CGFloat(i) * (petW + gap)
    let y: CGFloat = 70
    // soft shadow
    ctx.setFillColor(CGColor(red: 0.35, green: 0.45, blue: 0.3, alpha: 0.25))
    ctx.fillEllipse(in: CGRect(x: x + 20, y: y - 8, width: petW - 40, height: 28))
    ctx.draw(Dog.sprite(look).image, in: CGRect(x: x, y: y, width: petW, height: petH))
  }
  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
  CGImageDestinationFinalize(dest)
}

