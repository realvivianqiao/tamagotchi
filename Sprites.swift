import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Tunables

let defaultPetName = "CoPet"
let scale: CGFloat = 4 // exact zoomies-dog size on the dock
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
  // soft lavender octopus (matches the blub-blub look)
  .purple: 0xC9AEE3, .yellow: 0xFFD45A,
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

  /// Basic default display name when you pick this pet.
  var defaultName: String {
    switch self {
    case .dog: "Zuzu"
    case .octopus: "Bloop"
    case .bird: "Puff"
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

  // MARK: Dog — exact original zoomies golden (do not "improve")

  private static func drawDog(_ c: inout Canvas, _ look: Look) -> (Int, Int) {
    let head: (Int, Int)
    switch look.pose {
    case .walk(let phase):
      dogTail(&c, look.wag, sit: false)
      dogLegs(&c, phase: phase, legBottom: 23)
      c.ellipse(15.5, 16, 9.5, 5, .gold)
      c.ellipse(15, 19, 6.5, 1.8, .light)
      c.ellipse(21.5, 16.5, 2.8, 3.5, .light)
      head = (0, 0)
    case .hang:
      dogTail(&c, -1, sit: false)
      dogLegs(&c, phase: 0, legBottom: 25)
      c.ellipse(15.5, 16, 9.5, 5, .gold)
      c.ellipse(15, 19, 6.5, 1.8, .light)
      c.ellipse(21.5, 16.5, 2.8, 3.5, .light)
      head = (0, 0)
    case .sit:
      dogTail(&c, look.wag, sit: true)
      c.rect(21, 15, 22, 23, .dark)
      c.ellipse(11.5, 19.5, 5, 4.5, .gold)
      c.ellipse(15.5, 15.5, 5.5, 6.5, .gold)
      c.ellipse(19, 15, 2.8, 4, .light)
      c.rect(11, 23, 16, 23, .light)
      c.rect(18, 15, 20, 23, .gold)
      c.rect(18, 23, 20, 23, .light)
      head = (-4, -1)
    case .lie:
      dogTail(&c, look.wag, sit: true)
      c.ellipse(14.5, 20, 10, 4.2, .gold)
      c.rect(26, 23, 36, 24, .gold)
      c.rect(35, 23, 36, 24, .light)
      head = (0, 8)
    }
    let (dx, dy) = (Double(head.0), Double(head.1))
    c.ellipse(25.5 + dx, 9.5 + dy, 6.2, 5.8, .gold)
    c.ellipse(31 + dx, 11.5 + dy, 3.3, 2.3, .light)
    if look.tongue { c.rect(30 + head.0, 13 + head.1, 31 + head.0, 15 + head.1, .pink) }
    c.rect(33 + head.0, 10 + head.1, 34 + head.0, 11 + head.1, .black)
    c.rect(21 + head.0, 14 + head.1, 23 + head.0, 15 + head.1, .red)
    c[22 + head.0, 16 + head.1] = .tag
    c.ellipse(21.5 + dx, 10.5 + dy, 2.2, 3.8, .dark)
    return head
  }

  private static func dogTail(_ c: inout Canvas, _ wag: Int, sit: Bool) {
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

  // MARK: Octopus — stubby lavender blob (front-facing, blub-blub look)

  private static func drawOctopus(_ c: inout Canvas, _ look: Look) -> (Int, Int) {
    let bob = look.wag > 0 ? 1 : 0
    let (bodyY, footY): (Double, Double) = {
      switch look.pose {
      case .lie: return (17.5, 23.5)
      case .hang: return (11.0, 22.0)
      default: return (11.0 - Double(bob), 23.5)
      }
    }()

    // five short flat tentacles (sitting on the ground)
    let feetX = [9.5, 13.5, 17.5, 21.5, 25.5]
    for (i, fx) in feetX.enumerated() {
      let wave = (look.wag > 0 ? 0.8 : 0) * (i % 2 == 0 ? 1 : -1)
      c.ellipse(fx + wave, footY - 1.2, 1.9, 2.2, .purple)
      c.ellipse(fx + wave, footY + 0.4, 2.1, 1.5, .purple)
    }

    // big round head
    c.ellipse(17.5, bodyY, 9.8, 8.6, .purple)
    // soft highlight on top (same family as the body — no sticker look)
    c.ellipse(14.8, bodyY - 3.5, 3.0, 1.8, .pink)

    if look.tongue {
      c.rect(18, Int(bodyY) + 3, 19, Int(bodyY) + 5, .pink)
    }
    // head offset so drawEyes lands on the face center
    return (0, Int(bodyY) - 8)
  }

  // MARK: Bird — front-facing yellow chick (plump, cream belly, tiny tuft)

  private static func drawBird(_ c: inout Canvas, _ look: Look) -> (Int, Int) {
    let hop: Int = {
      if case .walk(1) = look.pose { return 1 }
      return 0
    }()
    let (bodyY, footY): (Double, Int) = {
      switch look.pose {
      case .lie: return (18.5, 24)
      case .hang: return (12.0, 23)
      default: return (13.5 - Double(hop), 24)
      }
    }()

    if look.pose == .lie {
      // loafed chick
      c.ellipse(17.5, bodyY, 9.0, 4.2, .yellow)
      c.ellipse(17.5, bodyY + 0.8, 5.0, 2.2, .cream)
      c.rect(13, footY, 15, footY, .orange)
      c.rect(20, footY, 22, footY, .orange)
    } else {
      // little orange feet
      c.rect(14, footY, 16, footY, .orange)
      c.rect(15, footY - 1, 15, footY - 1, .orange)
      c.rect(19, footY, 21, footY, .orange)
      c.rect(20, footY - 1, 20, footY - 1, .orange)

      // plump round body
      c.ellipse(17.5, bodyY, 8.6, 8.2, .yellow)
      // cream belly
      c.ellipse(17.5, bodyY + 2.4, 4.6, 3.4, .cream)

      // stubby yellow side wings
      let wingUp = look.wag > 0 || hop == 1
      let wy = bodyY + (wingUp ? -1.2 : 0.8)
      c.ellipse(9.2, wy, 2.8, 2.6, .yellow)
      c.ellipse(25.8, wy, 2.8, 2.6, .yellow)
    }

    // tiny tuft on top
    let tuftY = Int(bodyY - 8.6)
    c[17, tuftY] = .yellow
    c[17, tuftY - 1] = .yellow
    c[16, tuftY] = .yellow
    c[18, tuftY] = .yellow

    // little orange triangle beak between the eyes
    let by = Int(bodyY) - 1
    c[17, by] = .orange
    c[16, by + 1] = .orange
    c[17, by + 1] = .orange
    c[18, by + 1] = .orange
    c[17, by + 2] = .orange
    if look.tongue { c[17, by + 3] = .pink }

    return (0, Int(bodyY) - 9)
  }

  /// Dog: side face. Octopus / bird: front-facing kawaii faces.
  private static func drawEyes(_ c: inout Canvas, at o: (x: Int, y: Int), eyes: Eyes, species: Species) {
    let (x, y): (Int, Int) = {
      switch species {
      case .octopus: return (20 + o.x, 8 + o.y) // right eye; left is x-6
      case .bird: return (21 + o.x, 7 + o.y) // right eye; left is x-7
      case .dog: return (26 + o.x, 8 + o.y)
      }
    }()

    func face(_ ex: Int, _ ey: Int) {
      switch eyes {
      case .open:
        if species == .octopus {
          c.rect(ex, ey, ex, ey, .black)
        } else if species == .bird {
          // 2×2 black eyes with white sparkle in the corner
          c.rect(ex, ey, ex + 1, ey + 1, .black)
          c[ex, ey] = .white
        } else {
          c.rect(ex, ey, ex + 1, ey + 1, .black)
          c[ex + 1, ey] = .white
        }
      case .closed:
        c.rect(ex - 1, ey + 1, ex + 1, ey + 1, .outline)
      case .happy:
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

    let blush: Px = eyes == .angry ? .red : .pink
    switch species {
    case .octopus:
      face(x, y)
      face(x - 6, y)
      if eyes != .angry {
        c[x - 3, y + 3] = .black
        c[x - 4, y + 2] = .black
        c[x - 2, y + 2] = .black
      }
      c[x - 7, y + 3] = blush
      c[x + 1, y + 3] = blush
    case .bird:
      face(x, y)
      face(x - 7, y)
      // pink cheek dashes under each eye
      c[x - 9, y + 3] = blush
      c[x - 8, y + 3] = blush
      c[x + 2, y + 3] = blush
      c[x + 3, y + 3] = blush
    case .dog:
      face(x, y)
      c[x, y + 3] = blush
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
  // Clean hero art: three pets fully in frame — no bubbles (site lays out text separately).
  let looks: [Look] = [
    Look(species: .dog, pose: .walk(0), eyes: .happy, tongue: true, wag: 1),
    Look(species: .octopus, pose: .walk(0), eyes: .happy, tongue: true, wag: 1),
    Look(species: .bird, pose: .walk(0), eyes: .happy, tongue: true, wag: 1),
  ]
  let w = 1200, h = 640
  let s = 12
  let ctx = CGContext(
    data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

  ctx.setFillColor(CGColor(red: 0.98, green: 0.95, blue: 0.90, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
  // soft ground
  ctx.setFillColor(CGColor(red: 0.55, green: 0.80, blue: 0.55, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: w, height: 96))
  ctx.setFillColor(CGColor(red: 0.72, green: 0.55, blue: 0.35, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: w, height: 18))

  ctx.interpolationQuality = .none
  let petW = CGFloat(Canvas.w * s), petH = CGFloat(Canvas.h * s)
  let total = CGFloat(looks.count) * petW
  let gap = (CGFloat(w) - total) / CGFloat(looks.count + 1)
  let y: CGFloat = 48
  for (i, look) in looks.enumerated() {
    let x = gap + CGFloat(i) * (petW + gap)
    ctx.setFillColor(CGColor(red: 0.3, green: 0.4, blue: 0.25, alpha: 0.18))
    ctx.fillEllipse(in: CGRect(x: x + 24, y: y - 6, width: petW - 48, height: 20))
    ctx.saveGState()
    ctx.translateBy(x: x + petW, y: y)
    ctx.scaleBy(x: -1, y: 1)
    ctx.draw(Dog.sprite(look).image, in: CGRect(x: 0, y: 0, width: petW, height: petH))
    ctx.restoreGState()
  }

  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
  CGImageDestinationFinalize(dest)
}

