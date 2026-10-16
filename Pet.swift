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
  /// Username + pet — e.g. "Viv Test's Zuzu" / "Ivars' Zuzu". Never overwritten by friend sync.
  private var petName: String {
    let n = Online.shared.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    return n.isEmpty ? "\(Online.possessive("me")) \(defaultPetName)" : n
  }
  private var applyingRemote = false
  private var onlineNote: String?
  private var hidden = false
  /// User (or partner) put them to sleep — stay asleep until Wake up.
  private var untilWoken = false
  /// Friend's pet visiting your desktop (their species + reactions).
  private var visitor: FriendVisitor?
  /// While a visit is playing, freeze wander so you stay face-to-face.
  private var hostingVisit = false
  /// Friend codes we've already announced as online this stretch (no spam).
  private var announcedOnline: Set<String> = []
  /// First presence snapshot only seeds who’s already online — no “just joined” spam.
  private var presenceBootstrapped = false
  /// When a friend last looked offline — clear announce after a real disconnect.
  private var offlineSince: [String: Date] = [:]
  /// Dedupe — keepalive / double-sync must not spawn phantom pads.
  private var lastVisitKey: String?
  private var lastVisitAt: TimeInterval = 0
  private static let visitActions: Set<String> = ["play", "poke", "talk"]
  /// Spotify is playing and Dance to Spotify is on — pulse on beat, chill wander.
  private var dancingToSpotify = false
  private var lastBeatPulse: TimeInterval = 0
  private var danceStep = 0
  private var lastBeatStrength: Double = 0.6
  /// When true, beat squash stretches tall instead of flat (PetView).
  private(set) var danceStretch = false
  /// Explicit dance pose so we aren’t stuck toggling sit ↔ walk legs.
  private var dancePoseOverride: Pose?
  private var dancePoseTicks = 0
  /// Status / context menu open — freeze dance so the menu doesn’t bounce with hops.
  private var menuIsOpen = false

  private var grabStart = CGPoint.zero, lastMouse = CGPoint.zero, grabOffset = CGPoint.zero
  /// Which body part the current press landed on (nose / head / tail…).
  private var grabPart: BodyPart = .body
  private var swallowRelease = false // double-click hide — don't also body-touch
  /// Wall-clock of last click-up — backup double-click detect if clickCount is flaky.
  private var lastClickReleaseAt: TimeInterval = 0
  private var pendingPetWork: DispatchWorkItem?
  private var lastDragTime: TimeInterval = 0
  private var throwVelocity = CGVector.zero
  private var dragged = false
  /// True from mouseDown through mouseUp so hit-testing can’t drop the drag mid-air.
  private var grabbing = false
  private var visitStartedAt: TimeInterval = 0
  /// Raised paw / tentacle while giving pets on an outgoing visit.
  private var visitPawTicks = 0
  /// Which care action is playing with the guest (drives host choreography).
  private var visitActionPlaying: String?
  /// Last time the human poked / fed / dragged / opened the menu, etc.
  private var lastUserTouch = ProcessInfo.processInfo.systemUptime
  /// Auto-nap from boredom (can self-wake and beg). User Nap stays sticky.
  private var idleNap = false
  private var idleAsleepAt: TimeInterval = 0
  /// Just woke from an idle nap — chatty until touched or they doze off again.
  private var seekingAttention = false
  private static let idleNapAfter: TimeInterval = 5 * 60
  /// How long an idle nap lasts before they wake up to bother you.
  private static let idleNapSleepFor: TimeInterval = 2.5 * 60
  /// Ignored after waking → back to sleep.
  private static let attentionIdleAfter: TimeInterval = 90
  /// How long you’ve been looking at the screen before a stretch / eye reminder.
  private static let stretchAfter: TimeInterval = 45 * 60
  /// Screen-on work clock (resets when the display sleeps or the Mac wakes).
  private var screenSessionStartedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
  private var screenSessionActive = true

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

    // First download / fresh install: pick Zuzu, Bloop, or Puff as the pad.
    if !PetPicker.hasChosen {
      let pick = PetPicker.runModal()
      species = pick
      Online.shared.mySpecies = pick
      Online.shared.padName = pick.defaultName
      sprites.removeAll()
      statusItem.button?.title = pick.emoji
      say("hi! i'm \(pick.defaultName)", seconds: 3.5)
    }

    window.orderFrontRegardless()
    restoreNapIfNeeded()
    wireAmbientGreetings()
    wireSpotifyDance()

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
    let nc = NSWorkspace.shared.notificationCenter
    // Opening the laptop lid / waking from sleep → hello again + fresh work clock.
    nc.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.beginScreenSession()
        guard !self.hidden else { return }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        Ambient.shared.maybeGreet(species: self.species, asleep: self.isAsleep, force: true) {
          [weak self] text, secs in
          self?.say(text, seconds: secs)
        }
      }
    }
    // Display off → pause the “you’ve been staring” clock.
    nc.addObserver(
      forName: NSWorkspace.screensDidSleepNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.screenSessionActive = false }
    }
    // Display back on → start a new stretch window.
    nc.addObserver(
      forName: NSWorkspace.screensDidWakeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.beginScreenSession() }
    }
  }

  private func beginScreenSession() {
    screenSessionActive = true
    screenSessionStartedAt = ProcessInfo.processInfo.systemUptime
  }

  /// Soft wellness nudge after ~45 min of continuous screen-on time.
  private func maybeStretchBreak() {
    guard screenSessionActive, !hidden, !isAsleep, !grabbing, !menuIsOpen else { return }
    // Don’t stomp a visit / gesture bubble.
    if bubble != nil, bubbleTicks > Int(1.0 * fps) { return }
    if hostingVisit || visitor?.isVisiting == true { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - screenSessionStartedAt >= Self.stretchAfter else { return }
    // Roll the window forward so the next nudge is another full stretch later.
    screenSessionStartedAt = now
    logApp("stretch_remind")
    sayFresh(PetLines.stretchBreak(species), seconds: 4.2)
    happyTicks = max(happyTicks, Int(2 * fps))
    switch species {
    case .dog:
      emit("👀", count: 1)
      hop()
    case .bird:
      emit("👀", count: 1)
      y = restFloor(in: screenFrame()) + 12
      set(.fly, seconds: 2.2)
    case .octopus:
      emit("👀", count: 1)
      set(.glide, seconds: 2.4)
    }
  }

  private var partnerWasOnline = false

  private func wireOnline() {
    Online.shared.onStatus = { [weak self] text in
      self?.onlineNote = text
    }
    Online.shared.onBondAlert = { [weak self] message, ok in
      guard let self else { return }
      self.say(ok ? message.components(separatedBy: "\n").first ?? message : "uh oh…", seconds: 3.5)
      self.alert(message)
    }
    Online.shared.onFriendsChanged = { [weak self] in
      self?.refreshStatusItem()
      self?.syncVisitorFromFriends()
    }
    Online.shared.onPresence = { [weak self] in
      guard let self else { return }
      self.refreshStatusItem()
      self.handlePresenceAnnouncements()
    }
    // Friend sent an action at *you* — their pet visits your screen, then your pet reacts.
    Online.shared.onSync = { [weak self] _, _, action, from, code, fromSpecies in
      guard let self, !self.hidden else { return }
      // Stats-only syncs must never spawn a visitor.
      guard let action,
            Self.visitActions.contains(action),
            !from.isEmpty,
            from != Online.shared.displayName
      else { return }
      self.applyingRemote = true
      let sp = Species.parse(fromSpecies ?? "")
      self.receiveFriendVisit(
        action: action, fromName: from, code: code, species: sp)
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

  /// Hide the desktop pad; reopen from the menu-bar emoji → Show.
  private func setHidden(_ hide: Bool) {
    guard hidden != hide else { return }
    hidden = hide
    grabbing = false
    dragged = false
    swallowRelease = hide
    pendingPetWork?.cancel()
    pendingPetWork = nil
    hostingVisit = false
    if hide {
      visitor?.dismiss()
      visitor = nil
      bubble = nil
      bubbleTicks = 0
      particles.removeAll()
      activity = .sit
      activityTicks = 0
      window.alphaValue = 0
      window.orderOut(nil)
      window.ignoresMouseEvents = true
      logApp("hide")
    } else {
      window.alphaValue = 1
      window.ignoresMouseEvents = false
      window.orderFrontRegardless()
      y = restFloor(in: screenFrame())
      activity = .sit
      activityTicks = Int(2 * fps)
      render()
      logApp("show")
      say("missed you", seconds: 2.0)
    }
    refreshStatusItem()
  }

  @objc private func showPet() {
    noteUserTouch()
    setHidden(false)
  }

  private func refreshStatusItem() {
    if hidden {
      statusItem.button?.title = "🫥"
      return
    }
    if !Online.shared.appearOnline {
      statusItem.button?.title = "\(species.emoji)⚪️"
      return
    }
    let onlineCount = Online.shared.friends.filter { $0.online && !$0.waiting }.count
    statusItem.button?.title = onlineCount > 0 ? "\(species.emoji)🟢" : species.emoji
  }

  /// Only announce a real offline → online transition. Never for “already online.”
  private func handlePresenceAnnouncements() {
    // While you’re hidden from friends, presence flaps are noise — ignore.
    guard Online.shared.appearOnline else { return }

    let friends = Online.shared.friends.filter { !$0.waiting }
    if !presenceBootstrapped {
      // Seed who’s already online so launch / reconnect doesn’t spam bubbles.
      for f in friends where f.online {
        announcedOnline.insert(f.code)
      }
      presenceBootstrapped = true
      partnerWasOnline = Online.shared.partnerOnline
      return
    }

    let now = Date()
    for f in friends {
      if f.online {
        offlineSince[f.code] = nil
        if !announcedOnline.contains(f.code) {
          announcedOnline.insert(f.code)
          if !hidden {
            let who = Online.tidyPossessiveLabel(f.partnerName)
            say("\(who) is online! 🟢", seconds: 3.0)
          }
        }
      } else if announcedOnline.contains(f.code) {
        // Short grace so a WS blip doesn’t re-fire “online!” a second later.
        let started = offlineSince[f.code] ?? now
        offlineSince[f.code] = started
        if now.timeIntervalSince(started) >= 20 {
          announcedOnline.remove(f.code)
          offlineSince[f.code] = nil
        }
      }
    }
    partnerWasOnline = Online.shared.partnerOnline
  }

  private func playRemote(_ action: String) {
    // Sticky nap is locked — friends can still nudge stats / leave a note, but
    // they cannot change activity except an explicit poke (wake + mad).
    if untilWoken, action != "poke" {
      switch action {
      case "play", "talk":
        happiness = min(100, happiness + 4)
      default:
        break
      }
      return
    }
    switch action {
    case "play":
      happiness = min(100, happiness + 12)
      startSignatureMove(seconds: 6)
    case "talk":
      happiness = min(100, happiness + 5)
      happyTicks = Int(3 * fps)
      set(.sit, seconds: 3.2)
      emit("💬", count: 2)
      sayFresh(PetLines.talk(species))
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

    maybeIdleNap()
    maybeWakeFromIdleNap()

    // Sticky nap: freeze until Wake up — unless it's an idle nap that just self-woke.
    if untilWoken {
      activity = .sleep
      vx = 0
      vy = 0
      targetX = nil
      wanderLock = nil
      y = sleepFloor(in: screenFrame())
      pinStaticSleepZzz()
      tickBubble() // still expire “friend online” bubbles while napping
      updateParticles()
      render()
      return
    }

    move(in: screenFrame())
    animate()
    updateParticles()
    chatter()
    // Check about once a second — cheap and won’t spam mid-frame.
    if tick % Int(fps) == 0 { maybeStretchBreak() }
    render()
  }

  private func move(in vf: CGRect) {
    // Never freeze physics while the user is dragging.
    if grabbing || activity == .held { return }

    // Safety: a stalled visit must not pin the pad mid-air forever.
    if hostingVisit, visitStartedAt > 0,
       ProcessInfo.processInfo.systemUptime - visitStartedAt > 12
    {
      hostingVisit = false
      visitor?.dismiss()
      visitor = nil
    }

    // Don't stroll away mid-visit — stay put, but keep the gesture pose animating
    // (run/walk/fly frames). Never convert fly→sit mid-play/poke.
    if hostingVisit || visitor?.isVisiting == true {
      if activity == .walk || activity == .run {
        y = restFloor(in: vf)
        if tick % 8 == 0 { walkFrame ^= 1 }
        return
      }
      if activity == .fly || activity == .glide {
        // Soft bob in place — still reads as flying/drifting.
        let base = species == .bird ? restFloor(in: vf) + 28 : restFloor(in: vf) + 14
        y = base + CGFloat(sin(Double(tick) / 5)) * 5
        if tick % 8 == 0 { walkFrame ^= 1 }
        return
      }
    }
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
    case .glide: // octopus — slow menace drift (never zippy)
      switch wanderAxis {
      case .horizontal:
        x += dir * 0.12
        if let lock = wanderLock { y = lock }
        if Int.random(in: 0..<260) == 0 { dir = -dir }
      case .vertical:
        let low = vf.minY + 12
        let high = vf.minY + 55
        if let lock = wanderLock { x = lock }
        y += dir * 0.09
        if y <= low { y = low; dir = 1 }
        if y >= high { y = high; dir = -1 }
      }
      if tick % 140 == 0 { emit(["💧", "🫧"].randomElement()!) }
    case .fall:
      vy -= species == .bird ? 0.55 : 0.9 // birds flutter-fall
      if species == .bird { vx *= 0.98 }
      x += vx
      y += vy
      let floor = restFloor(in: vf)
      if y <= floor {
        y = floor
        // One bounce when dropped from height, then settle.
        let bounceThresh: CGFloat = species == .bird ? -5 : -4
        if vy < bounceThresh, bounceCount < 1 {
          bounceCount = 1
          let damp: CGFloat = species == .bird ? 0.38 : 0.5
          vy = -vy * damp
          vy = max(vy, species == .bird ? 4 : 5.5)
          vx *= 0.6
          squashTicks = 8
          emit("💨")
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

  /// Where this species likes to rest. Birds sit on the real floor (flight uses perch/ceiling in `.fly`).
  private func restFloor(in vf: CGRect) -> CGFloat {
    switch species {
    case .octopus: return vf.minY + 20
    default: return vf.minY
    }
  }

  private func sleepFloor(in vf: CGRect) -> CGFloat {
    switch species {
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
    case .octopus: return 0.10 // lazy on “land”
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
    visitPawTicks = max(0, visitPawTicks - 1)
    if dancePoseTicks > 0 {
      dancePoseTicks -= 1
      if dancePoseTicks == 0 { dancePoseOverride = nil }
    }
    if blinkTicks > 0 { blinkTicks -= 1 } else if Int.random(in: 0..<150) == 0 { blinkTicks = 4 }
    tickBubble()
    if activity == .sleep {
      pinStaticSleepZzz()
    } else {
      particles.removeAll { ($0.text == "💤" || $0.text == "🫧") && $0.vel == .zero }
    }
    if activity == .fly && tick % 32 == 0 { emit(["🪶", "✨"].randomElement()!) }
    if activity == .run && species == .dog && tick % 35 == 0 { emit("💨") }

    activityTicks -= 1
    guard activityTicks <= 0, activity != .held, activity != .fall else { return }
    // Sticky nap always wins — never stomp sleep for dance or visits.
    if untilWoken {
      set(.sleep, seconds: 9_999)
      return
    }
    // Don't pick a new wander mid-visit — hold the current gesture pose.
    if hostingVisit || visitor?.isVisiting == true {
      if activity == .eat || activity == .sleep || activity == .run
          || activity == .walk || activity == .fly || activity == .glide
      {
        activityTicks = Int(1.2 * fps)
      } else {
        set(.sit, seconds: 1.2)
      }
      return
    }
    // Dance mode: pulseToBeat owns the choreography — don't reset to a dead sit loop.
    if isDanceMode {
      if activity == .fall || activity == .held { return }
      activityTicks = Int(2 * fps)
      return
    }
    // Only non-sticky (idle) sleeps can auto-wake.
    if activity == .sleep {
      set(.sit, seconds: 2)
      say("🥱")
    } else {
      chooseNext()
    }
  }

  /// Vibing to Spotify — never while napping.
  private var isDanceMode: Bool {
    guard !untilWoken, activity != .sleep else { return false }
    guard SpotifyDance.shared.enabled else { return false }
    if dancingToSpotify { return true }
    return lastBeatPulse > 0
      && ProcessInfo.processInfo.systemUptime - lastBeatPulse < 5
  }

  private func noteUserTouch() {
    lastUserTouch = ProcessInfo.processInfo.systemUptime
    seekingAttention = false
  }

  /// No human contact → tuck in. Shorter fuse while they're already begging for attention.
  private func maybeIdleNap() {
    guard !untilWoken, activity != .sleep, activity != .held, !grabbing else { return }
    // Mid-song dance counts as company — nap when the music (or the human) goes quiet.
    if isDanceMode { return }
    let limit = seekingAttention ? Self.attentionIdleAfter : Self.idleNapAfter
    guard ProcessInfo.processInfo.systemUptime - lastUserTouch >= limit else { return }
    logApp(seekingAttention ? "idle_nap_ignored" : "idle_nap")
    enterNap(sayLine: true, idle: true)
  }

  /// Idle naps self-wake after a bit and ask for pets / food / play.
  private func maybeWakeFromIdleNap() {
    guard untilWoken, idleNap else { return }
    guard ProcessInfo.processInfo.systemUptime - idleAsleepAt >= Self.idleNapSleepFor else { return }
    wakeForAttention()
  }

  private func wakeForAttention() {
    untilWoken = false
    idleNap = false
    seekingAttention = true
    persistNap()
    // Fresh attention window — not a user touch.
    lastUserTouch = ProcessInfo.processInfo.systemUptime
    let vf = screenFrame()
    y = restFloor(in: vf)
    activity = .sit
    activityTicks = Int(2.5 * fps)
    vx = 0
    vy = 0
    logApp("idle_wake_attention")
    begForAttention(force: true)
    switch species {
    case .dog: hop()
    case .bird:
      y = restFloor(in: vf) + 8
      set(.fly, seconds: 1.8)
    case .octopus:
      set(.glide, seconds: 2)
      emit("🫧")
    }
    pushOnline()
    render()
  }

  private func begForAttention(force: Bool) {
    let pool: [String] =
      if fullness < 40 {
        PetLines.hungry(species)
      } else if happiness < 45 {
        PetLines.lonely(species)
      } else {
        PetLines.lonely(species) + PetLines.checkIn(species)
      }
    say(PetLines.pick(pool, recent: &recentSays), seconds: 3.6, force: force)
  }

  private func chooseNext() {
    if untilWoken {
      set(.sleep, seconds: 9_999)
      return
    }
    // Dance to Spotify on (and awake) → pulseToBeat drives the moves.
    if SpotifyDance.shared.enabled {
      if activity != .fall, activity != .held {
        set(.sit, seconds: 4)
      }
      return
    }
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
      case .glide: 8...16 // octopus: long, slow drifts
      case .sleep: 20...45
      default: 2.5...7
      }
    set(next, seconds: .random(in: seconds))
    // Settle into the right height for this mood.
    let vf = screenFrame()
    switch next {
    case .fly:
      // Bird: restless — flip axes often, wider height band.
      wanderAxis = Int.random(in: 0..<3) == 0 ? .vertical : .horizontal
      y = vf.minY + CGFloat.random(in: 50...160)
      wanderLock = wanderAxis == .horizontal ? y : x
      say(["SKY— wait", "↑!!", "ooh— fly", "zoom unfinished", "wind!!"].randomElement()!)
    case .glide:
      wanderAxis = Int.random(in: 0..<4) == 0 ? .vertical : .horizontal
      y = restFloor(in: vf) + (wanderAxis == .horizontal ? CGFloat.random(in: 0...20) : 0)
      wanderLock = wanderAxis == .horizontal ? y : x
      if Bool.random() {
        say(["…watching", "hm.", "noted.", "🫧", "try harder"].randomElement()!)
      }
    case .walk, .run:
      wanderAxis = .horizontal
      wanderLock = nil
      if case .run = next, species == .dog, Bool.random() {
        say(["soft zoomies", "easy run~", "come along?"].randomElement()!)
      } else if case .walk = next, species == .bird, Bool.random() {
        say(["can't sit!!", "hop hop— wait", "ground?? briefly"].randomElement()!)
      }
    default:
      wanderAxis = .horizontal
      wanderLock = nil
    }
  }

  private func speciesIdleOptions(sleepy: Bool) -> [(Activity, Int)] {
    switch species {
    case .dog: // golden calm — sit + stroll, rare soft sprint
      return [(.sit, 36), (.walk, 40), (.sleep, sleepy ? 38 : 8), (.run, happiness > 60 ? 8 : 2)]
    case .bird: // ADHD air — fly dominates, almost never idle-sit
      return [(.fly, 62), (.walk, 14), (.sit, 10), (.sleep, sleepy ? 20 : 3)]
    case .octopus: // menace drift — observe (sit) then glide with intent
      return [(.glide, 44), (.sit, 36), (.sleep, sleepy ? 24 : 5)]
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
    let needy = hungry || sad || seekingAttention
    // Begging after an idle wake → chatty; needier → more often.
    let interval = Int((seekingAttention ? 22.0 : (needy ? 40.0 : 85.0)) * fps)
    guard tick % interval == 0 else { return }
    // Don't stomp a gesture bubble that's still being read.
    if bubble != nil, bubbleTicks > Int(0.8 * fps) { return }

    let chance: Double = seekingAttention ? 1.0 : (needy ? 0.95 : 0.55)
    guard Double.random(in: 0..<1) < chance else { return }

    if seekingAttention {
      begForAttention(force: false)
      return
    }
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
    let dancing = isDanceMode
    let happy = !angry && (happyTicks > 0 || dancing || activity == .eat || activity == .run || activity == .fly || visitPawTicks > 0)
    var l = Look(species: species)
    if visitPawTicks > 0, species == .dog || species == .octopus {
      l.pose = .hang // raised paw / tentacle while petting a friend
    } else if dancing, let pose = dancePoseOverride, dancePoseTicks > 0 {
      l.pose = pose
    } else {
      switch activity {
      case .walk, .run, .fly: l.pose = .walk(walkFrame)
      case .glide, .sit, .eat: l.pose = .sit
      case .sleep: l.pose = .lie
      case .held, .fall: l.pose = dancing ? .walk(walkFrame) : .hang
      }
    }
    // Don't blink-closed while dancing — reads as napping.
    if activity == .sleep || (blinkTicks > 0 && !angry && !dancing) {
      l.eyes = .closed
    } else if angry {
      l.eyes = .angry
    } else if happy {
      l.eyes = .happy
    } else {
      l.eyes = .open
    }
    l.tongue = !angry && (activity == .eat ? walkFrame == 0 : happy)
    // Octopus tentacle bob stays lazy even when “happy.”
    let wagFast = happy || dancing || activity == .fly || (activity == .glide && species != .octopus)
    l.wag = activity == .sleep || angry ? 0 : tick / (wagFast ? 3 : (activity == .glide ? 18 : 12)) % 2
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
    // Keep receiving mouse while grabbing/dragging — mid-air pads are easy to lose otherwise.
    window.ignoresMouseEvents = !(grabbing || activity == .held || isOverDog(NSEvent.mouseLocation))
    view.needsDisplay = true
  }

  private func isOverDog(_ m: CGPoint) -> Bool {
    guard let (col, row) = canvasCell(at: m) else { return false }
    return sprite.canvas[col, row] != nil
  }

  /// Canvas coords facing right (mirrors if the pet faces left).
  private func canvasCell(at m: CGPoint) -> (col: Int, row: Int)? {
    let lx = m.x - window.frame.minX - spriteOrigin.x
    let ly = m.y - window.frame.minY - spriteOrigin.y
    var col = Int((lx / scale).rounded(.down))
    let row = Canvas.h - 1 - Int((ly / scale).rounded(.down))
    if dir < 0 { col = Canvas.w - 1 - col }
    guard Canvas.contains(col, row) else { return nil }
    return (col, row)
  }

  private func bodyPart(at m: CGPoint) -> BodyPart {
    guard let (col, row) = canvasCell(at: m), sprite.canvas[col, row] != nil else {
      return .body
    }
    return BodyPart.hit(species: species, col: col, row: row, head: sprite.head)
  }

  var headPoint: CGPoint {
    let col = 25.5 + CGFloat(sprite.head.x), row = 3 + CGFloat(sprite.head.y)
    let mirrored = dir < 0 ? CGFloat(Canvas.w) - col : col
    return CGPoint(x: spriteOrigin.x + mirrored * scale, y: spriteOrigin.y + (CGFloat(Canvas.h) - row) * scale)
  }

  private func tickBubble() {
    guard bubbleTicks > 0 else { return }
    bubbleTicks -= 1
    if bubbleTicks == 0 { bubble = nil }
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
    noteUserTouch()
    // Break out of any stuck visit / freeze so the pad is always grab-able.
    hostingVisit = false
    if visitor != nil {
      visitor?.dismiss()
      visitor = nil
    }
    grabbing = true
    window.ignoresMouseEvents = false

    // Double-click → disappear (not nap). Show again from the menu-bar emoji.
    if clickCount >= 2 {
      setHidden(true)
      return
    }
    swallowRelease = false
    let m = NSEvent.mouseLocation
    grabStart = m
    lastMouse = m
    grabOffset = CGPoint(x: x - m.x, y: y - m.y)
    grabPart = bodyPart(at: m)
    throwVelocity = .zero
    dragged = false
    activity = .held
    activityTicks = Int(60 * fps)
    logApp("grab_start", extra: ["part": grabPart.rawValue])
  }

  func drag() {
    if swallowRelease { return }
    grabbing = true
    let m = NSEvent.mouseLocation
    if !dragged {
      guard hypot(m.x - grabStart.x, m.y - grabStart.y) > 3 else { return }
      dragged = true
      pendingPetWork?.cancel()
      pendingPetWork = nil
      targetX = nil
      activity = .held // untilWoken kept — land() puts them back to sleep
      logApp("drag_start", extra: ["part": grabPart.rawValue])
      // Tail / tentacle / wing tug gets a sharper protest; otherwise occasional carry chatter.
      let sensitive = grabPart == .tail || (species == .bird && grabPart == .limb)
      if sensitive || Bool.random() {
        sayFresh(PetLines.pull(species, grabPart), seconds: 2.4)
        if sensitive {
          angryTicks = max(angryTicks, Int(1.6 * fps))
          emit(species == .octopus ? "🫧" : "💢", count: 2)
        }
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
    grabbing = false
    if swallowRelease || hidden {
      swallowRelease = false
      return
    }
    if !dragged {
      let now = ProcessInfo.processInfo.systemUptime
      // Double-click (system count or two quick click-ups) → hide, never nap.
      if clickCount >= 2 || (lastClickReleaseAt > 0 && now - lastClickReleaseAt <= NSEvent.doubleClickInterval) {
        lastClickReleaseAt = 0
        pendingPetWork?.cancel()
        pendingPetWork = nil
        setHidden(true)
        return
      }
      lastClickReleaseAt = now
      // Defer body-touch so a second click can hide instead.
      pendingPetWork?.cancel()
      let part = grabPart
      let work = DispatchWorkItem { [weak self] in
        self?.pendingPetWork = nil
        guard let self, !self.hidden else { return }
        self.touchBody(part)
      }
      pendingPetWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
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

  private func enterNap(sayLine: Bool, idle: Bool = false) {
    let vf = screenFrame()
    untilWoken = true
    idleNap = idle
    seekingAttention = false
    if idle { idleAsleepAt = ProcessInfo.processInfo.systemUptime }
    // Nap pauses the vibe — dance resumes only after Wake up + music.
    dancingToSpotify = false
    lastBeatPulse = 0
    danceStretch = false
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
    noteUserTouch()
    untilWoken = false
    idleNap = false
    persistNap()
    let vf = screenFrame()
    y = restFloor(in: vf)
    activity = .sit
    activityTicks = Int(2 * fps)
  }

  /// Play / talk / poke should get them out of a sticky nap.
  @discardableResult
  private func wakeIfNapping() -> Bool {
    guard untilWoken || activity == .sleep else { return false }
    wakeStickyNap()
    return true
  }

  // MARK: Actions

  /// Single-click on a body part — different words / mood per nose, head, tail…
  private func touchBody(_ part: BodyPart) {
    noteUserTouch()
    logApp("self_touch", extra: ["part": part.rawValue])
    _ = wakeIfNapping()

    let likes =
      part == .head || part == .ear || part == .belly || part == .body
    let dislikes = part == .nose
    let wary = part == .tail || part == .limb

    if likes {
      happiness = min(100, happiness + 6)
      happyTicks = Int(2.6 * fps)
      angryTicks = 0
    } else if dislikes {
      happiness = max(0, happiness - 1)
      angryTicks = max(angryTicks, Int(1.4 * fps))
      happyTicks = 0
    } else if wary {
      happiness = min(100, happiness + 1)
      happyTicks = Int(1.2 * fps)
    }

    sayFresh(PetLines.touch(species, part), seconds: 2.8)

    switch (species, part) {
    case (.dog, .nose):
      emit("💢", count: 1)
      set(.sit, seconds: 1.8)
    case (.dog, .head), (.dog, .ear), (.dog, .belly), (.dog, .body):
      emit("❤️", count: likes ? 3 : 1)
      hop()
    case (.dog, .tail), (.dog, .limb):
      emit("✨", count: 1)
      set(.sit, seconds: 1.6)

    case (.bird, .nose):
      emit("💢", count: 1)
      y = restFloor(in: screenFrame()) + 14
      set(.fly, seconds: 1.8)
    case (.bird, .head), (.bird, .ear), (.bird, .belly), (.bird, .body):
      emit("✨", count: 3)
      y = restFloor(in: screenFrame()) + 10
      set(.fly, seconds: 2.4)
    case (.bird, .limb), (.bird, .tail):
      emit("🪶", count: 1)
      set(.sit, seconds: 1.6)

    case (.octopus, .nose):
      emit("🫧", count: 1)
      set(.sit, seconds: 1.8)
    case (.octopus, .head), (.octopus, .ear), (.octopus, .belly), (.octopus, .body):
      emit("🫧", count: 2)
      if likes { emit("❤️", count: 1) }
      set(.glide, seconds: 2.6)
    case (.octopus, .tail), (.octopus, .limb):
      emit("🫧", count: 2)
      set(.sit, seconds: 1.8)
    }

    pushOnline()
  }

  private func pet() {
    touchBody(.body)
  }

  @objc private func feed() {
    noteUserTouch()
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
    noteUserTouch()
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
    noteUserTouch()
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
    noteUserTouch()
    Online.shared.setActive(code: code)
    logApp("menu_friend_\(action)", code: code, targetName: name)
    Online.shared.noteInteraction(code: code, direction: .sent)
    if !Online.shared.appearOnline {
      say("turn on “Friends can visit” first", seconds: 2.5)
      // Still play the local visit preview on your screen.
    } else {
      // Sync reaches them only if both are in the bond room (🟢).
      Online.shared.sync(fullness: fullness, happiness: happiness, action: action, toCode: code)
      let friendOnline = Online.shared.friends.first(where: { $0.code == code })?.online == true
      if !friendOnline {
        say("\(name) looks offline ⚪️ — open CoPet on both Macs", seconds: 2.5)
      }
    }
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
      deferHostReaction: true)
  }

  /// Friend's pet jumps onto your screen, does a species gesture, then leaves.
  private func receiveFriendVisit(
    action: String, fromName: String, code: String?, species: Species
  ) {
    guard Self.visitActions.contains(action) else { return }
    let bond =
      (code.flatMap { c in Online.shared.friends.first(where: { $0.code == c }) })
      ?? Online.shared.friends.first(where: { $0.partnerName == fromName })
    let visitCode = bond?.code ?? code ?? "visit"
    let visitName = bond?.partnerName.isEmpty == false ? bond!.partnerName : fromName
    let visitSpecies = bond?.petSpecies ?? species
    // Same poke re-broadcast / keepalive echo → ignore.
    let key = "\(visitCode)|\(action)|\(fromName)"
    let now = ProcessInfo.processInfo.systemUptime
    if lastVisitKey == key, now - lastVisitAt < 2.8 { return }
    lastVisitKey = key
    lastVisitAt = now
    Online.shared.noteInteraction(code: visitCode, direction: .received)
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
      deferHostReaction: true)
  }

  /// Friend pads only appear for a brief interaction, then always leave.
  private func presentVisit(
    code: String,
    name: String,
    species: Species,
    action: String,
    label: String,
    role: FriendVisitor.VisitRole,
    deferHostReaction: Bool = false
  ) {
    // Never keep a lingering visitor — rebuild for each interaction.
    visitor?.dismiss()
    visitor = nil
    hostingVisit = true
    visitStartedAt = ProcessInfo.processInfo.systemUptime
    // Plant yourself so the guest can spawn on your hip.
    let vf = screenFrame()
    y = restFloor(in: vf)
    set(.sit, seconds: 5)
    let v = FriendVisitor(
      code: code, name: name, species: species, near: x,
      ephemeral: true, quiet: true)
    v.hostX = { [weak self] in self?.x ?? 0 }
    v.hostY = { [weak self] in self?.y ?? 0 }
    v.hostSpecies = { [weak self] in self?.species ?? .dog }
    visitor = v
    v.onPlayWithHost = { [weak self] in
      // In-place play — species-specific, don't sprint off-screen.
      guard let self else { return }
      self.happyTicks = Int(4.5 * fps)
      switch self.species {
      case .dog:
        self.set(.run, seconds: 4.5)
        self.hop()
        self.emit("🎾", count: 2)
        self.emit("💨", count: 1)
      case .bird:
        self.set(.fly, seconds: 4.5)
        self.emit("🪶", count: 2)
        self.emit("✨", count: 1)
      case .octopus:
        self.set(.glide, seconds: 4.5)
        self.emit("🫧", count: 2)
        self.emit("🌊", count: 1)
      }
    }
    v.onGestureStart = { [weak self] in
      guard let self else { return }
      if role == .incomingActor {
        // Label is only on the visitor — keep the host speechless.
        self.bubble = nil
        self.bubbleTicks = 0
      }
      if role == .incomingActor, deferHostReaction {
        // We *receive* their action — distinct reaction per verb.
        if action == "play" {
          self.happiness = min(100, self.happiness + 12)
          // onPlayWithHost owns the motion
        } else if action == "poke" {
          if self.untilWoken || self.activity == .sleep { self.wakeStickyNap() }
          self.happiness = max(0, self.happiness - 8)
          self.angryTicks = Int(2.6 * fps)
          // Recoil hop then mad glare — not a happy sit.
          self.hop()
          switch self.species {
          case .dog: self.set(.walk, seconds: 2.6)
          case .bird: self.set(.fly, seconds: 2.6)
          case .octopus: self.set(.glide, seconds: 2.6)
          }
          self.emit("💢", count: 2)
        } else if action == "talk" {
          self.happiness = min(100, self.happiness + 5)
          self.happyTicks = Int(4.0 * fps)
          self.set(.sit, seconds: 4.0)
          self.emit("💬", count: 2)
          self.sayFresh(PetLines.talk(self.species))
        } else {
          self.playRemote(action)
        }
      } else if role == .outgoingTarget {
        // We *give* the action — friend species is `species` on this visit.
        self.performHostSideVisit(action: action, friendSpecies: species)
      }
    }
    v.beginVisit(action: action, label: label, role: role) { [weak self] in
      guard let self else { return }
      self.hostingVisit = false
      self.visitStartedAt = 0
      // Always clear the guest pad after the visit — only your pet stays.
      if self.visitor?.code == code {
        self.visitor?.dismiss()
        self.visitor = nil
      }
    }
    // Belt-and-suspenders: force-dismiss if a visit stalls.
    let visitCode = code
    let forceAfter: TimeInterval = action == "poke" ? 5.0 : 10.0
    DispatchQueue.main.asyncAfter(deadline: .now() + forceAfter) { [weak self] in
      guard let self, self.visitor?.code == visitCode || self.hostingVisit else { return }
      self.hostingVisit = false
      self.visitStartedAt = 0
      self.visitor?.dismiss()
      self.visitor = nil
    }
    // Outgoing: one line on *you*. Incoming: visitor already has the only bubble.
    if role == .outgoingTarget {
      say(label, seconds: action == "poke" ? 2.6 : 2.8)
    } else {
      bubble = nil
      bubbleTicks = 0
    }
  }

  /// You are the actor on an outgoing visit — poke / play / talk with them.
  private func performHostSideVisit(action: String, friendSpecies: Species) {
    // Face the visitor.
    if let side = visitor?.visitSide { dir = side }
    switch action {
    case "poke":
      angryTicks = Int(2.6 * fps)
      emit("💢", count: 3)
      hop()
      // Lunge, don’t sit politely.
      switch species {
      case .dog: set(.walk, seconds: 2.6)
      case .bird: set(.fly, seconds: 2.6)
      case .octopus: set(.glide, seconds: 2.6)
      }
      visitPawTicks = Int(0.7 * fps)
    case "play":
      // Kick off our side of play (visitor also hops via onPlayWithHost).
      happyTicks = Int(4.5 * fps)
      switch species {
      case .dog:
        set(.run, seconds: 4.5)
        hop()
        emit("🎾", count: 2)
      case .bird:
        set(.fly, seconds: 4.5)
        emit("🪶", count: 2)
      case .octopus:
        set(.glide, seconds: 4.5)
        emit("🫧", count: 2)
      }
    case "talk":
      happyTicks = Int(4.0 * fps)
      set(.sit, seconds: 4.0)
      emit("💬", count: 2)
      sayFresh(PetLines.talk(species))
    default:
      break
    }
  }

  /// Float food from your pad toward the guest (handoff, not “I eat you”).
  private func emitTowardVisitor(_ text: String, count: Int = 2) {
    guard let side = visitor?.visitSide else {
      emit(text, count: count)
      return
    }
    let head = headPoint
    let n = min(count, 3)
    for i in 0..<n {
      particles.append(
        Particle(
          text: text,
          pos: CGPoint(x: head.x + side * 14, y: head.y - 2 + CGFloat(i) * 7),
          vel: CGVector(
            dx: side * CGFloat.random(in: 1.4...2.0),
            dy: CGFloat.random(in: 0.15...0.55)),
          life: 55, maxLife: 55))
    }
  }

  private static func visitLabel(
    actor: String, action: String, toward: String, incoming: Bool
  ) -> String {
    let a = actor.isEmpty ? "friend" : actor
    let raw: String
    if incoming {
      raw = switch action {
      case "play": "\(a) wants to play 🎾"
      case "poke": "\(a) pokes you 💢"
      case "talk": "\(a) says hi 💬"
      default: "\(a) → \(action)"
      }
    } else {
      raw = switch action {
      case "play": "I play with \(toward) 🎾"
      case "poke": "I poke \(toward) 💢"
      case "talk": "I talk with \(toward) 💬"
      default: "→ \(toward)"
      }
    }
    return Online.tidyPossessiveLabel(raw)
  }

  private func syncVisitorFromFriends() {
    guard let v = visitor,
          let f = Online.shared.friends.first(where: { $0.code == v.code })
    else { return }
    v.update(name: f.partnerName, species: f.petSpecies)
  }

  @objc private func chooseSpecies(_ sender: NSMenuItem) {
    noteUserTouch()
    guard let raw = sender.representedObject as? String,
          let next = Species(rawValue: raw)
    else { return }
    logApp("choose_species", extra: ["from": species.rawValue, "to": next.rawValue])
    species = next
    Online.shared.mySpecies = next // also rolls pad name if it was the old default
    sprites.removeAll()
    refreshStatusItem()
    say("hi! i'm \(Online.shared.padName)", seconds: 2)
    pushOnline() // tell friends your new look
    render()
  }

  @objc private func friendPlay(_ sender: NSMenuItem) {
    guard let code = sender.representedObject as? String,
          let name = Online.shared.friends.first(where: { $0.code == code })?.partnerName
    else { return }
    sendToFriend(action: "play", code: code, name: name)
  }

  @objc private func friendPoke(_ sender: NSMenuItem) {
    guard let code = sender.representedObject as? String,
          let name = Online.shared.friends.first(where: { $0.code == code })?.partnerName
    else { return }
    sendToFriend(action: "poke", code: code, name: name)
  }

  @objc private func friendTalk(_ sender: NSMenuItem) {
    guard let code = sender.representedObject as? String,
          let name = Online.shared.friends.first(where: { $0.code == code })?.partnerName
    else { return }
    sendToFriend(action: "talk", code: code, name: name)
  }

  /// Top-level poke — aims at the selected friend.
  @objc private func pokeActiveFriend() {
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

  @objc private func pokeSelf() {
    noteUserTouch()
    logApp("self_poke")
    getAngry(fromPoke: true)
    pushOnline()
  }

  @objc private func talkSelf() {
    noteUserTouch()
    logApp("self_talk")
    _ = wakeIfNapping()
    happiness = min(100, happiness + 4)
    happyTicks = Int(2.8 * fps)
    set(.sit, seconds: 2.8)
    emit("💬", count: 2)
    sayFresh(PetLines.talk(species))
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

  @objc private func removeFriend(_ sender: NSMenuItem) {
    guard let code = sender.representedObject as? String else { return }
    let name = Online.shared.friends.first(where: { $0.code == code })?.partnerName ?? "friend"
    let alert = NSAlert()
    alert.messageText = "Remove bond?"
    alert.informativeText = "Unbind from \(name)? You can accept their code again later."
    alert.addButton(withTitle: "Remove bond")
    alert.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    logApp("remove_friend", code: code, targetName: name)
    Online.shared.removeFriend(code: code)
    if visitor?.code == code {
      visitor?.dismiss()
      visitor = nil
    }
    refreshStatusItem()
    say("unbound from \(name)", seconds: 2)
  }

  @objc private func onlineSetName() {
    noteUserTouch()
    if let user = prompt(
      "Username",
      message: "Your name (e.g. Viv Test). Friends see “Username’s Pet” — like Viv Test’s Zuzu. Names ending in s use a trailing apostrophe (Ivars’ Zuzu).",
      placeholder: Online.shared.ownerName),
       !user.isEmpty
    {
      Online.shared.ownerName = user
      logApp("rename_owner", extra: ["owner": user])
    }
    if let pet = prompt(
      "Pet name",
      message: "Your pet’s name. Defaults: Zuzu (dog), Puff (bird), Bloop (octopus).",
      placeholder: Online.shared.padName),
       !pet.isEmpty
    {
      Online.shared.padName = pet
      logApp("rename_pad", extra: ["pad": pet])
    }
    refreshStatusItem()
    say("hi! i'm \(Online.shared.displayName)", seconds: 3)
  }

  @objc private func toggleAppearOnline() {
    applyVisitPresence(!Online.shared.appearOnline)
  }

  /// Pad presence — game language, not “online/offline.”
  private func applyVisitPresence(_ friendsCanVisit: Bool) {
    guard friendsCanVisit != Online.shared.appearOnline else { return }
    Online.shared.setAppearOnline(friendsCanVisit)
    logApp(friendsCanVisit ? "appear_online" : "appear_offline")
    say(friendsCanVisit ? "back on the pad ✨" : "hiding for a bit 🌙", seconds: 2)
    refreshStatusItem()
  }

  private func ensureDisplayName() {
    let d = UserDefaults.standard
    if d.string(forKey: "mochiOwnerName") == nil, d.string(forKey: "mochiName") == nil {
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

  func menuWillOpen(_ menu: NSMenu) {
    noteUserTouch()
    menuIsOpen = true
    // Settle mid-hop so the panel doesn’t ride the bounce.
    if activity == .fall {
      vx = 0
      vy = 0
      y = restFloor(in: screenFrame())
      activity = .sit
      activityTicks = Int(2 * fps)
      squashTicks = 0
      danceStretch = false
      render()
    }
  }

  func menuDidClose(_ menu: NSMenu) {
    menuIsOpen = false
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()

    if hidden {
      menu.addItem(item("Show \(Online.shared.padName)…", #selector(showPet), symbol: "eye"))
      menu.addItem(.separator())
    }

    // --- Identity → pet → presence → stats ---
    menu.addItem(item("My username / pet name…", #selector(onlineSetName), symbol: "pencil"))
    if !hidden {
      let speciesItem = NSMenuItem(title: "Choose pet…", action: nil, keyEquivalent: "")
      speciesItem.image = menuSymbol("pawprint")
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
    }
    // Card: name + meters + presence dot
    let card = PadMenuCard(frame: NSRect(x: 0, y: 0, width: 248, height: 72))
    card.configure(
      emoji: species.emoji,
      name: petName,
      fullness: fullness,
      happiness: happiness,
      friendsCanVisit: Online.shared.appearOnline)
    card.onVisitChanged = { [weak self] on in
      self?.applyVisitPresence(on)
    }
    let cardItem = NSMenuItem()
    cardItem.view = card
    menu.addItem(cardItem)

    if !hidden {
      menu.addItem(.separator())
      // Care actions tucked away — keeps the top-level menu short for first-timers.
      let careItem = NSMenuItem(title: "Care…", action: nil, keyEquivalent: "")
      careItem.image = menuSymbol("heart")
      let careMenu = NSMenu()
      careMenu.addItem(item("💢  Poke", #selector(pokeSelf)))
      careMenu.addItem(item("🎾  Play", #selector(play)))
      careMenu.addItem(item("💬  Talk", #selector(talkSelf)))
      let danceItem = item(
        SpotifyDance.shared.enabled ? "🎵  Stop dance" : "🎵  Dance to Spotify",
        #selector(toggleDanceToSpotify))
      if !SpotifyDance.shared.isAvailable { danceItem.isEnabled = false }
      careMenu.addItem(danceItem)
      careMenu.addItem(item(isAsleep ? "☀️  Wake up" : "💤  Nap", #selector(toggleNap)))
      careItem.submenu = careMenu
      menu.addItem(careItem)
    }

    // --- Friends & bonds ---
    menu.addItem(.separator())
    let friends = Online.shared.friends.sorted { a, b in
      // Closest bonds float up; waiting invites sink.
      if a.waiting != b.waiting { return !a.waiting && b.waiting }
      if a.togetherCount != b.togetherCount { return a.togetherCount > b.togetherCount }
      if a.online != b.online { return a.online && !b.online }
      return a.partnerName.localizedCaseInsensitiveCompare(b.partnerName) == .orderedAscending
    }
    let onlineN = friends.filter { $0.online && !$0.waiting }.count
    let friendsItem = NSMenuItem(
      title: "Friends (\(friends.count) · \(onlineN) online)",
      action: nil,
      keyEquivalent: "")
    let sub = NSMenu()
    if friends.isEmpty {
      sub.addItem(info("No friends yet — Invite or Claim under Bonds"))
    } else {
      for f in friends {
        let mark = f.waiting ? "⏳" : (f.online ? "🟢" : "⚪️")
        let label = f.waiting
          ? "code \(f.code)"
          : shortFriendName(Online.tidyPossessiveLabel(f.partnerName))
        // Heart sits between presence and name for close bonds.
        let heart = (!f.waiting ? f.bondHeart.map { "\($0) " } : nil) ?? ""
        let row = NSMenuItem(title: "\(mark)  \(heart)\(label)", action: nil, keyEquivalent: "")
        if f.code == Online.shared.activeCode { row.state = .on }
        let person = NSMenu()

        if f.waiting {
          person.addItem(info("Waiting for them to join"))
          person.addItem(info("Code \(f.code)"))
        } else {
          person.addItem(info("\(f.petSpecies.emoji)  \(f.petSpecies.defaultName)  ·  full \(Int(f.fullness))%  ·  happy \(Int(f.happiness))%"))
          if let together = f.togetherLabel {
            person.addItem(info(together))
          }
          if let act = friendlyActivity(f.lastActivity) {
            person.addItem(info(act))
          }
          person.addItem(.separator())

          for (title, sel) in [
            ("💢  Poke", #selector(friendPoke(_:))),
            ("🎾  Play", #selector(friendPlay(_:))),
            ("💬  Talk", #selector(friendTalk(_:))),
          ] as [(String, Selector)] {
            let m = item(title, sel)
            m.representedObject = f.code
            person.addItem(m)
          }
        }

        person.addItem(.separator())
        let rm = NSMenuItem(
          title: "Remove bond",
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

    menu.addItem(item("Check for updates…", #selector(checkForUpdates), symbol: "arrow.triangle.2.circlepath"))
    menu.addItem(item("Send feedback…", #selector(sendFeedback), symbol: "text.bubble"))

    // --- Quit alone ---
    menu.addItem(.separator())
    menu.addItem(item("Quit", #selector(quit), symbol: "xmark.circle"))
  }

  @objc private func sendFeedback() {
    noteUserTouch()
    let alert = NSAlert()
    alert.messageText = "Send feedback"
    alert.informativeText = "What’s working, what’s weird, what you wish CoPet did — we’ll save it."
    alert.addButton(withTitle: "Send")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 72))
    field.placeholderString = "Type a note…"
    field.stringValue = ""
    // Multi-line-ish: tall field is fine for short feedback.
    alert.accessoryView = field
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      say("empty note ✏️", seconds: 1.5)
      return
    }
    logApp("feedback_submit", extra: ["length": text.count])
    Online.shared.submitFeedback(text) { [weak self] ok in
      Task { @MainActor in
        if ok {
          self?.say("thanks for the note 💌", seconds: 2.2)
        } else {
          self?.say("couldn’t send — try again later", seconds: 2.5)
        }
      }
    }
  }

  @objc private func toggleDanceToSpotify() {
    noteUserTouch()
    let dance = SpotifyDance.shared
    guard dance.isAvailable else {
      alert("Dance to Spotify needs macOS 14.2 or later so Mochi can tap Spotify’s audio.")
      return
    }
    if dance.enabled {
      // Asleep with dance still on → treat the click as “resume,” not stop.
      if untilWoken || activity == .sleep {
        _ = wakeIfNapping()
        say("back to the music 🎵", seconds: 2)
        logApp("spotify_dance_resume")
        return
      }
      dance.setEnabled(false)
      dancingToSpotify = false
      lastBeatPulse = 0
      say("ok, quiet mode", seconds: 2)
      logApp("spotify_dance_off")
      return
    }
    // Same as Play / Talk — dance ends a nap; no separate Wake up needed.
    _ = wakeIfNapping()
    let a = NSAlert()
    a.messageText = "Dance to Spotify?"
    a.informativeText =
      "Same as Play — but for music. Mochi listens only to the Spotify desktop app and dances on the beat. Speakers or Bluetooth headphones both work. Allow audio capture (and Spotify Automation) if macOS asks."
    a.addButton(withTitle: "Dance")
    a.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    guard a.runModal() == .alertFirstButtonReturn else { return }
    dance.setEnabled(true)
    say("put on a song 🎵", seconds: 2.5)
    logApp("spotify_dance_on")
  }

  private func wireSpotifyDance() {
    let dance = SpotifyDance.shared
    dance.onBeat = { [weak self] strength in
      self?.lastBeatStrength = strength
      self?.pulseToBeat()
    }
    dance.onTrackChange = { [weak self] track in
      guard let self, dance.enabled, !self.untilWoken, self.activity != .sleep else { return }
      self.say("vibing to \(track.name)", seconds: 2.4, force: false)
    }
    dance.onPlayingChange = { [weak self] playing in
      guard let self else { return }
      // Nap always wins — music does not wake a sticky sleep.
      if self.untilWoken || self.activity == .sleep {
        self.dancingToSpotify = false
        return
      }
      self.dancingToSpotify = playing && dance.enabled
    }
    dance.onError = { [weak self] message in
      guard let self, !self.untilWoken, self.activity != .sleep else { return }
      if message.localizedCaseInsensitiveContains("Screen & System Audio") {
        self.say("need audio permission…", seconds: 3.2)
      } else if message.localizedCaseInsensitiveContains("isn’t running") {
        self.say("open Spotify first", seconds: 2.5)
      } else {
        self.say("can’t hear Spotify…", seconds: 2.8)
      }
    }
    if dance.enabled { dance.start() }
  }

  /// Pulse on the locked beat grid. Mix of poses + hops — not sit↔stand forever.
  private func pulseToBeat() {
    guard SpotifyDance.shared.enabled, !hidden, !grabbing, !menuIsOpen else { return }
    guard !untilWoken, activity != .sleep else { return }
    guard dancingToSpotify || isDanceMode else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastBeatPulse > 0.16 else { return }
    lastBeatPulse = now
    dancingToSpotify = true
    happyTicks = max(happyTicks, Int(0.45 * fps))
    danceStep += 1
    let strength = lastBeatStrength
    let accent = strength >= 0.85 || danceStep % 4 == 1

    emit(accent ? "🎵" : (Bool.random() ? "♪" : "🎶"), count: accent ? 2 : 1)

    let floorY = restFloor(in: screenFrame())
    let grounded = activity != .held && activity != .fall && y <= floorY + 3
    danceStretch = false
    squashTicks = max(squashTicks, accent ? 9 : 6)

    // Rotating move catalog — different every beat, accents get bigger ones.
    applyDanceMove(step: danceStep, accent: accent, grounded: grounded)

    if accent, Int.random(in: 0..<6) == 0 {
      say(["🎵", "🎶", "♪~"].randomElement()!, seconds: 0.9, force: false)
    }
    render()
  }

  /// Hold a dance pose for a few frames (overrides sit/walk flicker).
  private func holdDancePose(_ pose: Pose, beats: Double = 0.35) {
    dancePoseOverride = pose
    dancePoseTicks = max(dancePoseTicks, Int(beats * fps))
  }

  private func applyDanceMove(step: Int, accent: Bool, grounded: Bool) {
    // Species-flavored catalogs so dog isn’t only sit/stand.
    let moves: [Int] =
      switch species {
      case .dog: [0, 1, 2, 3, 4, 5, 6, 7, 1, 8, 2, 4]
      case .bird: [0, 9, 2, 10, 3, 9, 5, 10]
      case .octopus: [0, 11, 2, 12, 4, 11, 5, 12]
      }
    let move = moves[step % moves.count]
    walkFrame = step % 2

    switch move {
    case 0: // bob
      holdDancePose(.sit, beats: 0.28)
    case 1: // strut
      holdDancePose(.walk(walkFrame), beats: 0.4)
      if accent, grounded { startFall(vx: dir * 1.2, vy: 4.2) }
    case 2: // spin face
      dir = -dir
      holdDancePose(.walk(1), beats: 0.32)
    case 3: // hop
      holdDancePose(.hang, beats: 0.25)
      if grounded { startFall(vx: 0, vy: accent ? 6.2 : 4.5) }
    case 4: // stretch pose
      danceStretch = true
      squashTicks = max(squashTicks, 11)
      holdDancePose(.sit, beats: 0.45)
    case 5: // side hop
      holdDancePose(.walk(0), beats: 0.3)
      if grounded { startFall(vx: dir * (accent ? 2.4 : 1.5), vy: accent ? 5.5 : 4.0) }
    case 6: // paw up
      holdDancePose(.hang, beats: 0.55)
      if accent { emit("✨") }
    case 7: // play bow / low
      holdDancePose(.lie, beats: 0.4)
      if accent, grounded { startFall(vx: 0, vy: 3.8) }
    case 8: // double bounce
      holdDancePose(.walk(1), beats: 0.35)
      if grounded {
        startFall(vx: dir * 0.8, vy: 5.8)
      }
    case 9: // bird flutter
      holdDancePose(.walk(walkFrame), beats: 0.35)
      y = floorAbove(6 + CGFloat(step % 3) * 4)
      if accent { startFall(vx: dir * 1.4, vy: 5.0) }
    case 10: // bird hover then drop
      holdDancePose(.hang, beats: 0.3)
      y = floorAbove(18)
      if accent, grounded { startFall(vx: dir * 1.0, vy: 4.8) }
    case 11: // octopus wave
      holdDancePose(.hang, beats: 0.5)
      if accent { emit("🫧") }
    case 12: // octopus drift step (keep it lazy)
      holdDancePose(.sit, beats: 0.45)
      x += dir * (accent ? 1.2 : 0.6)
      if accent, grounded { startFall(vx: dir * 0.5, vy: 2.2) }
    default:
      holdDancePose(.sit, beats: 0.25)
    }
  }

  private func floorAbove(_ dy: CGFloat) -> CGFloat {
    restFloor(in: screenFrame()) + dy
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
    headerLine(title, secondary: true)
  }

  /// Non-clickable menu text that still reads clearly (not system-disabled grey).
  private func headerLine(_ title: String, secondary: Bool = false) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    let color: NSColor = secondary ? .secondaryLabelColor : .labelColor
    item.attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .font: NSFont.menuFont(ofSize: 0),
        .foregroundColor: color,
      ])
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
    // Only user-requested sticky naps survive relaunch — idle dozes are temporary.
    let sticky = untilWoken && !idleNap
    d.set(sticky, forKey: "mochiStickyNap")
    if sticky {
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
