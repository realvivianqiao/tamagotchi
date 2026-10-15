import AppKit

// MARK: - Pet brain

@MainActor final class Pet: NSObject, NSMenuDelegate {
  enum Activity { case walk, run, sit, sleep, eat, held, fall, roll, fly, glide, moo }

  let menu = NSMenu()
  private let window: NSPanel
  private let view = PetView()
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

  private var x: CGFloat
  private var y: CGFloat
  private var vx: CGFloat = 0, vy: CGFloat = 0
  private(set) var dir: CGFloat = 1
  private var activity = Activity.fall
  private var activityTicks = 0
  private var targetX: CGFloat?
  private var tick = 0, walkFrame = 0, happyTicks = 0, angryTicks = 0, blinkTicks = 0, bubbleTicks = 0
  private var greeted = false

  private(set) var bubble: String?
  private(set) var particles: [Particle] = []
  private var species: Species = Online.shared.mySpecies
  private(set) var sprite = Dog.sprite(Look(species: Online.shared.mySpecies))
  private var sprites: [Look: Sprite] = [:]

  private var fullness: Double
  private var happiness: Double
  private var petName = defaultPetName
  private var applyingRemote = false
  private var onlineNote: String?
  private var hidden = false
  /// User (or partner) put them to sleep — stay asleep until Wake up.
  private var untilWoken = false
  /// Friend's pet visiting your desktop (their species + reactions).
  private var visitor: FriendVisitor?

  private var grabStart = CGPoint.zero, lastMouse = CGPoint.zero, grabOffset = CGPoint.zero
  private var lastDragTime: TimeInterval = 0
  private var throwVelocity = CGVector.zero
  private var dragged = false

  override init() {
    let screen = NSScreen.main!.visibleFrame
    x = screen.midX
    y = screen.maxY - 40
    (fullness, happiness) = Self.loadStats()
    window = NSPanel(
      contentRect: CGRect(origin: .zero, size: windowSize), styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    super.init()

    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.level = .floating
    window.hidesOnDeactivate = false
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    window.contentView = view
    view.pet = self

    statusItem.button?.title = species.emoji
    statusItem.menu = menu
    menu.delegate = self
    wireOnline()

    // First download / fresh install: pick Dog, Black Cat, Octopus, Cow, or Bird.
    if !PetPicker.hasChosen {
      let pick = PetPicker.runModal()
      species = pick
      sprites.removeAll()
      statusItem.button?.title = pick.emoji
      say("hi! i'm a \(pick.title) \(pick.emoji)", seconds: 3.5)
    }

    window.orderFrontRegardless()

    let timer = Timer(timeInterval: 1 / fps, target: self, selector: #selector(step), userInfo: nil, repeats: true)
    RunLoop.main.add(timer, forMode: .common)
  }

  private var partnerWasOnline = false

  private func wireOnline() {
    Online.shared.onStatus = { [weak self] text in
      self?.onlineNote = text
    }
    Online.shared.onFriendsChanged = { [weak self] in
      self?.refreshStatusItem()
      self?.syncVisitorFromFriends()
    }
    Online.shared.onPresence = { [weak self] in
      guard let self else { return }
      self.refreshStatusItem()
      // Dog on screen is always yours — never rename to the friend.
      let online = Online.shared.partnerOnline
      if online && !self.partnerWasOnline, let partner = Online.shared.partner, !self.hidden {
        self.say("\(partner) is online! 🟢", seconds: 2.5)
      } else if !online && self.partnerWasOnline, let partner = Online.shared.partner, !self.hidden {
        self.say("\(partner) went offline 💤", seconds: 2)
      }
      self.partnerWasOnline = online
    }
    // Friend sent an action at *you* — your dog reacts. Their stats stay on FriendBond only.
    Online.shared.onSync = { [weak self] _, _, action, from in
      guard let self, let action, !self.hidden else { return }
      self.applyingRemote = true
      self.playRemote(action)
      let who = from.isEmpty ? "friend" : from
      let line: String =
        switch action {
        case "feed": "\(who) fed you! 🦴"
        case "play": "\(who) wants to play! 🎾"
        case "pet": "\(who) pet you! ❤️"
        case "nap": "\(who) tucked you in 💤"
        case "poke": "\(who) poked you! 💢"
        default: "\(who) → \(action)"
        }
      self.say(line, seconds: 2.5)
      self.applyingRemote = false
      self.save()
    }
    Online.shared.restoreBondIfAny()
  }

  private func refreshStatusItem() {
    if hidden {
      statusItem.button?.title = "😴"
      return
    }
    let onlineCount = Online.shared.friends.filter { $0.online && !$0.waiting }.count
    statusItem.button?.title = onlineCount > 0 ? "\(species.emoji)🟢" : species.emoji
  }

  private func playRemote(_ action: String) {
    switch action {
    case "feed":
      fullness = min(100, fullness + 35)
      happiness = min(100, happiness + 4)
      set(.eat, seconds: 3)
      emit("🦴")
    case "play":
      happiness = min(100, happiness + 12)
      startSignatureMove(seconds: 6)
    case "pet":
      happiness = min(100, happiness + 6)
      happyTicks = Int(2 * fps)
      emit("❤️", count: 3)
      if activity != .sleep && !untilWoken { hop() }
    case "nap":
      untilWoken = true
      set(.sleep, seconds: 9_999)
    case "poke":
      getAngry(fromPoke: true)
    default:
      break
    }
  }

  private func pushOnline(action: String? = nil) {
    guard !applyingRemote, Online.shared.isBonded else { return }
    Online.shared.sync(fullness: fullness, happiness: happiness, action: action)
  }

  // MARK: Loop

  @objc private func step() {
    tick += 1
    decay()
    guard !hidden else { return }
    move(in: screenFrame())
    animate()
    updateParticles()
    chatter()
    render()
  }

  private func move(in vf: CGRect) {
    switch activity {
    case .walk:
      if let t = targetX {
        dir = t > x ? 1 : -1
        if abs(t - x) < 3 {
          targetX = nil
          emit("❤️")
          set(.sit, seconds: 3)
        }
      }
      x += dir * walkSpeed
      // Bird “hops” on the ground; cow barely shuffles; octopus prefers not to walk.
      if species == .bird, activity == .walk {
        y = vf.minY + (walkFrame == 0 ? 0 : 6)
      }
    case .run: // dog chase / rare cat zoomies
      x += dir * (species == .cat ? 6.5 : 5)
      if Int.random(in: 0..<(species == .cat ? 25 : 50)) == 0 { dir = -dir }
      y = vf.minY
    case .roll: // cat belly-roll tumble
      x += dir * 2.6
      if Int.random(in: 0..<40) == 0 { dir = -dir }
      y = vf.minY
    case .fly: // bird soars between perch heights
      x += dir * 3.2
      let ceiling = vf.minY + min(200, vf.height * 0.55)
      let perch = vf.minY + 55
      y += CGFloat(sin(Double(tick) / 6.0)) * 2.0
      if tick % 50 == 0 { y += CGFloat.random(in: -20...25) }
      y = min(max(y, perch), ceiling)
      if Int.random(in: 0..<45) == 0 { dir = -dir }
    case .glide: // octopus drifts like it’s in water
      x += dir * 0.9
      y = vf.minY + 28 + CGFloat(sin(Double(tick) / 18.0)) * 14
      if Int.random(in: 0..<100) == 0 { dir = -dir }
      if tick % 55 == 0 { emit(["💧", "🫧"].randomElement()!) }
    case .moo: // cow plants feet and hollers
      y = vf.minY
      if tick % 36 == 0 {
        emit(["💬", "🌾"].randomElement()!)
        say(["moo~", "MOO!", "mooo…", "*chew*"].randomElement()!)
      }
    case .fall:
      vy -= species == .bird ? 0.7 : 1.1 // birds flutter-fall
      if species == .bird { vx *= 0.98 }
      x += vx
      y += vy
      if y <= restFloor(in: vf) {
        y = restFloor(in: vf)
        land(impact: vy)
      }
    case .sleep:
      y = sleepFloor(in: vf)
      vx = 0
      vy = 0
    case .held:
      break
    case .sit, .eat:
      y = restFloor(in: vf)
      // cow chews; cat loafs (still); dog pants; bird pecks in place
      if activity == .eat, tick % 12 == 0, species == .bird { emit("seed") }
      if activity == .eat, tick % 20 == 0, species == .cow { emit("🌾") }
      if activity == .sit, species == .cat, tick % 90 == 0, bubble == nil {
        say(["mrrrp", "…", "loaf."].randomElement()!, seconds: 1.2)
      }
    }
    guard activity != .held else { return }

    let margin = spriteSize.width / 2 - 16
    if x < vf.minX + margin {
      x = vf.minX + margin
      dir = 1
      vx = abs(vx) * 0.6
    }
    if x > vf.maxX - margin {
      x = vf.maxX - margin
      dir = -1
      vx = -abs(vx) * 0.6
    }
    pinToHabitat(in: vf)
  }

  /// Where this species likes to rest (birds perch, octopus hovers).
  private func restFloor(in vf: CGRect) -> CGFloat {
    switch species {
    case .bird: return vf.minY + 72
    case .octopus: return vf.minY + 20
    default: return vf.minY
    }
  }

  private func sleepFloor(in vf: CGRect) -> CGFloat {
    switch species {
    case .bird: return vf.minY + 90 // roost up high
    case .octopus: return vf.minY + 8 // settle near sand
    default: return vf.minY
    }
  }

  private func pinToHabitat(in vf: CGRect) {
    if activity == .sleep || untilWoken {
      y = sleepFloor(in: vf)
      return
    }
    switch activity {
    case .fly, .glide, .held, .fall:
      return
    case .sit, .eat, .moo:
      y = restFloor(in: vf)
    case .walk:
      if species == .octopus {
        y = restFloor(in: vf) // they'd rather hover than walk
      } else if species == .bird {
        // hop height set in walk case
      } else if y > vf.minY + 0.5 {
        startFall(vx: 0, vy: 0)
      } else {
        y = vf.minY
      }
    case .run, .roll:
      y = vf.minY
    default:
      break
    }
  }

  private var walkSpeed: CGFloat {
    switch species {
    case .cow: return 0.85 // grazing shuffle
    case .cat: return 1.6 // sneaky trot
    case .bird: return 1.4 // hop-walk
    case .octopus: return 0.6 // awkward on “land”
    case .dog: return fullness < 20 ? 1.0 : 1.9
    }
  }

  private func animate() {
    let flapFast = activity == .run || activity == .fly || activity == .roll
    if tick % (flapFast ? 3 : 7) == 0 { walkFrame ^= 1 }
    happyTicks = max(0, happyTicks - 1)
    angryTicks = max(0, angryTicks - 1)
    if blinkTicks > 0 { blinkTicks -= 1 } else if Int.random(in: 0..<150) == 0 { blinkTicks = 4 }
    if bubbleTicks > 0 {
      bubbleTicks -= 1
      if bubbleTicks == 0 { bubble = nil }
    }
    if activity == .sleep && tick % 45 == 0 {
      emit(species == .bird ? "💤" : species == .octopus ? "🫧" : "💤")
    }
    if activity == .fly && tick % 22 == 0 { emit(["🪶", "✨"].randomElement()!) }
    if activity == .roll && tick % 18 == 0 { emit("🌀") }
    if activity == .run && species == .dog && tick % 25 == 0 { emit("💨") }

    if activity == .sleep && untilWoken {
      activityTicks = max(activityTicks, Int(60 * fps)) // keep ticking forever while napping
      return
    }
    activityTicks -= 1
    guard activityTicks <= 0, activity != .held, activity != .fall else { return }
    if activity == .sleep {
      untilWoken = false
      set(.sit, seconds: 2)
      say("🥱")
    } else {
      chooseNext()
    }
  }

  private func chooseNext() {
    let hour = Calendar.current.component(.hour, from: Date())
    let sleepy = hour >= 23 || hour < 7 || fullness < 15
    let options: [(Activity, Int)] = speciesIdleOptions(sleepy: sleepy)
    var roll = Int.random(in: 0..<options.reduce(0) { $0 + $1.1 })
    let next = options.first { roll -= $0.1; return roll < 0 }!.0
    if next == .walk || next == .roll || next == .fly || next == .glide, Bool.random() { dir = -dir }
    let seconds: ClosedRange<Double> =
      switch next {
      case .walk: species == .cow ? 4...8 : 3...9
      case .run: 2...4
      case .roll: 2.5...5
      case .fly: 4...9
      case .glide: 4...8
      case .moo: 2...3.5
      case .sleep: 20...45
      default: 2...6
      }
    set(next, seconds: .random(in: seconds))
    // Settle into the right height for this mood.
    let vf = screenFrame()
    switch next {
    case .fly:
      y = vf.minY + CGFloat.random(in: 70...130)
      say(["chirp!", "↑ tweet", "wind~"].randomElement()!)
    case .glide:
      y = restFloor(in: vf)
      if Bool.random() { say(["…", "bloop", "🫧"].randomElement()!) }
    case .roll:
      say(["nya~", "tumble!", "hehe"].randomElement()!)
    case .moo:
      say(["moo~", "*cud*", "🌾"].randomElement()!)
    case .run where species == .dog:
      if Bool.random() { say(["zoom!", "bark!", "🎾"].randomElement()!) }
    case .run where species == .cat:
      say(["ZOOMIES", "mrrp!!"].randomElement()!)
    case .sit where species == .cat:
      if Bool.random() { say("loaf.", seconds: 1.2) }
    default:
      break
    }
  }

  private func speciesIdleOptions(sleepy: Bool) -> [(Activity, Int)] {
    switch species {
    case .dog: // loyal energy — walk + occasional sprint
      return [(.walk, 48), (.sit, 18), (.sleep, sleepy ? 35 : 5), (.run, happiness > 55 ? 22 : 6)]
    case .cat: // loaf a lot, sneak, rare roll, sudden zoomies
      return [
        (.sit, 40), (.sleep, sleepy ? 40 : 12), (.walk, 18),
        (.roll, 8), (.run, happiness > 70 ? 10 : 2),
      ]
    case .cow: // chill grazer — almost never rushes
      return [(.sit, 42), (.walk, 28), (.moo, 14), (.sleep, sleepy ? 35 : 10)]
    case .bird: // lives in the air; ground is temporary
      return [(.fly, 55), (.sit, 18), (.walk, 8), (.sleep, sleepy ? 25 : 4)]
    case .octopus: // water creature — drift + rest, skip “walking”
      return [(.glide, 50), (.sit, 28), (.sleep, sleepy ? 22 : 6)]
    }
  }

  private func set(_ next: Activity, seconds: Double) {
    if next != .sleep { untilWoken = false }
    activity = next
    activityTicks = Int(seconds * fps)
  }

  private func startFall(vx: CGFloat, vy: CGFloat) {
    // Accidental micro-falls must not end a nap.
    if untilWoken, abs(vx) < 1, abs(vy) < 1 {
      y = screenFrame().minY
      self.vx = 0
      self.vy = 0
      activity = .sleep
      return
    }
    self.vx = vx
    self.vy = vy
    activity = .fall
  }

  private func hop() {
    targetX = nil
    startFall(vx: 0, vy: 7)
  }

  private func land(impact: CGFloat) {
    vx = 0
    vy = 0
    let vf = screenFrame()
    if untilWoken {
      activity = .sleep
      activityTicks = Int(9_999 * fps)
      y = sleepFloor(in: vf)
      return
    }
    y = restFloor(in: vf)
    set(.sit, seconds: happyTicks > 0 ? 1.5 : 1)
    if !greeted {
      greeted = true
      let hi: String =
        switch species {
        case .dog: "hi! i'm \(petName) 🐶"
        case .cat: "…oh. i'm \(petName) 🐈‍⬛"
        case .cow: "moo. i'm \(petName) 🐮"
        case .bird: "chirp! \(petName) 🐦"
        case .octopus: "bloop — \(petName) 🐙"
        }
      say(hi, seconds: 4)
    } else if impact < -18 {
      happiness = max(0, happiness - 2)
      say(species == .bird ? "eep!" : species == .cat ? "mrrp?!" : "ow!")
    }
  }

  private func decay() {
    fullness = max(0, fullness - 1 / (180 * fps))
    happiness = max(0, happiness - 1 / (120 * fps))
    if tick % Int(30 * fps) == 0 {
      save()
      pushOnline()
    }
  }

  private func chatter() {
    // Cats talk less; birds & dogs more; cows rarely.
    let chance: Double =
      switch species {
      case .cat: 0.35
      case .cow: 0.3
      case .octopus: 0.4
      case .bird: 0.75
      case .dog: 0.65
      }
    guard tick % Int(75 * fps) == 0, activity != .sleep, bubble == nil, Double.random(in: 0..<1) < chance else { return }
    let hour = Calendar.current.component(.hour, from: Date())
    let hungry = fullness < 30
    let sad = happiness < 30
    let night = hour >= 23 || hour < 6
    let lines: [String] =
      if hungry {
        switch species {
        case .dog: ["hungry… 🦴?", "ball AND food??"]
        case .cat: ["…tuna.", "you may feed me"]
        case .cow: ["grass please", "chew… empty"]
        case .bird: ["SEED", "berry??", "hungry chirp"]
        case .octopus: ["🦀?", "snack bloop"]
        }
      } else if sad {
        switch species {
        case .dog: ["play with me…", "pet me? 🥺"]
        case .cat: ["ignoring you…", "…attention."]
        case .cow: ["lonely moo", "pets?"]
        case .bird: ["lonely tweet", "sing with me?"]
        case .octopus: ["drift alone…", "🫧?"]
        }
      } else if night {
        switch species {
        case .cat: ["night loaf 🌙"]
        case .bird: ["roost time"]
        case .octopus: ["dark water…"]
        default: ["sleepy 🌙"]
        }
      } else {
        switch species {
        case .dog: ["woof!", "*sniff*", "walk??", "good day!"]
        case .cat: ["mrrrp", "…", "loafing", "mine."]
        case .cow: ["moo", "*chew*", "🌾", "…"]
        case .bird: ["chirp!", "tweet!", "♪", "up up!"]
        case .octopus: ["bloop", "…", "🫧", "ink later"]
        }
      }
    say(lines.randomElement()!)
  }

  // MARK: Rendering

  /// Spin angle while the cat rolls (used by PetView).
  var rollRotation: CGFloat? {
    activity == .roll ? CGFloat(tick) * (.pi / 6) : nil
  }

  private var look: Look {
    let angry = angryTicks > 0
    let happy = !angry && (happyTicks > 0 || activity == .eat || activity == .run || activity == .fly)
    var l = Look(species: species)
    switch activity {
    case .walk, .run, .fly: l.pose = .walk(walkFrame)
    case .roll: l.pose = walkFrame == 0 ? .hang : .lie // tumble frames
    case .glide: l.pose = .sit
    case .moo, .sit, .eat: l.pose = .sit
    case .sleep: l.pose = .lie
    case .held, .fall: l.pose = .hang
    }
    if activity == .sleep || (blinkTicks > 0 && !angry) {
      l.eyes = .closed
    } else if angry {
      l.eyes = .angry
    } else if happy || activity == .moo {
      l.eyes = .happy
    } else {
      l.eyes = .open
    }
    l.tongue = !angry && (activity == .eat || activity == .moo ? walkFrame == 0 : happy)
    l.wag = activity == .sleep || angry ? 0 : tick / (happy || activity == .fly || activity == .glide ? 3 : 10) % 2
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
    window.ignoresMouseEvents = !(activity == .held || isOverDog(NSEvent.mouseLocation))
    view.needsDisplay = true
  }

  private func isOverDog(_ m: CGPoint) -> Bool {
    let lx = m.x - window.frame.minX - spriteOrigin.x, ly = m.y - window.frame.minY - spriteOrigin.y
    var col = Int((lx / scale).rounded(.down))
    let row = Canvas.h - 1 - Int((ly / scale).rounded(.down))
    if dir < 0 { col = Canvas.w - 1 - col }
    return Canvas.contains(col, row) && sprite.canvas[col, row] != nil
  }

  var headPoint: CGPoint {
    let col = 25.5 + CGFloat(sprite.head.x), row = 3 + CGFloat(sprite.head.y)
    let mirrored = dir < 0 ? CGFloat(Canvas.w) - col : col
    return CGPoint(x: spriteOrigin.x + mirrored * scale, y: spriteOrigin.y + (CGFloat(Canvas.h) - row) * scale)
  }

  private func say(_ text: String, seconds: Double = 2.5) {
    bubble = text
    bubbleTicks = Int(seconds * fps)
  }

  private func emit(_ text: String, count: Int = 1) {
    let head = headPoint
    for i in 0..<count {
      particles.append(
        Particle(
          text: text, pos: CGPoint(x: head.x - 8 + .random(in: -14...14), y: head.y + CGFloat(i) * 8),
          vel: CGVector(dx: .random(in: -0.4...0.4), dy: .random(in: 0.8...1.4)), life: 45, maxLife: 45))
    }
  }

  private func updateParticles() {
    for i in particles.indices {
      particles[i].pos.x += particles[i].vel.dx
      particles[i].pos.y += particles[i].vel.dy
      particles[i].life -= 1
    }
    particles.removeAll { $0.life <= 0 }
  }

  private func screenFrame() -> CGRect {
    let p = CGPoint(x: x, y: y + 1)
    return (NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main!).visibleFrame
  }

  // MARK: Mouse

  func grab() {
    let m = NSEvent.mouseLocation
    grabStart = m
    lastMouse = m
    grabOffset = CGPoint(x: x - m.x, y: y - m.y)
    throwVelocity = .zero
    dragged = false
  }

  func drag() {
    let m = NSEvent.mouseLocation
    if !dragged {
      guard hypot(m.x - grabStart.x, m.y - grabStart.y) > 3 else { return }
      dragged = true
      targetX = nil
      activity = .held // untilWoken kept — land() puts them back to sleep
      if Bool.random() {
        let line: String =
          switch species {
          case .dog: ["put me down!", "wheee~"].randomElement()!
          case .cat: ["unhand me", "I allowed this"].randomElement()!
          case .cow: "moo?!"
          case .bird: "not a kite!!"
          case .octopus: "tentacles!!"
          }
        say(line)
      }
    }
    throwVelocity = CGVector(dx: (m.x - lastMouse.x) * 1.5, dy: (m.y - lastMouse.y) * 1.5)
    lastMouse = m
    lastDragTime = ProcessInfo.processInfo.systemUptime
    x = m.x + grabOffset.x
    y = m.y + grabOffset.y
    render()
  }

  func release() {
    guard dragged else { return pet() }
    let stale = ProcessInfo.processInfo.systemUptime - lastDragTime > 0.1
    let v = stale ? .zero : throwVelocity
    if abs(v.dx) > 1 { dir = v.dx > 0 ? 1 : -1 }
    startFall(vx: max(-30, min(30, v.dx)), vy: max(-20, min(25, v.dy)))
  }

  // MARK: Actions

  private func pet() {
    happiness = min(100, happiness + 6)
    happyTicks = Int(2.5 * fps)
    if activity == .sleep || untilWoken {
      say(species == .cat ? "mrrp… 💤" : species == .cow ? "mmmoo…" : "mmh…? 🥱")
      pushOnline()
      return
    }
    switch species {
    case .dog:
      emit("❤️", count: 4)
      say(["woof!", "best day!!", "more pets!!"].randomElement()!)
      hop()
    case .cat:
      // Cats are choosy — sometimes loaf-purr, sometimes swat.
      emit(Bool.random() ? "❤️" : "💢", count: 2)
      if Double.random(in: 0..<1) < 0.55 {
        say(["purr~", "mrrrp", "acceptable."].randomElement()!)
        set(.sit, seconds: 3) // loaf into it
      } else {
        say(["touch grass", "hiss— joke", "my terms."].randomElement()!)
        set(.roll, seconds: 2)
      }
    case .cow:
      emit("❤️", count: 2)
      say(["moo~", "*leans in*", "warm…"].randomElement()!)
      set(.sit, seconds: 2.5)
    case .bird:
      emit("✨", count: 3)
      say(["tweet!", "fluff!!", "♪"].randomElement()!)
      y = restFloor(in: screenFrame()) + 10
      set(.fly, seconds: 2) // happy flutter
    case .octopus:
      emit("🫧", count: 3)
      say(["bloop~", "pat pat", "🫧❤️"].randomElement()!)
      set(.glide, seconds: 2.5)
    }
    pushOnline()
  }

  @objc private func feed() {
    guard fullness < 95 else {
      return say(
        species == .cow ? "full of grass~" :
          species == .cat ? "…no." :
          species == .bird ? "crop full!" :
          species == .octopus ? "too full bloop" : "too full~ 😵")
    }
    fullness = min(100, fullness + 35)
    happiness = min(100, happiness + 4)
    let eatSec: Double = species == .cow ? 5 : species == .cat ? 2.5 : 3
    set(.eat, seconds: eatSec)
    switch species {
    case .dog:
      say("nom nom 🦴"); emit("🦴")
    case .cat:
      say("…fine. 🐟"); emit("🐟")
    case .cow:
      say("*chew chew* 🌾"); emit("🌾", count: 2)
    case .bird:
      say("peck peck!"); emit("seed", count: 2)
    case .octopus:
      say("nom bloop 🦀"); emit("🦀")
    }
    pushOnline()
  }

  @objc private func play() {
    happiness = min(100, happiness + 12)
    fullness = max(0, fullness - 3)
    startSignatureMove(seconds: 6)
    pushOnline()
  }

  /// Signature play per personality.
  private func startSignatureMove(seconds: Double) {
    let vf = screenFrame()
    switch species {
    case .dog:
      set(.run, seconds: seconds)
      say("ZOOMIES!! 🎾")
      emit("💨")
    case .cat:
      // classic: sudden zoomies, then a dramatic roll
      set(.run, seconds: seconds * 0.45)
      DispatchQueue.main.asyncAfter(deadline: .now() + seconds * 0.45) { [weak self] in
        guard let self, self.species == .cat else { return }
        self.set(.roll, seconds: seconds * 0.55)
        self.say("tumble!! 🌀")
      }
      say("mrrp ZOOM")
    case .bird:
      y = vf.minY + CGFloat.random(in: 80...140)
      set(.fly, seconds: seconds)
      say("sky!! 🪶")
    case .cow:
      set(.moo, seconds: min(seconds, 4))
      say("MOOO!! 🌾")
      emit("💬", count: 2)
    case .octopus:
      y = restFloor(in: vf) + 10
      set(.glide, seconds: seconds)
      say("whoosh 🌊")
      emit("🫧", count: 2)
    }
  }

  /// Mad reaction — personality intact.
  private func getAngry(fromPoke: Bool) {
    if untilWoken || activity == .sleep { untilWoken = false }
    happyTicks = 0
    angryTicks = Int(5 * fps)
    happiness = max(0, happiness - (fromPoke ? 8 : 4))
    let vf = screenFrame()
    switch species {
    case .dog:
      set(.run, seconds: 2.5)
      emit("💢", count: 3)
      say(["hey!!", "grrr!", "was that needed"].randomElement()!)
    case .cat:
      set(.run, seconds: 2) // offended sprint away
      emit("💢", count: 2)
      say(["HISS", "how dare", "unloved."].randomElement()!)
    case .cow:
      set(.moo, seconds: 2.5)
      emit("💢", count: 2)
      say(["MOO?!", "rude farmer"].randomElement()!)
    case .bird:
      y = vf.minY + 100
      set(.fly, seconds: 3)
      emit("💢", count: 2)
      say(["SQUAWK", "mean!!"].randomElement()!)
    case .octopus:
      y = restFloor(in: vf)
      set(.glide, seconds: 3)
      emit("🖤", count: 4) // ink cloud
      say(["INK!!", "blorp— bye"].randomElement()!)
    }
  }

  @objc private func toggleNap() {
    let vf = screenFrame()
    if activity == .sleep {
      untilWoken = false
      y = restFloor(in: vf)
      set(.sit, seconds: 2)
      say(
        species == .cat ? "big stretch…" :
          species == .bird ? "morning chirp" :
          species == .cow ? "moo…?" :
          species == .octopus ? "rise…" : "🥱")
    } else {
      untilWoken = true
      y = sleepFloor(in: vf)
      set(.sleep, seconds: 9_999)
      say(
        species == .cat ? "loaf nap 💤" :
          species == .bird ? "roost 💤" :
          species == .cow ? "zzz moo" :
          species == .octopus ? "sand nap 🫧" : "zzz…")
    }
    pushOnline()
  }

  /// Send an action at a friend — their pet reacts (on their screen + visitor if shown).
  private func sendToFriend(action: String, code: String, name: String) {
    Online.shared.setActive(code: code)
    Online.shared.sync(fullness: fullness, happiness: happiness, action: action, toCode: code)
    if visitor?.code == code {
      visitor?.play(action)
    } else {
      let line: String =
        switch action {
        case "feed": "fed \(name)! 🦴"
        case "play": "playing with \(name)! 🎾"
        case "pet": "pet \(name)! ❤️"
        case "nap": "tucked \(name) in 💤"
        case "poke": "poked \(name)! 💢"
        default: "→ \(name)"
        }
      say(line, seconds: 2)
    }
  }

  private func syncVisitorFromFriends() {
    guard let v = visitor,
          let f = Online.shared.friends.first(where: { $0.code == v.code })
    else { return }
    v.update(name: f.partnerName, species: f.petSpecies)
  }

  @objc private func chooseSpecies(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
          let next = Species(rawValue: raw)
    else { return }
    species = next
    Online.shared.mySpecies = next
    sprites.removeAll()
    refreshStatusItem()
    say("i'm a \(next.title)! \(next.emoji)", seconds: 2)
    pushOnline() // tell friends your new look
    render()
  }

  @objc private func showFriendOnScreen(_ sender: NSMenuItem) {
    guard let code = sender.representedObject as? String,
          let f = Online.shared.friends.first(where: { $0.code == code }), !f.waiting
    else { return }
    visitor?.dismiss()
    let v = FriendVisitor(code: code, name: f.partnerName, species: f.petSpecies, near: x)
    v.hostX = { [weak self] in self?.x ?? 0 }
    visitor = v
    Online.shared.setActive(code: code)
    say("brought \(f.partnerName) over \(f.petSpecies.emoji)", seconds: 2)
  }

  @objc private func hideFriendOnScreen(_ sender: NSMenuItem) {
    // Menu may pass a code, or the top-level “Hide …” item with none.
    if let code = sender.representedObject as? String, visitor?.code != code { return }
    hideVisitor()
  }

  @objc private func hideVisitor() {
    guard visitor != nil else { return }
    visitor?.dismiss()
    visitor = nil
    say("visitor left", seconds: 1.5)
  }

  @objc private func friendFeed(_ sender: NSMenuItem) {
    guard let code = sender.representedObject as? String,
          let name = Online.shared.friends.first(where: { $0.code == code })?.partnerName
    else { return }
    sendToFriend(action: "feed", code: code, name: name)
  }

  @objc private func friendPlay(_ sender: NSMenuItem) {
    guard let code = sender.representedObject as? String,
          let name = Online.shared.friends.first(where: { $0.code == code })?.partnerName
    else { return }
    sendToFriend(action: "play", code: code, name: name)
  }

  @objc private func friendPet(_ sender: NSMenuItem) {
    guard let code = sender.representedObject as? String,
          let name = Online.shared.friends.first(where: { $0.code == code })?.partnerName
    else { return }
    sendToFriend(action: "pet", code: code, name: name)
  }

  @objc private func friendPoke(_ sender: NSMenuItem) {
    guard let code = sender.representedObject as? String,
          let name = Online.shared.friends.first(where: { $0.code == code })?.partnerName
    else { return }
    sendToFriend(action: "poke", code: code, name: name)
  }

  /// Top-level poke — targets visitor on screen, else the selected friend.
  @objc private func pokeActiveFriend() {
    if let v = visitor {
      sendToFriend(action: "poke", code: v.code, name: v.name)
      return
    }
    guard let f = Online.shared.activeFriend, !f.waiting else {
      say("pick a friend first", seconds: 2)
      return
    }
    sendToFriend(action: "poke", code: f.code, name: f.partnerName)
  }

  private func friendActionItem(_ title: String, _ sel: Selector, code: String) -> NSMenuItem {
    let m = NSMenuItem(title: title, action: sel, keyEquivalent: "")
    m.target = self
    m.representedObject = code
    return m
  }

  @objc private func friendNap(_ sender: NSMenuItem) {
    guard let code = sender.representedObject as? String,
          let name = Online.shared.friends.first(where: { $0.code == code })?.partnerName
    else { return }
    sendToFriend(action: "nap", code: code, name: name)
  }

  @objc private func petFromMenu() { pet() }

  @objc private func toggleHide() {
    hidden.toggle()
    if hidden {
      window.orderOut(nil)
      bubble = nil
      particles.removeAll()
    } else {
      window.orderFrontRegardless()
      set(.sit, seconds: 2)
      say("i'm back 🐾")
      render()
    }
    refreshStatusItem()
  }

  @objc private func quit() {
    save()
    Online.shared.disconnect()
    NSApp.terminate(nil)
  }

  // MARK: Online — invite / claim

  @objc private func onlineInvite() {
    ensureDisplayName()
    Online.shared.create(fullness: fullness, happiness: happiness)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
      guard let self else { return }
      let code = Online.shared.activeCode
        ?? Online.shared.friends.first(where: { $0.waiting })?.code
      guard let code else {
        self.alert("Couldn’t reach the server.\nCheck your internet and try again.")
        return
      }
      let site = "https://tamagotchi-udtz.onrender.com"
      let msg = """
      Mochi code \(code)

      1) download \(site)
      2) 🐶 → Claim invite → paste \(code)
      """
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(msg, forType: .string)
      self.onlineNote = "waiting · code \(code)"
      self.alert("Invite copied.\n\nYour code is \(code) — send it to your friend now.")
    }
  }

  @objc private func onlineClaim() {
    ensureDisplayName()
    let code = prompt("Claim invite", message: "Paste just the 6-letter code (or the whole invite text)", placeholder: "")
    guard let code, !code.isEmpty else { return }
    let token = Online.extractCode(code)
    onlineNote = "joining \(token)…"
    Online.shared.join(code: token)
  }

  @objc private func onlineLeave() {
    Online.shared.leaveAllBonds()
    petName = defaultPetName
    onlineNote = nil
    partnerWasOnline = false
    refreshStatusItem()
    say("bye bye…")
  }

  @objc private func selectFriend(_ sender: NSMenuItem) {
    guard let code = sender.representedObject as? String else { return }
    Online.shared.setActive(code: code)
    if let f = Online.shared.activeFriend, !f.waiting {
      say("targeting \(f.partnerName)", seconds: 2)
    }
    refreshStatusItem()
  }

  @objc private func removeFriend(_ sender: NSMenuItem) {
    guard let code = sender.representedObject as? String else { return }
    Online.shared.removeFriend(code: code)
    refreshStatusItem()
  }

  @objc private func onlineSetName() {
    if let name = prompt(
      "Your name",
      message: "Friends see this when they interact with you (your dog stays \(defaultPetName))",
      placeholder: Online.shared.displayName),
       !name.isEmpty
    {
      Online.shared.displayName = name
    }
  }

  private func ensureDisplayName() {
    if UserDefaults.standard.string(forKey: "mochiName") == nil {
      onlineSetName()
    }
  }

  private func prompt(_ title: String, message: String, placeholder: String) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = placeholder
    field.placeholderString = "paste here"
    alert.accessoryView = field
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func alert(_ text: String) {
    let a = NSAlert()
    a.messageText = "Mochi"
    a.informativeText = text
    a.addButton(withTitle: "OK")
    NSApp.activate(ignoringOtherApps: true)
    a.runModal()
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    menu.addItem(info("🍖 Fullness    \(bar(fullness))"))
    menu.addItem(info("💛 Happiness  \(bar(happiness))"))

    let friends = Online.shared.friends
    let onlineN = friends.filter { $0.online && !$0.waiting }.count
    menu.addItem(info("👥 Friends     \(friends.count) total · \(onlineN) online"))

    if let note = onlineNote {
      menu.addItem(info("🔗 \(note)"))
    }
    menu.addItem(.separator())
    // YOUR pet
    if !hidden {
      menu.addItem(info("—— \(petName) \(species.emoji) ——"))
      menu.addItem(item("🦴 Feed", #selector(feed)))
      menu.addItem(item("🎾 Play", #selector(play)))
      menu.addItem(item("🤚 Pet", #selector(petFromMenu)))
      menu.addItem(item(activity == .sleep ? "☀️ Wake up" : "💤 Nap", #selector(toggleNap)))
      let speciesItem = NSMenuItem(title: "Choose pet…", action: nil, keyEquivalent: "")
      let speciesMenu = NSMenu()
      for sp in Species.allCases {
        let row = NSMenuItem(
          title: "\(sp.emoji) \(sp.title)",
          action: #selector(chooseSpecies(_:)),
          keyEquivalent: "")
        row.target = self
        row.representedObject = sp.rawValue
        if sp == species { row.state = .on }
        speciesMenu.addItem(row)
      }
      speciesItem.submenu = speciesMenu
      menu.addItem(speciesItem)
      menu.addItem(.separator())
    }

    // Friend on your screen / selected friend — poke & co. live here (not buried)
    let focus = visitor.flatMap { v in Online.shared.friends.first { $0.code == v.code } }
      ?? Online.shared.activeFriend
    if let f = focus, !f.waiting {
      let who = f.partnerName
      let code = f.code
      menu.addItem(info("—— \(who) \(f.petSpecies.emoji) ——"))
      menu.addItem(friendActionItem("👉 Poke \(who)", #selector(friendPoke(_:)), code: code))
      menu.addItem(friendActionItem("🦴 Feed \(who)", #selector(friendFeed(_:)), code: code))
      menu.addItem(friendActionItem("🎾 Play with \(who)", #selector(friendPlay(_:)), code: code))
      menu.addItem(friendActionItem("🤚 Pet \(who)", #selector(friendPet(_:)), code: code))
      menu.addItem(friendActionItem("💤 Tuck \(who) in", #selector(friendNap(_:)), code: code))
      if visitor?.code == code {
        menu.addItem(item("👋 Hide \(who) from screen", #selector(hideVisitor)))
      } else {
        menu.addItem(friendActionItem("✨ Show \(who) on screen", #selector(showFriendOnScreen(_:)), code: code))
      }
      menu.addItem(.separator())
    } else if !friends.isEmpty {
      menu.addItem(item("👉 Poke a friend…", #selector(pokeActiveFriend)))
      menu.addItem(.separator())
    }

    menu.addItem(item(hidden ? "☀️ Show pet" : "😴 Hide pet (focus mode)", #selector(toggleHide)))
    menu.addItem(.separator())

    // Friends: status + actions aimed at *them*
    let friendsItem = NSMenuItem(
      title: "Friends (\(friends.count))",
      action: nil,
      keyEquivalent: "")
    let sub = NSMenu()
    if friends.isEmpty {
      sub.addItem(info("No friends yet"))
      sub.addItem(info("Invite or Claim to bond"))
    } else {
      for f in friends {
        let dot = f.waiting ? "⏳" : (f.online ? "🟢" : "⚪️")
        let name = f.waiting ? "code \(f.code) · waiting" : f.partnerName
        let row = NSMenuItem(
          title: "\(dot) \(name)",
          action: #selector(selectFriend(_:)),
          keyEquivalent: "")
        row.target = self
        row.representedObject = f.code
        if f.code == Online.shared.activeCode { row.state = .on }
        sub.addItem(row)
        if f.waiting { continue }
        sub.addItem(info("   \(f.petSpecies.emoji) \(f.petSpecies.title) · 🍖 \(Int(f.fullness))%  💛 \(Int(f.happiness))%"))
        if let act = f.lastActivity {
          sub.addItem(info("   \(act)"))
        }
        let onScreen = visitor?.code == f.code
        let bring = NSMenuItem(
          title: onScreen ? "   👋 Hide \(f.partnerName) from screen" : "   ✨ Show \(f.partnerName) on screen",
          action: onScreen ? #selector(hideFriendOnScreen(_:)) : #selector(showFriendOnScreen(_:)),
          keyEquivalent: "")
        bring.target = self
        bring.representedObject = f.code
        sub.addItem(bring)
        for (title, sel) in [
          ("   🦴 Feed \(f.partnerName)", #selector(friendFeed(_:))),
          ("   🎾 Play with \(f.partnerName)", #selector(friendPlay(_:))),
          ("   🤚 Pet \(f.partnerName)", #selector(friendPet(_:))),
          ("   👉 Poke \(f.partnerName)", #selector(friendPoke(_:))),
          ("   💤 Tuck \(f.partnerName) in", #selector(friendNap(_:))),
        ] as [(String, Selector)] {
          let m = NSMenuItem(title: title, action: sel, keyEquivalent: "")
          m.target = self
          m.representedObject = f.code
          sub.addItem(m)
        }
      }
      sub.addItem(.separator())
      for f in friends {
        let name = f.waiting ? f.code : f.partnerName
        let rm = NSMenuItem(
          title: "Remove \(name)",
          action: #selector(removeFriend(_:)),
          keyEquivalent: "")
        rm.target = self
        rm.representedObject = f.code
        sub.addItem(rm)
      }
    }
    friendsItem.submenu = sub
    menu.addItem(friendsItem)

    menu.addItem(item("Invite friend…", #selector(onlineInvite)))
    menu.addItem(item("Claim invite…", #selector(onlineClaim)))
    if !friends.isEmpty {
      menu.addItem(item("Leave all bonds", #selector(onlineLeave)))
    }
    menu.addItem(item("My name…", #selector(onlineSetName)))
    menu.addItem(.separator())
    menu.addItem(item("Quit \(petName)", #selector(quit)))
  }

  private func item(_ title: String, _ action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  private func info(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  private func bar(_ value: Double) -> String {
    let n = Int((value / 10).rounded())
    return String(repeating: "▰", count: n) + String(repeating: "▱", count: 10 - n) + " \(Int(value))%"
  }

  // MARK: Persistence

  func save() {
    let d = UserDefaults.standard
    d.set(fullness, forKey: "fullness")
    d.set(happiness, forKey: "happiness")
    d.set(Date().timeIntervalSince1970, forKey: "savedAt")
  }

  private static func loadStats() -> (Double, Double) {
    let d = UserDefaults.standard
    guard let savedAt = d.object(forKey: "savedAt") as? Double else { return (80, 80) }
    let minutesAway = min(Date().timeIntervalSince1970 - savedAt, 12 * 3600) / 60
    return (
      max(10, d.double(forKey: "fullness") - minutesAway / 3),
      max(20, d.double(forKey: "happiness") - minutesAway / 2)
    )
  }
}
