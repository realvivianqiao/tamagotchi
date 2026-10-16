import AppKit

/// A friend's pet on your desktop — idle visitor, or a brief cross-screen visit gesture.
@MainActor final class FriendVisitor {
  enum VisitRole {
    /// Friend's pet arrives on *your* screen and acts on you.
    case incomingActor
    /// Friend's pet appears so *your* pet can act on them (local mirror).
    case outgoingTarget
  }

  let code: String
  private(set) var name: String
  private(set) var species: Species
  /// True when this window should auto-dismiss after a visit finishes.
  private(set) var ephemeral = false
  /// Host uses this to freeze wandering so the pair stays face-to-face.
  private(set) var isVisiting = false

  private let window: NSPanel
  private let view = VisitorView()
  private var x: CGFloat
  private var y: CGFloat
  private var dir: CGFloat = -1
  private var activity: Pet.Activity = .sit
  private var activityTicks = 0
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
  /// Raised-paw / special gesture pose for a few frames.
  private var pawTicks = 0
  private var showNameplate = true

  // Visit choreography
  private var visitRole: VisitRole = .incomingActor
  private var visitAction = ""
  private var visitPhase = 0 // 0 approach, 1 gesture, 2 leave
  private var visitTicks = 0
  private var visitLabel: String?
  private var onVisitDone: (() -> Void)?
  private var playKickoffSent = false
  /// Which side of the host we stand on for this visit (locked so we don't flip-flop).
  private var visitSide: CGFloat = 1
  /// Absolute deadline — visit never lingers past this.
  private var visitDeadline: Date?
  private let visitMaxSeconds: TimeInterval = 4.5

  var hostX: (() -> CGFloat)?
  var hostY: (() -> CGFloat)?
  /// Host should start their play animation when the visit reaches the play beat.
  var onPlayWithHost: (() -> Void)?
  /// Fired when the visitor is close and the gesture starts (host should react *now*).
  var onGestureStart: (() -> Void)?
  /// Centers almost overlapping — hip-to-hip, not across the desk.
  private let visitGap: CGFloat = 48

  init(
    code: String, name: String, species: Species, near hostX: CGFloat,
    ephemeral: Bool = false, quiet: Bool = false
  ) {
    self.code = code
    self.name = name
    self.species = species
    self.ephemeral = ephemeral
    // Interaction visitors start "visiting" immediately so idle gap-push never runs.
    self.isVisiting = ephemeral
    let screen = NSScreen.main!.visibleFrame
    let roomRight = screen.maxX - hostX
    let roomLeft = hostX - screen.minX
    visitSide = roomRight >= roomLeft ? 1 : -1
    x = min(max(hostX + visitSide * visitGap, screen.minX + 50), screen.maxX - 50)
    y = screen.minY
    dir = -visitSide
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
    // Don't start the timer until beginVisit — avoids a frame of idle shove.
    if !ephemeral {
      if !quiet {
        say("hi from \(name) \(species.emoji)", seconds: 2.5)
      }
      startTimer()
    }
  }

  private func startTimer() {
    guard timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.step() }
    }
    if let timer {
      RunLoop.main.add(timer, forMode: .common)
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
    hostY = nil
    onPlayWithHost = nil
    onGestureStart = nil
    onVisitDone = nil
    view.visitor = nil
    window.orderOut(nil)
    window.close()
  }

  /// ≤4.5s visit: appear beside host → gesture → leave. Never idles on screen.
  func beginVisit(
    action: String,
    label: String,
    role: VisitRole,
    onDone: (() -> Void)? = nil
  ) {
    isVisiting = true
    visitRole = role
    visitAction = action
    visitPhase = 1 // skip approach — already glued beside host
    visitTicks = 0
    visitLabel = label
    playKickoffSent = false
    onVisitDone = onDone
    untilWoken = false
    showNameplate = true
    visitDeadline = Date().addingTimeInterval(visitMaxSeconds)
    say(label, seconds: 0.9)
    startTimer()
    snapBesideHost()
    render()
    let hx = hostX?() ?? x
    let hy = hostY?() ?? y
    startVisitGesture(hostX: hx, hostY: hy)
  }

  /// Hard-stick to the host’s side so they never look rooms apart.
  private func snapBesideHost() {
    let screen = NSScreen.main!.visibleFrame
    let hx = hostX?() ?? x
    let hy = hostY?() ?? screen.minY
    // Keep the chosen side unless the host is jammed against that edge.
    if visitSide > 0, hx > screen.maxX - 120 { visitSide = -1 }
    if visitSide < 0, hx < screen.minX + 120 { visitSide = 1 }
    x = min(max(hx + visitSide * visitGap, screen.minX + 50), screen.maxX - 50)
    dir = -visitSide
    switch species {
    case .bird: y = hy + 28
    case .octopus: y = max(screen.minY + 14, hy)
    case .dog: y = screen.minY
    }
  }

  /// Local preview of an action you sent (idle visitor, not a full visit).
  func play(_ action: String) {
    if isVisiting { return }
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
    if pawTicks > 0 { pawTicks -= 1 }
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

    if isVisiting {
      stepVisit()
    } else {
      stepIdle()
    }

    if tick % (activity == .run || activity == .fly || pawTicks > 0 ? 7 : 14) == 0 {
      walkFrame ^= 1
    }
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

  private func stepVisit() {
    // Hard cap — never linger past ~4.5s even if a phase stalls.
    if let deadline = visitDeadline, Date() >= deadline {
      finishVisit()
      return
    }
    visitTicks += 1
    let hx = hostX?() ?? x
    let hy = hostY?() ?? y

    switch visitPhase {
    case 1: // gesture — glued beside host the whole time
      snapBesideHost()
      runVisitGestureTick(hostX: hx, hostY: hy)
      if visitTicks == Int(0.8 * fps) {
        bubble = nil
        bubbleTicks = 0
      }
      if visitTicks >= visitGestureDuration {
        visitPhase = 2
        visitTicks = 0
        bubble = nil
        bubbleTicks = 0
        dir = visitSide
        switch species {
        case .dog: set(.run, seconds: 0.5)
        case .bird: set(.fly, seconds: 0.5)
        case .octopus: set(.glide, seconds: 0.5)
        }
      }

    default: // tiny step away, then gone (~0.45s)
      x += visitSide * 8
      if species == .bird { y += 1.6 }
      if visitTicks > Int(0.45 * fps) {
        finishVisit()
        return
      }
    }
  }

  /// Gesture only — total visit stays under visitMaxSeconds with leave.
  private var visitGestureDuration: Int {
    switch visitAction {
    case "play": return Int(2.4 * fps)
    case "nap": return Int(2.0 * fps)
    default: return Int(2.2 * fps)
    }
  }

  private func startVisitGesture(hostX hx: CGFloat, hostY hy: CGFloat) {
    // Host reacts when we’re actually close — not while we’re spawning.
    onGestureStart?()
    switch visitAction {
    case "pet":
      happyTicks = Int(2.5 * fps)
      angryTicks = 0
      switch species {
      case .dog:
        set(.sit, seconds: 2.6)
        pawTicks = Int(2.0 * fps)
        emit("❤️", count: 6)
        hop()
      case .bird:
        set(.fly, seconds: 2.6)
        y = hy + 40
        emit("✨", count: 5)
        emit("❤️", count: 3)
      case .octopus:
        set(.glide, seconds: 2.6)
        emit("🫧", count: 5)
        emit("❤️", count: 3)
      }
    case "poke":
      angryTicks = Int(2.2 * fps)
      happyTicks = 0
      emit("💢", count: 5)
      switch species {
      case .dog:
        set(.run, seconds: 2)
        hop()
      case .bird:
        set(.fly, seconds: 2)
      case .octopus:
        set(.glide, seconds: 2)
        emit("🖤", count: 2)
      }
    case "feed":
      set(.eat, seconds: 2.4)
      switch species {
      case .dog: emit("🍖", count: 3)
      case .bird: emit("seed", count: 4)
      case .octopus: emit("🦀", count: 3)
      }
    case "play":
      signaturePlay(seconds: 2.8)
      emit(species == .dog ? "🎾" : (species == .bird ? "🪶" : "🫧"), count: 3)
      if !playKickoffSent {
        playKickoffSent = true
        onPlayWithHost?()
      }
    case "nap":
      untilWoken = true
      set(.sleep, seconds: 2.2)
      emit("💤", count: 2)
    default:
      set(.sit, seconds: 2)
    }
  }

  private func runVisitGestureTick(hostX hx: CGFloat, hostY hy: CGFloat) {
    switch visitAction {
    case "pet":
      // Bounce into the host — reads as actual pats, not standing still.
      if species == .dog {
        if visitTicks % 10 == 0 {
          hop()
          emit("❤️", count: 2)
          pawTicks = max(pawTicks, 14)
        }
        // Nudge slightly toward host on each pat.
        x += (hx - x) * 0.08
      }
      if species == .bird {
        y = hy + 28 + CGFloat(sin(Double(visitTicks) / 4)) * 10
        x += (hx - x) * 0.1
        if visitTicks % 8 == 0 { emit("❤️"); emit("✨") }
      }
      if species == .octopus {
        y = max(NSScreen.main!.visibleFrame.minY + 12, hy + CGFloat(sin(Double(visitTicks) / 5)) * 8)
        x += (hx - x) * 0.1
        if visitTicks % 9 == 0 { emit("🫧"); emit("❤️") }
      }
    case "play":
      // Stay beside host — little bounces, not a wide orbit across the desk.
      let t = Double(visitTicks) / fps
      x = hx + visitSide * (visitGap + CGFloat(sin(t * 6)) * 10)
      dir = -visitSide
      if species == .bird {
        y = hy + 28 + CGFloat(sin(t * 6)) * 10
      } else if species == .octopus {
        y = max(NSScreen.main!.visibleFrame.minY + 14, hy + CGFloat(sin(t * 4)) * 8)
      } else {
        y = NSScreen.main!.visibleFrame.minY
        if visitTicks % 8 == 0 { hop() }
      }
      if visitTicks % 10 == 0 {
        emit(species == .dog ? "💨" : (species == .bird ? "✨" : "🫧"))
      }
    case "poke":
      if visitTicks % 8 == 0 {
        emit("💢", count: 2)
        hop()
      }
    case "feed":
      if visitTicks % 10 == 0 {
        switch species {
        case .dog: emit("🍖")
        case .bird: emit("seed")
        case .octopus: emit("🦀")
        }
      }
    default:
      break
    }
  }

  private func finishVisit() {
    isVisiting = false
    bubble = nil
    bubbleTicks = 0
    let done = onVisitDone
    onVisitDone = nil
    // Interaction visits always tear down via onDone (Pet clears the visitor).
    done?()
  }

  private func stepIdle() {
    // Ephemeral visitors must never idle-wander on the desk.
    if ephemeral {
      finishVisit()
      return
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

    // Parked (non-ephemeral) visitors keep a gap from the host.
    let parkGap: CGFloat = 260
    if let hx = hostX?(), abs(x - hx) < parkGap {
      dir = x < hx ? -1 : 1
      x += dir * 4
      if activity != .sit && activity != .eat && activity != .sleep {
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
    let happy = !angry && (happyTicks > 0 || activity == .eat || activity == .run || pawTicks > 0)
    var l = Look(species: species)
    if pawTicks > 0, species == .dog {
      // Hang pose reads as a lifted stance — used as the “raise a paw” pat.
      l.pose = .hang
    } else {
      switch activity {
      case .walk, .run, .fly: l.pose = .walk(walkFrame)
      case .glide, .sit, .eat: l.pose = .sit
      case .sleep: l.pose = .lie
      case .held, .fall: l.pose = .hang
      }
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
  fileprivate var drawNameplate: String? {
    guard showNameplate else { return nil }
    // `name` is already "Username's Pad" from the friend bond / visit label.
    return "\(name) \(species.emoji)"
  }
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
    if let plate = visitor.drawNameplate {
      drawNameplate(plate, under: rect)
    }
    if let text = visitor.drawBubble {
      drawBubble(text, at: visitor.headPoint)
    }
  }

  private func drawNameplate(_ text: String, under rect: CGRect) {
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
      .foregroundColor: NSColor(white: 0.12, alpha: 1),
    ]
    let size = (text as NSString).size(withAttributes: attrs)
    var box = CGRect(
      x: rect.midX - size.width / 2 - 6,
      y: rect.maxY + 2,
      width: size.width + 12,
      height: size.height + 4)
    box.origin.x = min(max(box.minX, 2), bounds.width - box.width - 2)
    let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
    NSColor.white.withAlphaComponent(0.92).setFill()
    path.fill()
    NSColor(srgbRed: 0.29, green: 0.17, blue: 0.07, alpha: 0.85).setStroke()
    path.lineWidth = 1
    path.stroke()
    (text as NSString).draw(at: CGPoint(x: box.minX + 6, y: box.minY + 2), withAttributes: attrs)
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
