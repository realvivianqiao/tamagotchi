import AppKit

/// A friend's pet on your desktop — their species, reacts when you interact with them.
@MainActor final class FriendVisitor {
  let code: String
  private(set) var name: String
  private(set) var species: Species

  private let window: NSPanel
  private let view = VisitorView()
  private var x: CGFloat
  private var y: CGFloat
  private var dir: CGFloat = -1
  private var activity: Pet.Activity = .sit
  private var activityTicks = 0
  /// Match host pet: one axis per bout so visitors are grab-able.
  private var wanderHorizontal = true
  private var wanderLock: CGFloat?
  private var tick = 0, walkFrame = 0, happyTicks = 0, angryTicks = 0, blinkTicks = 0, bubbleTicks = 0
  private var untilWoken = false
  private var recentSays: [String] = []
  private var bubble: String?
  private var particles: [Particle] = []
  private var sprite: Sprite
  private var sprites: [Look: Sprite] = [:]
  private var timer: Timer?
  /// Host pet X — keep clear so the two don't stack.
  var hostX: (() -> CGFloat)?
  private let minGap: CGFloat = 260

  init(code: String, name: String, species: Species, near hostX: CGFloat) {
    self.code = code
    self.name = name
    self.species = species
    let screen = NSScreen.main!.visibleFrame
    // Park on the opposite side of the host with a wide gap (windows are ~300pt).
    let preferRight = hostX < screen.midX
    let parked = preferRight ? hostX + 300 : hostX - 300
    x = min(max(parked, screen.minX + 100), screen.maxX - 100)
    y = screen.minY
    dir = preferRight ? -1 : 1 // face toward host
    sprite = Dog.sprite(Look(species: species, pose: .sit))
    window = NSPanel(
      contentRect: CGRect(origin: .zero, size: windowSize), styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.level = .floating
    window.hidesOnDeactivate = false
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    window.contentView = view
    view.visitor = self
    window.orderFrontRegardless()
    say("hi from \(name) \(species.emoji)", seconds: 2.5)
    timer = Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.step() }
    }
  }

  func update(name: String, species: Species) {
    self.name = name
    if self.species != species {
      self.species = species
      sprites.removeAll()
    }
  }

  func dismiss() {
    timer?.invalidate()
    timer = nil
    hostX = nil
    view.visitor = nil
    window.orderOut(nil)
    window.close()
  }

  /// Local preview of an action you sent to this friend.
  func play(_ action: String) {
    switch action {
    case "feed":
      set(.eat, seconds: 3)
      emit("🍖")
      sayFresh(PetLines.feed(species, secondBreakfast: false))
    case "play":
      signaturePlay(seconds: 5)
    case "pet":
      happyTicks = Int(2.5 * fps)
      angryTicks = 0
      emit("❤️", count: 3)
      sayFresh(PetLines.pet(species))
      if activity != .sleep { hop() }
    case "nap":
      untilWoken = true
      set(.sleep, seconds: 9_999)
      sayFresh(["zzz…", "nap time", "night night", "💤", "tucked in", "soft…", "dreaming…", "zzz", "cozy", "sleep mode"])
    case "poke":
      untilWoken = false
      happyTicks = 0
      angryTicks = Int(5 * fps)
      signaturePlayAngry(seconds: 2.5)
      emit("💢", count: 3)
      sayFresh(PetLines.poke(species))
    default:
      break
    }
  }

  private func signaturePlay(seconds: Double) {
    let vf = NSScreen.main!.visibleFrame
    switch species {
    case .dog:
      set(.run, seconds: seconds)
      sayFresh(PetLines.play(.dog))
    case .bird:
      y = vf.minY + 60
      set(.fly, seconds: seconds)
      sayFresh(PetLines.play(.bird))
    case .octopus:
      y = vf.minY + 24
      set(.glide, seconds: seconds)
      sayFresh(PetLines.play(.octopus))
    }
  }

  private func signaturePlayAngry(seconds: Double) {
    let vf = NSScreen.main!.visibleFrame
    switch species {
    case .dog: set(.run, seconds: seconds)
    case .bird:
      y = vf.minY + 60
      set(.fly, seconds: seconds)
    case .octopus:
      y = vf.minY + 24
      set(.glide, seconds: seconds)
    }
  }

  // MARK: - Internals

  private func step() {
    tick += 1
    happyTicks = max(0, happyTicks - 1)
    angryTicks = max(0, angryTicks - 1)
    if blinkTicks > 0 { blinkTicks -= 1 } else if Int.random(in: 0..<150) == 0 { blinkTicks = 4 }
    if bubbleTicks > 0 {
      bubbleTicks -= 1
      if bubbleTicks == 0 { bubble = nil }
    }
    if activity == .sleep {
      let pos = CGPoint(x: headPoint.x - 4, y: headPoint.y + 14)
      if let i = particles.firstIndex(where: { $0.text == "💤" && $0.vel == .zero }) {
        particles[i].pos = pos
        particles[i].life = particles[i].maxLife
      } else {
        particles.removeAll { $0.text == "💤" }
        particles.append(Particle(text: "💤", pos: pos, vel: .zero, life: 9999, maxLife: 9999))
      }
    } else {
      particles.removeAll { $0.text == "💤" && $0.vel == .zero }
    }

    let vf0 = NSScreen.main!.visibleFrame
    switch activity {
    case .walk:
      x += dir * 0.35
      y = vf0.minY
    case .run:
      x += dir * 0.9
      if Int.random(in: 0..<120) == 0 { dir = -dir }
      y = vf0.minY
    case .fly:
      let perch = vf0.minY + 40
      let ceiling = vf0.minY + 140
      if wanderHorizontal {
        x += dir * 0.5
        if let lock = wanderLock { y = lock }
        if Int.random(in: 0..<140) == 0 { dir = -dir }
      } else {
        if let lock = wanderLock { x = lock }
        y += dir * 0.35
        if y <= perch { y = perch; dir = 1 }
        if y >= ceiling { y = ceiling; dir = -1 }
      }
      y = max(perch, min(ceiling, y))
    case .glide:
      if wanderHorizontal {
        x += dir * 0.28
        if let lock = wanderLock { y = lock }
        if Int.random(in: 0..<180) == 0 { dir = -dir }
      } else {
        let low = vf0.minY + 12
        let high = vf0.minY + 70
        if let lock = wanderLock { x = lock }
        y += dir * 0.22
        if y <= low { y = low; dir = 1 }
        if y >= high { y = high; dir = -1 }
      }
    case .sit, .eat, .sleep, .held:
      if activity != .sleep { y = vf0.minY }
    case .fall:
      y = max(vf0.minY, y - 1.5)
      if y <= vf0.minY {
        y = vf0.minY
        set(.sit, seconds: 2)
      }
    }

    // Stay clear of the host pet.
    if let hx = hostX?(), abs(x - hx) < minGap {
      dir = x < hx ? -1 : 1
      x += dir * 4
      if activity == .sit || activity == .eat || activity == .sleep {
        // nudge without breaking nap/eat too hard
      } else {
        set(.walk, seconds: 2)
      }
    }

    let vf = NSScreen.main!.visibleFrame
    let margin = spriteSize.width / 2 - 16
    if x < vf.minX + margin { x = vf.minX + margin; dir = 1 }
    if x > vf.maxX - margin { x = vf.maxX - margin; dir = -1 }

    if activity == .sleep && untilWoken {
      activityTicks = max(activityTicks, Int(60 * fps))
    } else {
      activityTicks -= 1
      if activityTicks <= 0, activity != .fall {
        if activity == .sleep {
          untilWoken = false
          set(.sit, seconds: 2)
        } else if Int.random(in: 0..<3) == 0 {
          // Prefer ground walks (horizontal); rare aerial bout for bird/octopus visitors.
          if species == .bird, Int.random(in: 0..<3) == 0 {
            set(.fly, seconds: Double.random(in: 4...8))
            wanderHorizontal = Int.random(in: 0..<5) != 0
            y = vf.minY + CGFloat.random(in: 60...110)
            wanderLock = wanderHorizontal ? y : x
          } else if species == .octopus, Int.random(in: 0..<3) == 0 {
            set(.glide, seconds: Double.random(in: 4...8))
            wanderHorizontal = Int.random(in: 0..<4) != 0
            y = vf.minY + CGFloat.random(in: 18...40)
            wanderLock = wanderHorizontal ? y : x
          } else {
            set(.walk, seconds: Double.random(in: 3...6))
            wanderHorizontal = true
            wanderLock = nil
          }
          if Bool.random() { dir = -dir }
        } else {
          set(.sit, seconds: Double.random(in: 2...5))
          wanderLock = nil
        }
      }
    }

    if tick % (activity == .run || activity == .fly ? 7 : 14) == 0 { walkFrame ^= 1 }
    for i in particles.indices {
      if particles[i].vel == .zero {
        particles[i].life = particles[i].maxLife
        continue
      }
      particles[i].pos.x += particles[i].vel.dx
      particles[i].pos.y += particles[i].vel.dy
      particles[i].life -= 1
    }
    particles.removeAll { $0.life <= 0 }
    render()
  }

  private func set(_ next: Pet.Activity, seconds: Double) {
    if next != .sleep { untilWoken = false }
    activity = next
    activityTicks = Int(seconds * fps)
  }

  private func hop() {
    activity = .fall
    y += 12
  }

  private func say(_ text: String, seconds: Double = 3.0) {
    bubble = text
    bubbleTicks = Int(seconds * fps)
  }

  private func sayFresh(_ pool: [String], seconds: Double = 3.0) {
    say(PetLines.pick(pool, recent: &recentSays), seconds: seconds)
  }

  private func emit(_ text: String, count: Int = 1) {
    let head = headPoint
    for i in 0..<count {
      particles.append(
        Particle(
          text: text,
          pos: CGPoint(x: head.x - 8 + .random(in: -12...12), y: head.y + CGFloat(i) * 8),
          vel: CGVector(dx: .random(in: -0.4...0.4), dy: .random(in: 0.8...1.4)),
          life: 45, maxLife: 45))
    }
  }

  private var look: Look {
    let angry = angryTicks > 0
    let happy = !angry && (happyTicks > 0 || activity == .eat || activity == .run)
    var l = Look(species: species)
    switch activity {
    case .walk, .run, .fly: l.pose = .walk(walkFrame)
    case .glide, .sit, .eat: l.pose = .sit
    case .sleep: l.pose = .lie
    case .held, .fall: l.pose = .hang
    }
    if activity == .sleep || (blinkTicks > 0 && !angry) {
      l.eyes = .closed
    } else if angry {
      l.eyes = .angry
    } else if happy {
      l.eyes = .happy
    }
    l.tongue = !angry && (activity == .eat ? walkFrame == 0 : happy)
    l.wag = activity == .sleep || angry ? 0 : tick / (happy ? 3 : 10) % 2
    return l
  }

  private func render() {
    let l = look
    if let cached = sprites[l] {
      sprite = cached
    } else {
      sprite = Dog.sprite(l)
      sprites[l] = sprite
    }
    let ground = CGFloat(Canvas.h - 1 - sprite.canvas.bottomRow) * scale
    window.setFrameOrigin(CGPoint(x: (x - windowSize.width / 2).rounded(), y: (y - ground).rounded()))
    view.needsDisplay = true
  }

  var headPoint: CGPoint {
    let col = 25.5 + CGFloat(sprite.head.x), row = 3 + CGFloat(sprite.head.y)
    let mirrored = dir < 0 ? CGFloat(Canvas.w) - col : col
    return CGPoint(x: spriteOrigin.x + mirrored * scale, y: spriteOrigin.y + (CGFloat(Canvas.h) - row) * scale)
  }

  fileprivate var drawDir: CGFloat { dir }
  fileprivate var drawSprite: Sprite { sprite }
  fileprivate var drawBubble: String? { bubble }
  fileprivate var drawParticles: [Particle] { particles }
  fileprivate var drawName: String { "\(name) \(species.emoji)" }
}

@MainActor private final class VisitorView: NSView {
  weak var visitor: FriendVisitor?

  override func draw(_ dirtyRect: NSRect) {
    guard let visitor, let ctx = NSGraphicsContext.current?.cgContext else { return }
    let rect = CGRect(origin: spriteOrigin, size: spriteSize)
    ctx.saveGState()
    ctx.interpolationQuality = .none
    if visitor.drawDir < 0 {
      ctx.translateBy(x: rect.midX, y: 0)
      ctx.scaleBy(x: -1, y: 1)
      ctx.translateBy(x: -rect.midX, y: 0)
    }
    ctx.draw(visitor.drawSprite.image, in: rect)
    ctx.restoreGState()

    for p in visitor.drawParticles {
      let alpha = min(1, Double(p.life) / Double(p.maxLife) * 2)
      (p.text as NSString).draw(
        at: p.pos,
        withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black.withAlphaComponent(alpha)])
    }
    if let text = visitor.drawBubble {
      drawBubble(text, at: visitor.headPoint)
    }
  }

  private func drawBubble(_ text: String, at head: CGPoint) {
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor(white: 0.15, alpha: 1),
    ]
    let size = (text as NSString).size(withAttributes: attrs)
    var box = CGRect(x: head.x - size.width / 2 - 8, y: head.y + 10, width: size.width + 16, height: size.height + 8)
    box.origin.x = min(max(box.minX, 2), bounds.width - box.width - 2)
    let body = NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9)
    NSColor.white.setFill()
    body.fill()
    NSColor(srgbRed: 0.29, green: 0.17, blue: 0.07, alpha: 1).setStroke()
    body.lineWidth = 1.5
    body.stroke()
    (text as NSString).draw(at: CGPoint(x: box.minX + 8, y: box.minY + 4), withAttributes: attrs)
  }
}
