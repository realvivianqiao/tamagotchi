import AppKit

// MARK: - Pet brain

@MainActor final class Pet: NSObject, NSMenuDelegate {
  enum Activity { case walk, run, sit, sleep, eat, held, fall, fly, glide }
  /// One activity bout moves on a single axis so the pet is easier to grab.
  private enum WanderAxis { case horizontal, vertical }

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
  private var wanderAxis: WanderAxis = .horizontal
  /// Locked Y (or X) for the current axis-locked bout.
  private var wanderLock: CGFloat?
  private var targetX: CGFloat?
  /// How many times we've bounced this fall (caps so they settle).
  private var bounceCount = 0
  /// Brief squash after a bounce hit (drawn in PetView).
  private(set) var squashTicks = 0
  private var tick = 0, walkFrame = 0, happyTicks = 0, angryTicks = 0, blinkTicks = 0, bubbleTicks = 0
  private var recentSays: [String] = []
  private var greeted = false

  private(set) var bubble: String?
  private(set) var particles: [Particle] = []
  private var species: Species = Online.shared.mySpecies
  private(set) var sprite = Dog.sprite(Look(species: Online.shared.mySpecies))
  private var sprites: [Look: Sprite] = [:]

  private var fullness: Double
  private var happiness: Double
  /// Your chosen name (My name…) — never overwritten by friend presence/sync.
  private var petName: String {
    let n = Online.shared.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    return n.isEmpty ? defaultPetName : n
  }
  private var applyingRemote = false
  private var onlineNote: String?
  private var hidden = false
  /// User (or partner) put them to sleep — stay asleep until Wake up.
  private var untilWoken = false
  /// Friend's pet visiting your desktop (their species + reactions).
  private var visitor: FriendVisitor?

  private var grabStart = CGPoint.zero, lastMouse = CGPoint.zero, grabOffset = CGPoint.zero
  private var swallowRelease = false // double-click nap/wake — don't also pet()
  private var pendingPetWork: DispatchWorkItem?
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

    // First download / fresh install: pick Zuzu, Bloop, or Puff.
    if !PetPicker.hasChosen {
      let pick = PetPicker.runModal()
      species = pick
      Online.shared.displayName = pick.defaultName
      sprites.removeAll()
      statusItem.button?.title = pick.emoji
      say("hi! i'm \(pick.defaultName)", seconds: 3.5)
    }

    window.orderFrontRegardless()
    restoreNapIfNeeded()
    wireAmbientGreetings()

    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      guard let self, self.untilWoken else { return }
      self.y = self.sleepFloor(in: self.screenFrame())
      self.render()
    }

    let timer = Timer(timeInterval: 1 / fps, target: self, selector: #selector(step), userInfo: nil, repeats: true)
    RunLoop.main.add(timer, forMode: .common)
  }

  /// Good morning / weather when the Mac wakes, the daypart changes, or the pad launches.
  private func wireAmbientGreetings() {
    // Always say hi on launch (force) — reload should talk even if we already
    // greeted this evening. Skip only if they left the pet napping.
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_200_000_000)
      guard !self.hidden else { return }
      Ambient.shared.maybeGreet(species: self.species, asleep: self.isAsleep, force: true) {
        [weak self] text, secs in
        self?.say(text, seconds: secs)
      }
    }
    // Opening the laptop lid / waking from sleep → hello again.
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, !self.hidden else { return }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        Ambient.shared.maybeGreet(species: self.species, asleep: self.isAsleep, force: true) {
          [weak self] text, secs in
          self?.say(text, seconds: secs)
        }
      }
    }
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
    // Friend sent an action at *you* — their pet visits your screen, then your pet reacts.
    Online.shared.onSync = { [weak self] _, _, action, from, code, fromSpecies in
      guard let self, let action, !self.hidden else { return }
      self.applyingRemote = true
      let who = from.isEmpty ? "friend" : from
      let sp = Species.parse(fromSpecies ?? "")
      self.receiveFriendVisit(
        action: action, fromName: who, code: code, species: sp)
      self.applyingRemote = false
      self.save()
      // Publish *your* new stats so their Friends list shows the real result.
      self.pushOnline()
    }
    Online.shared.restoreBondIfAny()
    Updater.shared.start()
    logApp("app_launch", extra: [
      "species": species.rawValue,
      "friendCount": Online.shared.friends.filter { !$0.waiting }.count,
    ])
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
    // Sticky nap is locked — friends can still nudge stats / leave a note, but
    // they cannot change activity except an explicit poke (wake + mad).
    if untilWoken, action != "poke" {
      switch action {
      case "feed":
        fullness = min(100, fullness + 35)
        happiness = min(100, happiness + 4)
      case "play", "pet":
        happiness = min(100, happiness + 4)
      case "nap":
        break
      default:
        break
      }
      return
    }
    switch action {
    case "feed":
      fullness = min(100, fullness + 35)
      happiness = min(100, happiness + 4)
      set(.eat, seconds: 3)
      emit("🍖")
    case "play":
      happiness = min(100, happiness + 12)
      startSignatureMove(seconds: 6)
    case "pet":
      happiness = min(100, happiness + 6)
      happyTicks = Int(2 * fps)
      emit("❤️", count: 3)
      if activity != .sleep && !untilWoken { hop() }
    case "nap":
      enterNap(sayLine: false)
    case "poke":
      getAngry(fromPoke: true)
    default:
      break
    }
  }

  private var lastCloudPush: TimeInterval = 0

  private func pushOnline(action: String? = nil) {
    guard !applyingRemote else { return }
    Online.shared.noteMetrics(fullness: fullness, happiness: happiness)
    if Online.shared.isBonded {
      Online.shared.sync(fullness: fullness, happiness: happiness, action: action)
    }
    let now = ProcessInfo.processInfo.systemUptime
    if now - lastCloudPush > 30 {
      lastCloudPush = now
      Online.shared.cloudPush(fullness: fullness, happiness: happiness)
    }
  }

  /// Every user-facing action → Supabase `mochi_events` with owner + metrics + timestamp.
  private func logApp(
    _ event: String,
    code: String? = nil,
    targetName: String? = nil,
    extra: [String: Any] = [:]
  ) {
    var payload = extra
    payload["activity"] = String(describing: activity)
    payload["asleep"] = untilWoken || activity == .sleep
    payload["hidden"] = hidden
    Online.shared.noteMetrics(fullness: fullness, happiness: happiness)
    Online.shared.track(
      event,
      code: code,
      targetName: targetName,
      fullness: fullness,
      happiness: happiness,
      payload: payload)
  }

  // MARK: Loop

  @objc private func step() {
    tick += 1
    decay()
    guard !hidden else { return }

    // Sticky nap: freeze activity forever until Wake up (survives screen / space switches).
    if untilWoken {
      activity = .sleep
      vx = 0
      vy = 0
      targetX = nil
      wanderLock = nil
      y = sleepFloor(in: screenFrame())
      pinStaticSleepZzz()
      updateParticles()
      render()
      return
    }

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
      // Walk is always horizontal — no diagonal zigzag.
      x += dir * walkSpeed
      if species == .bird {
        y = vf.minY + (walkFrame == 0 ? 0 : 3)
      }
    case .run: // dog chase — horizontal only, slightly slower to grab
      x += dir * 0.95
      if Int.random(in: 0..<120) == 0 { dir = -dir }
      y = vf.minY
    case .fly: // one axis per bout — easier to catch than zigzag
      let ceiling = vf.minY + min(180, vf.height * 0.5)
      let perch = vf.minY + 55
      switch wanderAxis {
      case .horizontal:
        x += dir * 0.55
        if let lock = wanderLock { y = lock }
        if Int.random(in: 0..<140) == 0 { dir = -dir }
      case .vertical:
        if let lock = wanderLock { x = lock }
        y += dir * 0.4
        if y <= perch { y = perch; dir = 1 }
        if y >= ceiling { y = ceiling; dir = -1 }
      }
      y = min(max(y, perch), ceiling)
    case .glide: // octopus — horizontal or vertical drift, never both
      switch wanderAxis {
      case .horizontal:
        x += dir * 0.28
        if let lock = wanderLock { y = lock }
        if Int.random(in: 0..<180) == 0 { dir = -dir }
      case .vertical:
        let low = vf.minY + 12
        let high = vf.minY + 70
        if let lock = wanderLock { x = lock }
        y += dir * 0.22
        if y <= low { y = low; dir = 1 }
        if y >= high { y = high; dir = -1 }
      }
      if tick % 90 == 0 { emit(["💧", "🫧"].randomElement()!) }
    case .fall:
      vy -= species == .bird ? 0.55 : 0.9 // birds flutter-fall
      if species == .bird { vx *= 0.98 }
      x += vx
      y += vy
      let floor = restFloor(in: vf)
      if y <= floor {
        y = floor
        // Bounce when dropped from height — reverse + damp so it settles in a few hops.
        let bounceThresh: CGFloat = species == .bird ? -5 : -4
        if vy < bounceThresh, bounceCount < 3 {
          bounceCount += 1
          let damp: CGFloat = species == .bird ? 0.42 : 0.58
          vy = -vy * damp
          // Keep a little upward pop so tall drops feel bouncy.
          if bounceCount == 1 { vy = max(vy, species == .bird ? 5 : 7) }
          vx *= 0.65
          squashTicks = 8
          if bounceCount == 1 { emit("💨") }
        } else {
          land(impact: vy)
        }
      }
    case .sleep:
      y = sleepFloor(in: vf)
      vx = 0
      vy = 0
    case .held:
      break
    case .sit, .eat:
      y = restFloor(in: vf)
      if activity == .eat, tick % 16 == 0, species == .bird { emit("seed") }
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
    case .sit, .eat:
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
    case .run:
      y = vf.minY
    default:
      break
    }
  }

  private var walkSpeed: CGFloat {
    switch species {
    case .bird: return 0.28 // gentle hop-walk
    case .octopus: return 0.18 // awkward on “land”
    case .dog: return fullness < 20 ? 0.26 : 0.38
    }
  }

  private func animate() {
    let flapFast = activity == .run || activity == .fly
    // Slower leg cycle when walking so it matches the chill pace.
    if tick % (flapFast ? 7 : 14) == 0 { walkFrame ^= 1 }
    if squashTicks > 0 { squashTicks -= 1 }
    happyTicks = max(0, happyTicks - 1)
    angryTicks = max(0, angryTicks - 1)
    if blinkTicks > 0 { blinkTicks -= 1 } else if Int.random(in: 0..<150) == 0 { blinkTicks = 4 }
    if bubbleTicks > 0 {
      bubbleTicks -= 1
      if bubbleTicks == 0 { bubble = nil }
    }
    if activity == .sleep {
      pinStaticSleepZzz()
    } else {
      particles.removeAll { ($0.text == "💤" || $0.text == "🫧") && $0.vel == .zero }
    }
    if activity == .fly && tick % 32 == 0 { emit(["🪶", "✨"].randomElement()!) }
    if activity == .run && species == .dog && tick % 35 == 0 { emit("💨") }

    activityTicks -= 1
    guard activityTicks <= 0, activity != .held, activity != .fall else { return }
    // Only non-sticky (idle) sleeps can auto-wake.
    if activity == .sleep {
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
    if next == .walk || next == .fly || next == .glide, Bool.random() { dir = -dir }
    let seconds: ClosedRange<Double> =
      switch next {
      case .walk: 4...10
      case .run: 2.5...4.5
      case .fly: 5...11
      case .glide: 5...10
      case .sleep: 20...45
      default: 2.5...7
      }
    set(next, seconds: .random(in: seconds))
    // Settle into the right height for this mood.
    let vf = screenFrame()
    switch next {
    case .fly:
      // Mostly side-to-side; occasional pure up/down climb.
      wanderAxis = Int.random(in: 0..<5) == 0 ? .vertical : .horizontal
      y = vf.minY + CGFloat.random(in: 70...130)
      wanderLock = wanderAxis == .horizontal ? y : x
      say(["chirp!", "↑ tweet", "wind~"].randomElement()!)
    case .glide:
      wanderAxis = Int.random(in: 0..<4) == 0 ? .vertical : .horizontal
      y = restFloor(in: vf) + (wanderAxis == .horizontal ? CGFloat.random(in: 0...20) : 0)
      wanderLock = wanderAxis == .horizontal ? y : x
      if Bool.random() { say(["…", "bloop", "🫧"].randomElement()!) }
    case .walk, .run:
      wanderAxis = .horizontal
      wanderLock = nil
      if case .run = next, species == .dog, Bool.random() {
        say(["zoom!", "bark!", "🎾"].randomElement()!)
      }
    default:
      wanderAxis = .horizontal
      wanderLock = nil
    }
  }

  private func speciesIdleOptions(sleepy: Bool) -> [(Activity, Int)] {
    switch species {
    case .dog: // loyal energy — walk + occasional sprint
      return [(.walk, 48), (.sit, 22), (.sleep, sleepy ? 35 : 5), (.run, happiness > 55 ? 16 : 4)]
    case .bird: // lives in the air; ground is temporary
      return [(.fly, 48), (.sit, 24), (.walk, 10), (.sleep, sleepy ? 25 : 4)]
    case .octopus: // water creature — drift + rest, skip “walking”
      return [(.glide, 50), (.sit, 28), (.sleep, sleepy ? 22 : 6)]
    }
  }

  private func set(_ next: Activity, seconds: Double) {
    // Never clear sticky nap except via wakeStickyNap() / poke.
    if next != .sleep, untilWoken { return }
    if next != .sleep { untilWoken = false }
    activity = next
    activityTicks = Int(seconds * fps)
  }

  private func startFall(vx: CGFloat, vy: CGFloat) {
    // Sticky nap ignores throws / screen-jump physics entirely.
    if untilWoken {
      self.vx = 0
      self.vy = 0
      activity = .sleep
      y = sleepFloor(in: screenFrame())
      return
    }
    self.vx = vx
    self.vy = vy
    bounceCount = 0
    activity = .fall
  }

  private func hop() {
    targetX = nil
    startFall(vx: 0, vy: 7)
  }

  private func land(impact: CGFloat) {
    vx = 0
    vy = 0
    bounceCount = 0
    if impact < -6 { squashTicks = max(squashTicks, 6) }
    logApp("land", extra: ["impact": Double(impact)])
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
        case .bird: "chirp! \(petName) 🐦"
        case .octopus: "bloop — \(petName) 🐙"
        }
      say(hi, seconds: 4)
    } else if impact < -18 {
      happiness = max(0, happiness - 2)
      say(species == .bird ? "eep!" : "ow!")
    }
  }

  private var isAsleep: Bool { untilWoken || activity == .sleep }

  private func decay() {
    // Asleep: hunger creeps slowly, happiness barely drops (resting).
    // Awake: both drain over time so they need care.
    let fullPerSec = isAsleep ? 1.0 / 420.0 : 1.0 / 150.0   // ~7h asleep / ~2.5h awake to empty
    let happyPerSec = isAsleep ? 1.0 / 900.0 : 1.0 / 100.0  // ~15h asleep / ~1.7h awake to empty
    fullness = max(0, fullness - fullPerSec / fps)
    happiness = max(0, happiness - happyPerSec / fps)
    if tick % Int(30 * fps) == 0 {
      save()
      pushOnline()
    }
  }

  /// Periodic check-ins while awake. Silent when you put them to sleep.
  private func chatter() {
    guard !hidden, !isAsleep else { return }
    // Once per morning/afternoon/evening/night — soft daypart hello.
    if tick % Int(60 * fps) == 0 {
      Ambient.shared.maybeGreet(species: species, asleep: false) { [weak self] text, secs in
        self?.say(text, seconds: secs, force: false)
      }
    }
    let hungry = fullness < 35
    let sad = happiness < 35
    let needy = hungry || sad
    // Needier → talk more often.
    let interval = Int((needy ? 40.0 : 85.0) * fps)
    guard tick % interval == 0 else { return }
    // Don't stomp a gesture bubble that's still being read.
    if bubble != nil, bubbleTicks > Int(0.8 * fps) { return }

    let chance: Double = needy ? 0.95 : 0.55
    guard Double.random(in: 0..<1) < chance else { return }

    let pool: [String] =
      if hungry && sad {
        PetLines.hungry(species) + PetLines.lonely(species)
      } else if hungry {
        PetLines.hungry(species)
      } else if sad {
        PetLines.lonely(species)
      } else {
        PetLines.checkIn(species)
      }
    say(PetLines.pick(pool, recent: &recentSays), seconds: needy ? 3.5 : 2.8, force: false)
  }

  // MARK: Rendering

  private var look: Look {
    let angry = angryTicks > 0
    let happy = !angry && (happyTicks > 0 || activity == .eat || activity == .run || activity == .fly)
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
    } else {
      l.eyes = .open
    }
    l.tongue = !angry && (activity == .eat ? walkFrame == 0 : happy)
    l.wag = activity == .sleep || angry ? 0 : tick / (happy || activity == .fly || activity == .glide ? 4 : 12) % 2
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

  private func say(_ text: String, seconds: Double = 3.0, force: Bool = true) {
    // Chatter passes force:false so idle lines don't stomp a gesture bubble mid-read.
    if !force, bubble != nil, bubbleTicks > Int(1.0 * fps) { return }
    bubble = text
    bubbleTicks = Int(seconds * fps)
  }

  private func sayFresh(_ pool: [String], seconds: Double = 3.0) {
    say(PetLines.pick(pool, recent: &recentSays), seconds: seconds, force: true)
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

  /// One still 💤 / 🫧 above the sleeper — no float animation.
  private func pinStaticSleepZzz() {
    let mark = species == .octopus ? "🫧" : "💤"
    let pos = CGPoint(x: headPoint.x - 4, y: headPoint.y + 14)
    if let i = particles.firstIndex(where: { $0.text == mark && $0.vel == .zero }) {
      particles[i].pos = pos
      particles[i].life = particles[i].maxLife
    } else {
      particles.removeAll { $0.text == "💤" || $0.text == "🫧" }
      particles.append(Particle(text: mark, pos: pos, vel: .zero, life: 9999, maxLife: 9999))
    }
  }

  private func updateParticles() {
    for i in particles.indices {
      // Static sleep zzz stays put
      if particles[i].vel == .zero {
        particles[i].life = particles[i].maxLife
        continue
      }
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

  func grab(clickCount: Int = 1) {
    // Double-click → nap if awake, wake if asleep (same as menu Nap / Wake up).
    if clickCount >= 2 {
      pendingPetWork?.cancel()
      pendingPetWork = nil
      swallowRelease = true
      dragged = false
      toggleNap()
      return
    }
    swallowRelease = false
    let m = NSEvent.mouseLocation
    grabStart = m
    lastMouse = m
    grabOffset = CGPoint(x: x - m.x, y: y - m.y)
    throwVelocity = .zero
    dragged = false
    logApp("grab_start")
  }

  func drag() {
    if swallowRelease { return }
    let m = NSEvent.mouseLocation
    if !dragged {
      guard hypot(m.x - grabStart.x, m.y - grabStart.y) > 3 else { return }
      dragged = true
      pendingPetWork?.cancel()
      pendingPetWork = nil
      targetX = nil
      activity = .held // untilWoken kept — land() puts them back to sleep
      logApp("drag_start")
      if Bool.random() {
        let line: String =
          switch species {
          case .dog: ["put me down!", "wheee~"].randomElement()!
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

  func release(clickCount: Int = 1) {
    if swallowRelease {
      swallowRelease = false
      return
    }
    if !dragged {
      // Defer pet so a following second click can become nap/wake instead.
      pendingPetWork?.cancel()
      let work = DispatchWorkItem { [weak self] in
        self?.pendingPetWork = nil
        self?.pet()
      }
      pendingPetWork = work
      let delay = NSEvent.doubleClickInterval
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
      return
    }
    // Dropped at a screen edge → tuck in for a nap.
    if edgeNapIfNeeded() { return }
    let stale = ProcessInfo.processInfo.systemUptime - lastDragTime > 0.1
    let v = stale ? .zero : throwVelocity
    if abs(v.dx) > 1 { dir = v.dx > 0 ? 1 : -1 }
    logApp("release_throw", extra: ["vx": Double(v.dx), "vy": Double(v.dy)])
    startFall(vx: max(-30, min(30, v.dx)), vy: max(-20, min(25, v.dy)))
  }

  /// Left / right / bottom of the visible screen → sticky nap (same as menu Nap).
  @discardableResult
  private func edgeNapIfNeeded() -> Bool {
    let vf = screenFrame()
    let edge: CGFloat = 56
    let atLeft = x <= vf.minX + edge
    let atRight = x >= vf.maxX - edge
    let atBottom = y <= vf.minY + edge
    guard atLeft || atRight || atBottom else { return false }

    let margin = spriteSize.width / 2 - 8
    if atLeft { x = vf.minX + margin; dir = 1 }
    else if atRight { x = vf.maxX - margin; dir = -1 }
    logApp("edge_nap", extra: [
      "edge": atLeft ? "left" : (atRight ? "right" : "bottom"),
    ])
    enterNap(sayLine: true)
    return true
  }

  private func enterNap(sayLine: Bool) {
    let vf = screenFrame()
    untilWoken = true
    targetX = nil
    vx = 0
    vy = 0
    activity = .sleep
    activityTicks = Int(9_999 * fps)
    y = sleepFloor(in: vf)
    if sayLine {
      say(
        species == .bird ? "roost 💤" :
          species == .octopus ? "sand nap 🫧" : "zzz…")
    }
    persistNap()
    pushOnline()
    render()
  }

  private func wakeStickyNap() {
    guard untilWoken || activity == .sleep else { return }
    untilWoken = false
    persistNap()
    let vf = screenFrame()
    y = restFloor(in: vf)
    activity = .sit
    activityTicks = Int(2 * fps)
  }

  /// Feed / play / pet / poke should get them out of a sticky nap.
  @discardableResult
  private func wakeIfNapping() -> Bool {
    guard untilWoken || activity == .sleep else { return false }
    wakeStickyNap()
    return true
  }

  // MARK: Actions

  private func pet() {
    logApp("self_pet")
    _ = wakeIfNapping()
    happiness = min(100, happiness + 6)
    happyTicks = Int(2.5 * fps)
    switch species {
    case .dog:
      emit("❤️", count: 4)
      sayFresh(PetLines.pet(.dog))
      hop()
    case .bird:
      emit("✨", count: 3)
      sayFresh(PetLines.pet(.bird))
      y = restFloor(in: screenFrame()) + 10
      set(.fly, seconds: 2.5) // happy flutter
    case .octopus:
      emit("🫧", count: 3)
      sayFresh(PetLines.pet(.octopus))
      set(.glide, seconds: 3)
    }
    pushOnline()
  }

  @objc private func feed() {
    logApp("self_feed")
    // Always feed *your* pet — never no-op. Full pets still eat (second breakfast).
    _ = wakeIfNapping()
    let wasFull = fullness >= 95
    fullness = min(100, fullness + 35)
    happiness = min(100, happiness + (wasFull ? 2 : 4))
    set(.eat, seconds: 3.5)
    sayFresh(PetLines.feed(species, secondBreakfast: wasFull))
    switch species {
    case .dog: emit("🍖")
    case .bird: emit("seed", count: 2)
    case .octopus: emit("🦀")
    }
    pushOnline()
  }

  @objc private func play() {
    logApp("self_play")
    _ = wakeIfNapping()
    happiness = min(100, happiness + 12)
    fullness = max(0, fullness - 3)
    startSignatureMove(seconds: 7)
    pushOnline()
  }

  /// Signature play per personality.
  private func startSignatureMove(seconds: Double) {
    let vf = screenFrame()
    switch species {
    case .dog:
      set(.run, seconds: seconds)
      sayFresh(PetLines.play(.dog))
      emit("💨")
    case .bird:
      y = vf.minY + CGFloat.random(in: 80...140)
      set(.fly, seconds: seconds)
      sayFresh(PetLines.play(.bird))
    case .octopus:
      y = restFloor(in: vf) + 10
      set(.glide, seconds: seconds)
      sayFresh(PetLines.play(.octopus))
      emit("🫧", count: 2)
    }
  }

  /// Mad reaction — personality intact.
  private func getAngry(fromPoke: Bool) {
    if untilWoken || activity == .sleep { wakeStickyNap() }
    happyTicks = 0
    angryTicks = Int(5 * fps)
    happiness = max(0, happiness - (fromPoke ? 8 : 4))
    let vf = screenFrame()
    switch species {
    case .dog:
      set(.run, seconds: 3)
      emit("💢", count: 3)
      sayFresh(PetLines.poke(.dog))
    case .bird:
      y = vf.minY + 100
      set(.fly, seconds: 3.5)
      emit("💢", count: 2)
      sayFresh(PetLines.poke(.bird))
    case .octopus:
      y = restFloor(in: vf)
      set(.glide, seconds: 3.5)
      emit("🖤", count: 4) // ink cloud
      sayFresh(PetLines.poke(.octopus))
    }
  }

  @objc private func toggleNap() {
    logApp(untilWoken || activity == .sleep ? "self_wake" : "self_nap")
    if untilWoken || activity == .sleep {
      wakeStickyNap()
      let first = Ambient.shared.wakeLine(species: species)
      say(first, seconds: 3.5)
      Task { @MainActor in
        await Ambient.shared.refreshWeatherIfNeeded()
        let richer = Ambient.shared.wakeLine(species: self.species)
        if richer != first { self.say(richer, seconds: 3.8) }
      }
      pushOnline()
    } else {
      enterNap(sayLine: true)
    }
  }

  /// Send an action at a friend — their pet visits *here* for the gesture; theirs also visits *them*.
  /// Carries *your* stats only so they can refresh your FriendBond row — never renames anyone.
  private func sendToFriend(action: String, code: String, name: String) {
    Online.shared.setActive(code: code)
    logApp("menu_friend_\(action)", code: code, targetName: name)
    Online.shared.sync(fullness: fullness, happiness: happiness, action: action, toCode: code)
    let friendSpecies =
      Online.shared.friends.first(where: { $0.code == code })?.petSpecies ?? .dog
    let label = Self.visitLabel(actor: petName, action: action, toward: name, incoming: false)
    presentVisit(
      code: code,
      name: name,
      species: friendSpecies,
      action: action,
      label: label,
      role: .outgoingTarget,
      ephemeral: visitor?.code != code)
    // Your pet also performs the gesture toward the visitor.
    performHostSideVisit(action: action)
  }

  /// Friend's pet jumps onto your screen, does a species gesture, then leaves.
  private func receiveFriendVisit(
    action: String, fromName: String, code: String?, species: Species
  ) {
    let bond =
      (code.flatMap { c in Online.shared.friends.first(where: { $0.code == c }) })
      ?? Online.shared.friends.first(where: { $0.partnerName == fromName })
    let visitCode = bond?.code ?? code ?? "visit"
    let visitName = bond?.partnerName.isEmpty == false ? bond!.partnerName : fromName
    let visitSpecies = bond?.petSpecies ?? species
    logApp(
      "visit_received_\(action)", code: visitCode, targetName: visitName,
      extra: ["fromSpecies": visitSpecies.rawValue])
    let label = Self.visitLabel(
      actor: visitName, action: action, toward: "you", incoming: true)
    presentVisit(
      code: visitCode,
      name: visitName,
      species: visitSpecies,
      action: action,
      label: label,
      role: .incomingActor,
      ephemeral: true)
    // Stats / your pet's reaction — play waits for the visit beat via onPlayWithHost.
    if action != "play" {
      playRemote(action)
    } else {
      // Soften: still bump happiness; animation kicks off when visitor starts playing.
      happiness = min(100, happiness + 12)
    }
  }

  private func presentVisit(
    code: String,
    name: String,
    species: Species,
    action: String,
    label: String,
    role: FriendVisitor.VisitRole,
    ephemeral: Bool
  ) {
    let reuse = visitor?.code == code ? visitor : nil
    if reuse == nil {
      visitor?.dismiss()
      let v = FriendVisitor(
        code: code, name: name, species: species, near: x,
        ephemeral: ephemeral, quiet: true)
      v.hostX = { [weak self] in self?.x ?? 0 }
      v.hostY = { [weak self] in self?.y ?? 0 }
      visitor = v
    } else {
      reuse?.update(name: name, species: species)
    }
    guard let v = visitor else { return }
    v.hostX = { [weak self] in self?.x ?? 0 }
    v.hostY = { [weak self] in self?.y ?? 0 }
    v.onPlayWithHost = { [weak self] in
      guard let self else { return }
      if role == .incomingActor {
        self.startSignatureMove(seconds: 5)
      } else {
        self.startSignatureMove(seconds: 5)
      }
    }
    let wasEphemeral = ephemeral && reuse == nil
    v.beginVisit(action: action, label: label, role: role) { [weak self] in
      guard let self else { return }
      if wasEphemeral, self.visitor?.code == code {
        self.visitor?.dismiss()
        self.visitor = nil
      }
    }
    say(label, seconds: 2.8)
  }

  private func performHostSideVisit(action: String) {
    switch action {
    case "pet":
      // Your pet delivers the pats (species flavor).
      happyTicks = Int(2.5 * fps)
      switch species {
      case .dog:
        emit("❤️", count: 4)
        hop()
      case .bird:
        emit("✨", count: 3)
        set(.fly, seconds: 2.5)
      case .octopus:
        emit("🫧", count: 3)
        set(.glide, seconds: 2.5)
      }
    case "poke":
      // You're poking *them* — a playful jab, not getting mad yourself.
      emit("💢", count: 2)
      hop()
    case "feed":
      set(.eat, seconds: 2.5)
      emit(species == .bird ? "seed" : (species == .octopus ? "🦀" : "🍖"))
    case "play":
      break // kicked off together via visitor onPlayWithHost
    case "nap":
      // You're tucking *them* in — don't nap yourself.
      emit("💤", count: 2)
    default:
      break
    }
  }

  private static func visitLabel(
    actor: String, action: String, toward: String, incoming: Bool
  ) -> String {
    let a = actor.isEmpty ? "friend" : actor
    if incoming {
      return switch action {
      case "feed": "\(a) feeds you 🍖"
      case "play": "\(a) wants to play 🎾"
      case "pet": "\(a) pats you ❤️"
      case "nap": "\(a) tucks you in 💤"
      case "poke": "\(a) pokes you 💢"
      default: "\(a) → \(action)"
      }
    }
    return switch action {
    case "feed": "you feed \(toward) 🍖"
    case "play": "you play with \(toward) 🎾"
    case "pet": "you pat \(toward) ❤️"
    case "nap": "you tuck \(toward) in 💤"
    case "poke": "you poke \(toward) 💢"
    default: "→ \(toward)"
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
    logApp("choose_species", extra: ["from": species.rawValue, "to": next.rawValue])
    let oldDefault = species.defaultName
    species = next
    Online.shared.mySpecies = next
    // If they were still using the old default name, switch to the new pet's name.
    if Online.shared.displayName == oldDefault || Online.shared.displayName == defaultPetName {
      Online.shared.displayName = next.defaultName
    }
    sprites.removeAll()
    refreshStatusItem()
    say("hi! i'm \(Online.shared.displayName)", seconds: 2)
    pushOnline() // tell friends your new look
    render()
  }

  @objc private func showFriendOnScreen(_ sender: NSMenuItem) {
    guard let code = sender.representedObject as? String,
          let f = Online.shared.friends.first(where: { $0.code == code }), !f.waiting
    else { return }
    logApp("show_friend", code: code, targetName: f.partnerName,
           extra: ["species": f.petSpecies.rawValue])
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
    logApp("hide_friend", code: visitor?.code, targetName: visitor?.name)
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

  @objc private func pokeSelf() {
    logApp("self_poke")
    getAngry(fromPoke: true)
    pushOnline()
  }

  @objc private func quit() {
    logApp("app_quit")
    save()
    Online.shared.disconnect()
    NSApp.terminate(nil)
  }

  // MARK: Online — bonds

  @objc private func onlineShareCode() {
    ensureDisplayName()
    logApp("menu_share_code")
    Online.shared.shareMyCode(fullness: fullness, happiness: happiness) { [weak self] code in
      guard let self else { return }
      guard let code else {
        self.logApp("share_code_fail")
        self.alert("Couldn’t reach the server.\nCheck your internet and try again.")
        return
      }
      self.logApp("share_code_ok", code: code)
      let site = "https://tamagotchi-udtz.onrender.com"
      let msg = """
      CoPet code \(code)

      1) download \(site)
      2) menu → Bonds → Accept a code → paste \(code)

      Same code forever — share it in a group chat and anyone can find me.
      """
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(msg, forType: .string)
      self.onlineNote = "your code · \(code)"
      self.alert("Code copied.\n\nYour code is \(code) — it stays the same, so you can paste it in a group chat.")
    }
  }

  @objc private func onlineClaim() {
    ensureDisplayName()
    let code = prompt(
      "Accept a code",
      message: "Paste a friend’s 6-letter CoPet code (or the whole invite text).",
      placeholder: "")
    guard let code, !code.isEmpty else { return }
    let token = Online.extractCode(code)
    logApp("menu_claim", code: token)
    onlineNote = "joining \(token)…"
    Online.shared.join(code: token)
  }

  @objc private func onlineLeave() {
    logApp("menu_leave_all_bonds",
           extra: ["friendCount": Online.shared.friends.count])
    Online.shared.leaveAllBonds()
    onlineNote = nil
    partnerWasOnline = false
    refreshStatusItem()
    say("bye bye…")
  }

  @objc private func selectFriend(_ sender: NSMenuItem) {
    guard let code = sender.representedObject as? String else { return }
    Online.shared.setActive(code: code)
    if let f = Online.shared.activeFriend, !f.waiting {
      logApp("select_friend", code: code, targetName: f.partnerName)
      say("targeting \(f.partnerName)", seconds: 2)
    }
    refreshStatusItem()
  }

  @objc private func removeFriend(_ sender: NSMenuItem) {
    guard let code = sender.representedObject as? String else { return }
    let name = Online.shared.friends.first(where: { $0.code == code })?.partnerName
    logApp("remove_friend", code: code, targetName: name)
    Online.shared.removeFriend(code: code)
    refreshStatusItem()
  }

  @objc private func onlineSetName() {
    if let name = prompt(
      "Your name",
      message: "This is your pet’s name in the menu, and what friends see when they pet/feed you.",
      placeholder: Online.shared.displayName),
       !name.isEmpty
    {
      logApp("rename", extra: ["newName": name])
      Online.shared.displayName = name
      refreshStatusItem()
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
    a.messageText = "CoPet"
    a.informativeText = text
    a.addButton(withTitle: "OK")
    NSApp.activate(ignoringOtherApps: true)
    a.runModal()
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    menu.addItem(info("Fullness   \(bar(fullness))"))
    menu.addItem(info("Happiness  \(bar(happiness))"))

    let friends = Online.shared.friends
    let onlineN = friends.filter { $0.online && !$0.waiting }.count
    menu.addItem(info("Friends    \(friends.count) · \(onlineN) online"))

    if let note = onlineNote {
      menu.addItem(info(note))
    }
    menu.addItem(.separator())

    if !hidden {
      menu.addItem(info(petName))
      menu.addItem(item("💢  Poke", #selector(pokeSelf)))
      menu.addItem(item("🍖  Feed", #selector(feed)))
      menu.addItem(item("🎾  Play", #selector(play)))
      menu.addItem(item("❤️  Pet", #selector(petFromMenu)))
      menu.addItem(item(isAsleep ? "☀️  Wake up" : "💤  Nap", #selector(toggleNap)))
      let speciesItem = NSMenuItem(title: "🐾  Choose pet…", action: nil, keyEquivalent: "")
      let speciesMenu = NSMenu()
      for sp in Species.allCases {
        let row = NSMenuItem(
          title: "\(sp.emoji)  \(sp.defaultName)",
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

    let friendsItem = NSMenuItem(
      title: "Friends (\(friends.count))",
      action: nil,
      keyEquivalent: "")
    let sub = NSMenu()
    if friends.isEmpty {
      sub.addItem(info("No friends yet — Invite or Claim"))
    } else {
      for f in friends {
        let mark = f.waiting ? "⏳" : (f.online ? "🟢" : "⚪️")
        let label = f.waiting ? "code \(f.code)" : shortFriendName(f.partnerName)
        let row = NSMenuItem(title: "\(mark)  \(label)", action: nil, keyEquivalent: "")
        if f.code == Online.shared.activeCode { row.state = .on }
        let person = NSMenu()

        if f.waiting {
          person.addItem(info("Waiting for them to join"))
          person.addItem(info("Code \(f.code)"))
        } else {
          person.addItem(info("\(f.petSpecies.emoji)  \(f.petSpecies.defaultName)  ·  full \(Int(f.fullness))%  ·  happy \(Int(f.happiness))%"))
          if let act = friendlyActivity(f.lastActivity) {
            person.addItem(info(act))
          }
          person.addItem(.separator())

          let focus = NSMenuItem(
            title: "✓  Select",
            action: #selector(selectFriend(_:)),
            keyEquivalent: "")
          focus.target = self
          focus.representedObject = f.code
          if f.code == Online.shared.activeCode { focus.state = .on }
          person.addItem(focus)

          let onScreen = visitor?.code == f.code
          let bring = NSMenuItem(
            title: onScreen ? "👁  Hide from screen" : "👁  Show on screen",
            action: onScreen ? #selector(hideFriendOnScreen(_:)) : #selector(showFriendOnScreen(_:)),
            keyEquivalent: "")
          bring.target = self
          bring.representedObject = f.code
          person.addItem(bring)

          for (title, sel) in [
            ("🍖  Feed", #selector(friendFeed(_:))),
            ("🎾  Play", #selector(friendPlay(_:))),
            ("❤️  Pet", #selector(friendPet(_:))),
            ("💢  Poke", #selector(friendPoke(_:))),
            ("💤  Tuck in", #selector(friendNap(_:))),
          ] as [(String, Selector)] {
            let m = item(title, sel)
            m.representedObject = f.code
            person.addItem(m)
          }
        }

        person.addItem(.separator())
        let rm = NSMenuItem(
          title: "Remove",
          action: #selector(removeFriend(_:)),
          keyEquivalent: "")
        rm.target = self
        rm.representedObject = f.code
        person.addItem(rm)

        row.submenu = person
        sub.addItem(row)
      }
    }
    friendsItem.submenu = sub
    menu.addItem(friendsItem)

    let bondsItem = item("Bonds…", nil, symbol: "link")
    let bondsMenu = NSMenu()
    bondsMenu.addItem(item("Share my code…", #selector(onlineShareCode), symbol: "square.and.arrow.up"))
    bondsMenu.addItem(item("Accept a code…", #selector(onlineClaim), symbol: "person.badge.plus"))
    if !friends.isEmpty {
      bondsMenu.addItem(.separator())
      bondsMenu.addItem(item("Leave all bonds", #selector(onlineLeave), symbol: "rectangle.portrait.and.arrow.right"))
    }
    bondsItem.submenu = bondsMenu
    menu.addItem(bondsItem)
    menu.addItem(item("My name…", #selector(onlineSetName), symbol: "pencil"))
    menu.addItem(item("Check for updates…", #selector(checkForUpdates), symbol: "arrow.triangle.2.circlepath"))
    menu.addItem(.separator())
    menu.addItem(item("Quit", #selector(quit), symbol: "xmark.circle"))
  }

  @objc private func checkForUpdates() {
    logApp("check_for_updates")
    Updater.shared.checkNow()
  }

  private func item(_ title: String, _ action: Selector?, symbol: String? = nil) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = action == nil ? nil : self
    if let symbol { item.image = menuSymbol(symbol) }
    return item
  }

  private func menuSymbol(_ name: String) -> NSImage? {
    let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    img?.isTemplate = true
    return img
  }

  private func info(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  private func shortFriendName(_ name: String, max: Int = 20) -> String {
    guard name.count > max else { return name }
    return String(name.prefix(max - 1)) + "…"
  }

  /// Skip noisy / technical last-activity lines in the menu.
  private func friendlyActivity(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    let lower = raw.lowercased()
    if lower.contains("server reset") || lower.contains("re-claim") || lower.contains("bond expired")
      || lower.contains("invite dead") || lower.contains("retrying")
    {
      return nil
    }
    if raw.count > 36 { return String(raw.prefix(35)) + "…" }
    return raw
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
    persistNap()
  }

  private func persistNap() {
    let d = UserDefaults.standard
    d.set(untilWoken, forKey: "mochiStickyNap")
    if untilWoken {
      d.set(Double(x), forKey: "mochiNapX")
      d.set(Double(y), forKey: "mochiNapY")
    }
  }

  private func restoreNapIfNeeded() {
    let d = UserDefaults.standard
    guard d.bool(forKey: "mochiStickyNap") else { return }
    untilWoken = true
    activity = .sleep
    activityTicks = Int(9_999 * fps)
    if d.object(forKey: "mochiNapX") != nil {
      x = CGFloat(d.double(forKey: "mochiNapX"))
      y = CGFloat(d.double(forKey: "mochiNapY"))
    }
    y = sleepFloor(in: screenFrame())
    render()
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
