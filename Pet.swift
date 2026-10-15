import AppKit

// MARK: - Pet brain

@MainActor final class Pet: NSObject, NSMenuDelegate {
  enum Activity { case walk, run, sit, sleep, eat, held, fall }

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
  private var tick = 0, walkFrame = 0, happyTicks = 0, blinkTicks = 0, bubbleTicks = 0
  private var greeted = false

  private(set) var bubble: String?
  private(set) var particles: [Particle] = []
  private(set) var sprite = Dog.sprite(Look())
  private var sprites: [Look: Sprite] = [:]

  private var fullness: Double
  private var happiness: Double
  private var petName = defaultPetName
  private var applyingRemote = false
  private var onlineNote: String?
  private var hidden = false
  /// User (or partner) put them to sleep — stay asleep until Wake up.
  private var untilWoken = false

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
    window.orderFrontRegardless()

    statusItem.button?.title = "🐶"
    statusItem.menu = menu
    menu.delegate = self
    wireOnline()

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
    }
    Online.shared.onPresence = { [weak self] in
      guard let self else { return }
      self.refreshStatusItem()
      if let f = Online.shared.activeFriend, !f.waiting {
        self.petName = f.partnerName
      }
      let online = Online.shared.partnerOnline
      if online && !self.partnerWasOnline, let partner = Online.shared.partner, !self.hidden {
        self.say("\(partner) is online! 🟢", seconds: 2.5)
      } else if !online && self.partnerWasOnline, let partner = Online.shared.partner, !self.hidden {
        self.say("\(partner) went offline 💤", seconds: 2)
      }
      self.partnerWasOnline = online
    }
    Online.shared.onSync = { [weak self] f, h, action, from in
      guard let self else { return }
      self.applyingRemote = true
      self.fullness = f
      self.happiness = h
      if let partner = Online.shared.partner { self.petName = partner }
      if let action, !self.hidden {
        self.playRemote(action)
        let who = from.isEmpty ? "partner" : from
        let line: String =
          switch action {
          case "feed": "\(who) fed you! 🦴"
          case "play": "\(who) wants to play! 🎾"
          case "pet": "\(who) pet you! ❤️"
          case "nap": "\(who) tucked you in 💤"
          default: "\(who) → \(action)"
          }
        self.say(line, seconds: 2.5)
      }
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
    if onlineCount > 0 {
      statusItem.button?.title = "🐶🟢"
    } else {
      statusItem.button?.title = "🐶"
    }
  }

  private func playRemote(_ action: String) {
    switch action {
    case "feed":
      set(.eat, seconds: 3)
      emit("🦴")
    case "play":
      set(.run, seconds: 6)
    case "pet":
      happyTicks = Int(2 * fps)
      emit("❤️", count: 3)
      if activity != .sleep && !untilWoken { hop() }
    case "nap":
      untilWoken = true
      set(.sleep, seconds: 9_999)
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
      x += dir * (fullness < 20 ? 1.0 : 1.8)
    case .run:
      x += dir * 5
      if Int.random(in: 0..<50) == 0 { dir = -dir }
    case .fall:
      vy -= 1.1
      x += vx
      y += vy
      if y <= vf.minY {
        y = vf.minY
        land(impact: vy)
      }
    case .sleep:
      y = vf.minY
      vx = 0
      vy = 0
    case .held, .sit, .eat:
      break
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
    // Don't knock them out of a nap with tiny floor wobble / screen-frame shifts.
    if activity == .sleep || untilWoken {
      y = vf.minY
    } else if activity != .fall {
      if y > vf.minY + 0.5 { startFall(vx: 0, vy: 0) } else { y = vf.minY }
    }
  }

  private func animate() {
    if tick % (activity == .run ? 3 : 7) == 0 { walkFrame ^= 1 }
    happyTicks = max(0, happyTicks - 1)
    if blinkTicks > 0 { blinkTicks -= 1 } else if Int.random(in: 0..<150) == 0 { blinkTicks = 4 }
    if bubbleTicks > 0 {
      bubbleTicks -= 1
      if bubbleTicks == 0 { bubble = nil }
    }
    if activity == .sleep && tick % 45 == 0 { emit("💤") }

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
    let options: [(Activity, Int)] = [(.walk, 50), (.sit, 25), (.sleep, sleepy ? 40 : 6), (.run, happiness > 70 ? 8 : 2)]
    var roll = Int.random(in: 0..<options.reduce(0) { $0 + $1.1 })
    let next = options.first { roll -= $0.1; return roll < 0 }!.0
    if next == .walk, Bool.random() { dir = -dir }
    let seconds: ClosedRange<Double> =
      switch next {
      case .walk: 3...9
      case .run: 2...4
      case .sleep: 20...45
      default: 2...6
      }
    set(next, seconds: .random(in: seconds))
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
    if untilWoken {
      activity = .sleep
      activityTicks = Int(9_999 * fps)
      y = screenFrame().minY
      return
    }
    set(.sit, seconds: happyTicks > 0 ? 1.5 : 1)
    if !greeted {
      greeted = true
      say("hi! i'm \(petName) 🐾", seconds: 4)
    } else if impact < -18 {
      happiness = max(0, happiness - 2)
      say("ow!")
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
    guard tick % Int(75 * fps) == 0, activity != .sleep, bubble == nil, Double.random(in: 0..<1) < 0.6 else { return }
    let hour = Calendar.current.component(.hour, from: Date())
    let lines =
      fullness < 30 ? ["hungry… 🦴?", "feed me pls 🥺"]
      : happiness < 30 ? ["play with me…", "pet me?"]
      : hour >= 23 || hour < 6 ? ["sleepy 🌙"]
      : ["woof!", "*sniff sniff*", "bored… 🎾?"]
    say(lines.randomElement()!)
  }

  // MARK: Rendering

  private var look: Look {
    let happy = happyTicks > 0 || activity == .eat || activity == .run
    var l = Look()
    switch activity {
    case .walk, .run: l.pose = .walk(walkFrame)
    case .sit, .eat: l.pose = .sit
    case .sleep: l.pose = .lie
    case .held, .fall: l.pose = .hang
    }
    l.eyes = activity == .sleep || blinkTicks > 0 ? .closed : happy ? .happy : .open
    l.tongue = activity == .eat ? walkFrame == 0 : happy
    l.wag = activity == .sleep ? 0 : tick / (happy ? 3 : 10) % 2
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
      if Bool.random() { say(["put me down!", "wheee~"].randomElement()!) }
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
    happyTicks = Int(2 * fps)
    emit("❤️", count: 3)
    if activity == .sleep || untilWoken {
      say("mmh…? 🥱")
      pushOnline(action: "pet")
      return // don't hop — that was waking them out of nap
    }
    say(["woof!", "hehe~", "more pets", "❤️"].randomElement()!)
    hop()
    pushOnline(action: "pet")
  }

  @objc private func feed() {
    guard fullness < 95 else { return say("too full~ 😵") }
    fullness = min(100, fullness + 35)
    happiness = min(100, happiness + 4)
    set(.eat, seconds: 3)
    say("nom nom 🦴")
    emit("🦴")
    pushOnline(action: "feed")
  }

  @objc private func play() {
    happiness = min(100, happiness + 12)
    fullness = max(0, fullness - 3)
    set(.run, seconds: 6)
    say("zoomies!! 🎾")
    pushOnline(action: "play")
  }

  @objc private func toggleNap() {
    if activity == .sleep {
      untilWoken = false
      set(.sit, seconds: 2)
      say("🥱")
    } else {
      untilWoken = true
      set(.sleep, seconds: 9_999)
      say("zzz…")
      pushOnline(action: "nap")
    }
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
    if let f = Online.shared.activeFriend {
      petName = f.waiting ? defaultPetName : f.partnerName
      if !f.waiting { say("watching \(f.partnerName)", seconds: 2) }
    }
    refreshStatusItem()
  }

  @objc private func removeFriend(_ sender: NSMenuItem) {
    guard let code = sender.representedObject as? String else { return }
    Online.shared.removeFriend(code: code)
    if let f = Online.shared.activeFriend {
      petName = f.waiting ? defaultPetName : f.partnerName
    } else {
      petName = defaultPetName
    }
    refreshStatusItem()
  }

  @objc private func onlineSetName() {
    if let name = prompt("Your name", message: "Your partner’s pet will be named after you", placeholder: Online.shared.displayName),
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

    if let f = Online.shared.activeFriend, !f.waiting {
      let dot = f.online ? "🟢" : "⚪️"
      menu.addItem(info("\(dot) watching \(f.partnerName)"))
      menu.addItem(info("   🍖 \(bar(f.fullness))  💛 \(bar(f.happiness))"))
    } else if let note = onlineNote {
      menu.addItem(info("🔗 \(note)"))
    }
    menu.addItem(.separator())
    if !hidden {
      menu.addItem(item("🦴 Feed", #selector(feed)))
      menu.addItem(item("🎾 Play", #selector(play)))
      menu.addItem(item("🤚 Pet", #selector(petFromMenu)))
      menu.addItem(item(activity == .sleep ? "☀️ Wake up" : "💤 Nap", #selector(toggleNap)))
      menu.addItem(.separator())
    }
    menu.addItem(item(hidden ? "☀️ Show pet" : "😴 Hide pet (focus mode)", #selector(toggleHide)))
    menu.addItem(.separator())

    // Always show Friends so count / status is visible even at 0.
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
        if !f.waiting {
          sub.addItem(info("   🍖 \(Int(f.fullness))%  💛 \(Int(f.happiness))%"))
          if let activity = f.lastActivity {
            sub.addItem(info("   \(activity)"))
          }
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
