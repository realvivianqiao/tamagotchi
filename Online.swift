import AppKit
import Foundation

struct FriendBond: Codable, Equatable {
  var code: String
  var partnerName: String
  var online: Bool
  var waiting: Bool
  var fullness: Double
  var happiness: Double
  var lastActivity: String?
  /// Friend's chosen pet species raw value (dog/cat/bunny/fox/panda).
  var species: String

  var petSpecies: Species { Species.parse(species) }

  enum CodingKeys: String, CodingKey {
    case code, partnerName, online, waiting, fullness, happiness, lastActivity, species
  }

  init(
    code: String, partnerName: String, online: Bool, waiting: Bool,
    fullness: Double, happiness: Double, lastActivity: String? = nil,
    species: String = Species.dog.rawValue
  ) {
    self.code = code
    self.partnerName = partnerName
    self.online = online
    self.waiting = waiting
    self.fullness = fullness
    self.happiness = happiness
    self.lastActivity = lastActivity
    self.species = species
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    code = try c.decode(String.self, forKey: .code)
    partnerName = try c.decode(String.self, forKey: .partnerName)
    online = try c.decode(Bool.self, forKey: .online)
    waiting = try c.decode(Bool.self, forKey: .waiting)
    fullness = try c.decode(Double.self, forKey: .fullness)
    happiness = try c.decode(Double.self, forKey: .happiness)
    lastActivity = try c.decodeIfPresent(String.self, forKey: .lastActivity)
    species = try c.decodeIfPresent(String.self, forKey: .species) ?? Species.dog.rawValue
  }
}

/// Multi-friend bonds: invite/claim many people, see who's online, pick who's on your screen.
@MainActor final class Online: NSObject, URLSessionWebSocketDelegate {
  static let shared = Online()

  private let httpBase = URL(string: "https://tamagotchi-udtz.onrender.com")!
  private let wsURL = URL(string: "wss://tamagotchi-udtz.onrender.com")!

  var serverURL: URL {
    let raw = UserDefaults.standard.string(forKey: "mochiServer")?.trimmingCharacters(in: .whitespacesAndNewlines)
    // Ignore stale local-dev overrides so friends sync hits the live server.
    if let raw, !raw.isEmpty,
       !raw.contains("127.0.0.1"), !raw.contains("localhost"),
       let url = URL(string: raw)
    {
      return url
    }
    return wsURL
  }

  private var httpRoot: URL {
    let s = serverURL.absoluteString
      .replacingOccurrences(of: "wss://", with: "https://")
      .replacingOccurrences(of: "ws://", with: "http://")
    return URL(string: s) ?? httpBase
  }

  /// Public base for version.json / CoPet.zip downloads.
  var httpRootForUpdates: URL { httpRoot }

  /// Old bundle id used UserDefaults under this suite — migrate so CoPet keeps the same pad.
  private static let legacySuiteName = "com.vivianqiao.mochi"
  private static let migrateKeys = [
    "mochiDeviceId", "mochiName", "mochiSpecies", "mochiFriends", "mochiActiveCode",
    "mochiBondCode", "mochiBondPartner", "mochiStickyNap", "mochiNapX", "mochiNapY",
    "fullness", "happiness", "savedAt", "mochiServer",
  ]

  private static func migrateLegacyDefaultsIfNeeded() {
    let d = UserDefaults.standard
    if d.bool(forKey: "mochiMigratedFromMochi") { return }
    defer { d.set(true, forKey: "mochiMigratedFromMochi") }
    guard let legacy = UserDefaults(suiteName: legacySuiteName) else { return }
    let legacyId = legacy.string(forKey: "mochiDeviceId") ?? ""
    let currentId = d.string(forKey: "mochiDeviceId") ?? ""
    // Prefer the old pad id so cloud bond history stays on this Mac after the CoPet rename.
    if !legacyId.isEmpty {
      let hasLocalFriends = d.data(forKey: "mochiFriends") != nil
      if currentId.isEmpty || (!hasLocalFriends && currentId != legacyId) {
        d.set(legacyId, forKey: "mochiDeviceId")
      }
    }
    for key in migrateKeys where key != "mochiDeviceId" {
      if d.object(forKey: key) != nil { continue }
      if let val = legacy.object(forKey: key) {
        d.set(val, forKey: key)
      }
    }
  }

  /// Stable id for this Mac — one device = one user pad in Supabase (survives app updates).
  var deviceId: String {
    Self.migrateLegacyDefaultsIfNeeded()
    let key = "mochiDeviceId"
    if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
      return existing
    }
    let id = UUID().uuidString
    UserDefaults.standard.set(id, forKey: key)
    return id
  }

  var displayName: String {
    get {
      let n = UserDefaults.standard.string(forKey: "mochiName")?.trimmingCharacters(in: .whitespacesAndNewlines)
      return (n?.isEmpty == false) ? n! : NSFullUserName().split(separator: " ").first.map(String.init) ?? "me"
    }
    set {
      let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
      let old = UserDefaults.standard.string(forKey: "mochiName")
      UserDefaults.standard.set(trimmed, forKey: "mochiName")
      cloudPush(fullness: nil, happiness: nil)
      if old != trimmed {
        broadcastRename(trimmed)
      }
    }
  }

  var mySpecies: Species {
    get { Species.parse(UserDefaults.standard.string(forKey: "mochiSpecies")) }
    set {
      UserDefaults.standard.set(newValue.rawValue, forKey: "mochiSpecies")
      cloudPush(fullness: nil, happiness: nil)
    }
  }

  private(set) var friends: [FriendBond] = []
  private(set) var activeCode: String?
  private(set) var connected = false

  /// Convenience for the friend currently on your desktop.
  var partner: String? { activeFriend?.partnerName }
  var partnerOnline: Bool { activeFriend?.online ?? false }
  var isBonded: Bool { friends.contains { !$0.waiting } }

  /// fullness, happiness, action, fromName, roomCode, fromSpecies
  var onSync: ((Double, Double, String?, String, String?, String?) -> Void)?
  var onStatus: ((String) -> Void)?
  var onPresence: (() -> Void)?
  var onFriendsChanged: (() -> Void)?

  private var session: URLSession!
  private var task: URLSessionWebSocketTask?
  private var receiveLoop = false

  override init() {
    super.init()
    session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    loadFriends()
  }

  var activeFriend: FriendBond? {
    guard let activeCode else { return friends.first }
    return friends.first { $0.code == activeCode } ?? friends.first
  }

  /// Permanent group-chat share code for this Mac (created once, reused forever).
  var shareCode: String? {
    get {
      let c = UserDefaults.standard.string(forKey: "mochiShareCode")?
        .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      return (c?.count == 6) ? c : nil
    }
    set { UserDefaults.standard.set(newValue, forKey: "mochiShareCode") }
  }

  // MARK: - Public API

  /// Ensure / refresh your standing share-code (same code every time — paste in a group chat).
  func shareMyCode(fullness: Double, happiness: Double, completion: ((String?) -> Void)? = nil) {
    onStatus?("getting your code…")
    Task { @MainActor in
      do {
        var body: [String: Any] = [
          "name": displayName,
          "deviceId": deviceId,
          "fullness": fullness,
          "happiness": happiness,
          "personal": true,
        ]
        if let shareCode { body["code"] = shareCode }
        let res = try await postJSON(path: "/api/invite", body: body)
        guard let c = res["code"] as? String else {
          onStatus?("couldn’t get share code")
          completion?(nil)
          return
        }
        shareCode = c
        ensureSocket()
        send(["type": "hello", "deviceId": deviceId, "name": displayName])
        onStatus?("your code · \(c)")
        onFriendsChanged?()
        completion?(c)
      } catch {
        onStatus?("share failed: \(error.localizedDescription)")
        completion?(nil)
      }
    }
  }

  func create(fullness: Double, happiness: Double) {
    // Back-compat: old “invite” now means share your permanent code.
    shareMyCode(fullness: fullness, happiness: happiness)
  }

  func join(code raw: String) {
    let token = Self.extractCode(raw)
    // Already on this pad — bonding is once; just focus that friend.
    if let existing = friends.first(where: { $0.code == token && !$0.waiting }) {
      setActive(code: existing.code)
      onStatus?("already bonded with \(existing.partnerName)")
      ensureSocket()
      attach(code: existing.code)
      return
    }
    onStatus?("claiming \(token)…")
    Task { @MainActor in
      do {
        let res = try await postJSON(path: "/api/claim", body: [
          "name": displayName,
          "deviceId": deviceId,
          "code": token,
          "species": mySpecies.rawValue,
        ])
        if let err = res["error"] as? String {
          onStatus?(err)
          return
        }
        let host = (res["hostName"] as? String) ?? "friend"
        let f = Self.num(res, "fullness") ?? 80
        let h = Self.num(res, "happiness") ?? 80
        upsert(FriendBond(
          code: (res["code"] as? String) ?? token,
          partnerName: host, online: false, waiting: false,
          fullness: f, happiness: h,
          lastActivity: (res["alreadyBonded"] as? Bool == true) ? "reconnected" : "just bonded"))
        activeCode = (res["code"] as? String) ?? token
        saveFriends()
        onStatus?("bonded with \(host)")
        onFriendsChanged?()
        onPresence?()
        ensureSocket()
        attach(code: activeCode!)
      } catch {
        onStatus?("claim failed: \(error.localizedDescription)")
      }
    }
  }

  func setActive(code: String) {
    guard friends.contains(where: { $0.code == code }) else { return }
    activeCode = code
    saveFriends()
    if let f = activeFriend {
      onStatus?(f.online ? "🟢 \(f.partnerName) online" : "⚪️ \(f.partnerName) offline")
    }
    onFriendsChanged?()
    onPresence?()
  }

  func removeFriend(code: String) {
    friends.removeAll { $0.code == code }
    if activeCode == code { activeCode = friends.first?.code }
    saveFriends()
    send(["type": "detach", "code": code])
    onFriendsChanged?()
    onPresence?()
  }

  /// Last known pet metrics — attached to every event so Supabase rows are queryable.
  private(set) var lastFullness: Double = 80
  private(set) var lastHappiness: Double = 80

  func noteMetrics(fullness: Double, happiness: Double) {
    lastFullness = fullness
    lastHappiness = happiness
  }

  private var appVersion: String {
    let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    return "\(short) (\(build))"
  }

  /// Product analytics → `/api/event` → `mochi_events`.
  /// Always includes action owner, client timestamp, and current metrics.
  func track(
    _ event: String,
    code: String? = nil,
    targetName: String? = nil,
    fullness: Double? = nil,
    happiness: Double? = nil,
    payload: [String: Any] = [:]
  ) {
    if let fullness { lastFullness = fullness }
    if let happiness { lastHappiness = happiness }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var ts = iso.string(from: Date())
    if ts.isEmpty {
      iso.formatOptions = [.withInternetDateTime]
      ts = iso.string(from: Date())
    }
    var body: [String: Any] = [
      "deviceId": deviceId,
      "ownerDeviceId": deviceId,
      "displayName": displayName,
      "ownerName": displayName,
      "event": event,
      "species": mySpecies.rawValue,
      "friendCount": friends.filter { !$0.waiting }.count,
      "fullness": fullness ?? lastFullness,
      "happiness": happiness ?? lastHappiness,
      "clientTs": ts,
      "appVersion": appVersion,
      "payload": payload,
    ]
    if let code { body["code"] = code }
    if let targetName { body["targetName"] = targetName }
    Task {
      _ = try? await postJSON(path: "/api/event", body: body)
    }
  }

  /// Broadcast your pet's stats (and optional action aimed at the friend in this room).
  /// Does not overwrite that friend's stored stats — those update only when *they* sync.
  func sync(fullness: Double, happiness: Double, action: String? = nil, toCode: String? = nil) {
    let code = toCode ?? activeCode
    guard let code, connected else { return }
    if let action, let i = friends.firstIndex(where: { $0.code == code }) {
      friends[i].lastActivity = "you: \(action)"
      saveFriends()
    }
    var msg: [String: Any] = [
      "type": "sync", "code": code,
      "fullness": fullness, "happiness": happiness,
      "species": mySpecies.rawValue,
      "updatedAt": Int(Date().timeIntervalSince1970 * 1000),
    ]
    if let action { msg["action"] = action }
    send(msg)
  }

  func disconnect() {
    task?.cancel(with: .goingAway, reason: nil)
    task = nil
    connected = false
    receiveLoop = false
    for i in friends.indices { friends[i].online = false }
    onStatus?("offline")
    onPresence?()
    onFriendsChanged?()
  }

  func leaveAllBonds() {
    for f in friends { send(["type": "detach", "code": f.code]) }
    friends.removeAll()
    activeCode = nil
    saveFriends()
    disconnect()
  }

  func restoreBondIfAny() {
    _ = deviceId // ensure pad id exists + legacy migrate before cloud talk
    loadFriends()
    Task { @MainActor in
      await cloudPull()
      // Always register this device pad in the DB, even with an empty friends list.
      cloudPush(fullness: nil, happiness: nil)
      ensureSocket()
      send(["type": "hello", "deviceId": deviceId, "name": displayName])
      // Keep your standing share-code alive across Render sleeps.
      if shareCode != nil || !friends.isEmpty {
        shareMyCode(fullness: 80, happiness: 80)
      }
      guard !friends.isEmpty else {
        onStatus?("pad ready")
        return
      }
      if activeCode == nil { activeCode = friends.first?.code }
      onFriendsChanged?()
      onPresence?()
      for f in friends { attach(code: f.code) }
    }
  }

  /// Tell bonded partners our new display name so their Friends list updates live.
  private func broadcastRename(_ name: String) {
    guard connected, !friends.isEmpty else { return }
    for f in friends {
      send([
        "type": "rename",
        "code": f.code,
        "name": name,
        "deviceId": deviceId,
      ])
    }
  }

  static func extractCode(_ raw: String) -> String {
    let alphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    let upper = raw.uppercased()
    let tokens = upper.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    if let hit = tokens.last(where: { $0.count == 6 && Set($0).isSubset(of: alphabet) }) {
      return hit
    }
    return String(upper.filter { $0.isLetter || $0.isNumber }.prefix(6))
  }

  // MARK: - Friends storage

  private func upsert(_ bond: FriendBond) {
    if let i = friends.firstIndex(where: { $0.code == bond.code }) {
      var merged = bond
      if merged.partnerName == "waiting…", !friends[i].waiting {
        merged.partnerName = friends[i].partnerName
      }
      friends[i] = merged
    } else {
      friends.append(bond)
    }
  }

  private func saveFriends() {
    let d = UserDefaults.standard
    if let data = try? JSONEncoder().encode(friends) {
      d.set(data, forKey: "mochiFriends")
    }
    d.set(activeCode, forKey: "mochiActiveCode")
    cloudPush(fullness: nil, happiness: nil)
  }

  private func loadFriends() {
    let d = UserDefaults.standard
    if let data = d.data(forKey: "mochiFriends"),
       let list = try? JSONDecoder().decode([FriendBond].self, from: data)
    {
      friends = list.map {
        var f = $0
        f.online = false
        return f
      }
    } else if let c = d.string(forKey: "mochiBondCode") {
      // migrate single-bond
      let name = d.string(forKey: "mochiBondPartner") ?? "friend"
      friends = [FriendBond(code: c, partnerName: name, online: false, waiting: false, fullness: 80, happiness: 80, lastActivity: nil)]
      activeCode = c
      saveFriends()
      d.removeObject(forKey: "mochiBondCode")
      d.removeObject(forKey: "mochiBondPartner")
    }
    activeCode = d.string(forKey: "mochiActiveCode") ?? friends.first?.code
  }

  /// Push name / species / friends to Supabase via the Render API.
  func cloudPush(fullness: Double?, happiness: Double?) {
    let payloadFriends: [[String: Any]] = friends.map { f in
      var row: [String: Any] = [
        "code": f.code,
        "partnerName": f.partnerName,
        "waiting": f.waiting,
        "fullness": f.fullness,
        "happiness": f.happiness,
        "species": f.species,
      ]
      if let act = f.lastActivity { row["lastActivity"] = act }
      return row
    }
    var body: [String: Any] = [
      "deviceId": deviceId,
      "displayName": displayName,
      "species": mySpecies.rawValue,
      "friends": payloadFriends,
    ]
    if let activeCode { body["activeCode"] = activeCode }
    if let fullness { body["fullness"] = fullness }
    if let happiness { body["happiness"] = happiness }
    Task { @MainActor in
      do {
        _ = try await postJSON(path: "/api/me", body: body)
      } catch {
        // Cloud optional until Supabase env is set on Render.
      }
    }
  }

  /// Pull profile + friends from Supabase (fills empty local state; merges missing codes).
  func cloudPull() async {
    do {
      let res = try await getJSON(path: "/api/me?deviceId=\(deviceId)")
      if let name = res["displayName"] as? String, !name.isEmpty {
        let local = UserDefaults.standard.string(forKey: "mochiName")
        // Don't let a placeholder cloud row clobber a real local name.
        if local == nil || local?.isEmpty == true || name != "me" {
          UserDefaults.standard.set(name, forKey: "mochiName")
        }
      }
      if let sp = res["species"] as? String, !sp.isEmpty {
        UserDefaults.standard.set(sp, forKey: "mochiSpecies")
      }
      if let code = res["activeCode"] as? String, !code.isEmpty {
        activeCode = code
      }
      guard let raw = res["friends"] as? [[String: Any]] else { return }
      let cloud: [FriendBond] = raw.compactMap { row in
        guard let code = row["code"] as? String, !code.isEmpty else { return nil }
        return FriendBond(
          code: code,
          partnerName: (row["partnerName"] as? String) ?? "friend",
          online: false,
          waiting: (row["waiting"] as? Bool) ?? false,
          fullness: (row["fullness"] as? Double) ?? 80,
          happiness: (row["happiness"] as? Double) ?? 80,
          lastActivity: row["lastActivity"] as? String,
          species: (row["species"] as? String) ?? Species.dog.rawValue)
      }
      if friends.isEmpty {
        friends = cloud
      } else {
        for c in cloud where !friends.contains(where: { $0.code == c.code }) {
          friends.append(c)
        }
      }
      // Persist locally without re-triggering an immediate cloudPush loop
      let d = UserDefaults.standard
      if let data = try? JSONEncoder().encode(friends) {
        d.set(data, forKey: "mochiFriends")
      }
      d.set(activeCode, forKey: "mochiActiveCode")
      onFriendsChanged?()
    } catch {
      // ok if cloud not configured yet
    }
  }

  // MARK: - HTTP / WS

  private func postJSON(path: String, body: [String: Any]) async throws -> [String: Any] {
    guard let url = URL(string: path, relativeTo: httpRoot)?.absoluteURL else {
      throw NSError(domain: "CoPet", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad url"])
    }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.timeoutInterval = 60
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, resp) = try await URLSession.shared.data(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    if status >= 400 {
      if json["error"] != nil { return json }
      throw NSError(domain: "CoPet", code: status, userInfo: [NSLocalizedDescriptionKey: (json["error"] as? String) ?? "HTTP \(status)"])
    }
    return json
  }

  private func getJSON(path: String) async throws -> [String: Any] {
    guard let url = URL(string: path, relativeTo: httpRoot)?.absoluteURL else {
      throw NSError(domain: "CoPet", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad url"])
    }
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.timeoutInterval = 60
    let (data, resp) = try await URLSession.shared.data(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    if status >= 400 {
      throw NSError(domain: "CoPet", code: status, userInfo: [NSLocalizedDescriptionKey: (json["error"] as? String) ?? "HTTP \(status)"])
    }
    return json
  }

  private func ensureSocket() {
    if task != nil, connected { return }
    task?.cancel(with: .goingAway, reason: nil)
    receiveLoop = false
    let t = session.webSocketTask(with: serverURL)
    task = t
    receiveLoop = true
    t.resume()
    connected = true
    listen()
  }

  private func attach(code: String) {
    ensureSocket()
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 300_000_000)
      var msg: [String: Any] = [
        "type": "attach", "code": code, "name": displayName,
        "deviceId": deviceId,
        "species": mySpecies.rawValue,
        "fullness": friends.first(where: { $0.code == code })?.fullness ?? 80,
        "happiness": friends.first(where: { $0.code == code })?.happiness ?? 80,
      ]
      // Partner name lets the server rehydrate a wiped bond directory from client memory.
      if let f = friends.first(where: { $0.code == code }), !f.waiting, !f.partnerName.isEmpty {
        msg["partnerName"] = f.partnerName
      }
      send(msg)
    }
  }

  private func send(_ msg: [String: Any]) {
    guard let task, let data = try? JSONSerialization.data(withJSONObject: msg),
          let text = String(data: data, encoding: .utf8)
    else { return }
    task.send(.string(text)) { _ in }
  }

  private func listen() {
    guard let task, receiveLoop else { return }
    task.receive { [weak self] result in
      Task { @MainActor in
        guard let self else { return }
        switch result {
        case .failure:
          self.connected = false
          for i in self.friends.indices { self.friends[i].online = false }
          self.onPresence?()
          self.onFriendsChanged?()
        case .success(let message):
          if case .string(let text) = message { self.handle(text) }
          self.listen()
        }
      }
    }
  }

  private func handle(_ text: String) {
    guard let data = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = json["type"] as? String
    else { return }

    switch type {
    case "room":
      applyRoom(json)
    case "presence":
      applyPresence(json)
    case "bond":
      // Someone claimed your standing share-code — add them as a friend.
      guard let code = json["code"] as? String, !code.isEmpty else { break }
      let partner = (json["partnerName"] as? String) ?? "friend"
      let f = Self.num(json, "fullness") ?? 80
      let h = Self.num(json, "happiness") ?? 80
      let sp = (json["species"] as? String) ?? Species.dog.rawValue
      upsert(FriendBond(
        code: code, partnerName: partner, online: false, waiting: false,
        fullness: f, happiness: h, lastActivity: "just bonded", species: sp))
      if activeCode == nil { activeCode = code }
      saveFriends()
      onStatus?("bonded with \(partner)")
      onFriendsChanged?()
      onPresence?()
      attach(code: code)

    case "rename":
      // Partner changed their pet name — update local friend row + cloud.
      let code = json["code"] as? String
      let newName = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let from = (json["from"] as? String) ?? ""
      guard !newName.isEmpty, newName != displayName else { break }
      if let code, let i = friends.firstIndex(where: { $0.code == code }) {
        if friends[i].partnerName == from || friends[i].partnerName == "waiting…" || from.isEmpty {
          friends[i].partnerName = newName
          friends[i].lastActivity = "renamed to \(newName)"
          saveFriends()
          onFriendsChanged?()
          onPresence?()
        }
      } else if !from.isEmpty, let i = friends.firstIndex(where: { $0.partnerName == from }) {
        friends[i].partnerName = newName
        friends[i].lastActivity = "renamed to \(newName)"
        saveFriends()
        onFriendsChanged?()
        onPresence?()
      }
    case "sync":
      let code = (json["code"] as? String) ?? activeCode
      let f = Self.num(json, "fullness") ?? 0
      let h = Self.num(json, "happiness") ?? 0
      let action = json["action"] as? String
      let from = (json["from"] as? String) ?? ""
      // Own echoes (if any) must never rename bonds or rewrite lastActivity as "Me: pet".
      let fromMe = !from.isEmpty && from == displayName
      if fromMe {
        break
      }
      if let code, let i = friends.firstIndex(where: { $0.code == code }) {
        // Payload stats belong to `from` (the friend) — update their FriendBond only.
        friends[i].fullness = f
        friends[i].happiness = h
        friends[i].waiting = false
        if let sp = json["species"] as? String, !sp.isEmpty {
          friends[i].species = sp
        }
        // Never adopt `from` as partnerName except the initial waiting → bonded transition.
        if friends[i].partnerName == "waiting…", !from.isEmpty {
          friends[i].partnerName = from
        }
        if let action {
          friends[i].lastActivity = "\(from.isEmpty ? "friend" : from): \(action)"
        }
        saveFriends()
      }
      // Actions from a friend land on *your* dog. Stats in the callback are ignored by Pet.
      let fromSpecies = json["species"] as? String
      onSync?(f, h, action, from, code, fromSpecies)
      onFriendsChanged?()

    case "system":
      onStatus?(json["text"] as? String ?? "ok")
    case "error":
      let text = (json["text"] as? String) ?? "error"
      let code = json["code"] as? String
      onStatus?(text)
      // Render redeploys wipe /tmp invites — re-register waiting codes, else mark dead.
      if text.contains("room not found"), let code {
        Task { @MainActor in
          await self.healMissingRoom(code: code)
        }
      }
    default:
      break
    }
  }

  /// After a server wipe: recreate the invite/bond from *this Mac’s* saved friends list.
  /// Bonds live on each device; the server is just a realtime relay.
  private func healMissingRoom(code: String) async {
    guard let i = friends.firstIndex(where: { $0.code == code }) else { return }
    if friends[i].waiting {
      onStatus?("reconnecting…")
      do {
        let res = try await postJSON(path: "/api/invite", body: [
          "name": displayName,
          "deviceId": deviceId,
          "code": code,
          "fullness": friends[i].fullness,
          "happiness": friends[i].happiness,
        ])
        let restored = (res["code"] as? String) ?? code
        if let guest = res["guestName"] as? String, !guest.isEmpty {
          friends[i].partnerName = guest
          friends[i].waiting = false
          friends[i].lastActivity = nil
          saveFriends()
          onFriendsChanged?()
          attach(code: restored)
          onStatus?("bonded with \(guest)")
          return
        }
        friends[i].lastActivity = nil
        saveFriends()
        onFriendsChanged?()
        attach(code: restored)
        onStatus?("waiting · code \(restored)")
      } catch {
        onStatus?("couldn’t restore invite — try Invite friend again")
      }
      return
    }
    onStatus?("reconnecting…")
    do {
      _ = try await postJSON(path: "/api/restore", body: [
        "name": displayName,
        "deviceId": deviceId,
        "code": code,
        "partnerName": friends[i].partnerName,
        "fullness": friends[i].fullness,
        "happiness": friends[i].happiness,
      ])
      friends[i].lastActivity = nil
      saveFriends()
      onFriendsChanged?()
      attach(code: code)
      onStatus?(friends[i].online ? "🟢 \(friends[i].partnerName) online" : "⚪️ \(friends[i].partnerName)")
    } catch {
      // Attach alone can still recreate the live room from the code + Supabase.
      attach(code: code)
    }
  }

  private func applyRoom(_ json: [String: Any]) {
    guard let code = json["code"] as? String else { return }
    let online = (json["partnerOnline"] as? Bool) ?? ((json["partner"] as? String)?.isEmpty == false)
    let partner = json["partner"] as? String
    let partnerSpecies = (json["partnerSpecies"] as? String) ?? Species.dog.rawValue
    let f = Self.num(json, "fullness")
    let h = Self.num(json, "happiness")
    // Server now sends *partner* stats in room payloads (per-member). Safe to store on FriendBond
    // only — never applied to your own dog.

    if let i = friends.firstIndex(where: { $0.code == code }) {
      friends[i].online = online
      if let partner, !partner.isEmpty, partner != displayName {
        friends[i].partnerName = partner
        friends[i].waiting = false
      }
      if let sp = json["partnerSpecies"] as? String, !sp.isEmpty {
        friends[i].species = sp
      }
      if let f { friends[i].fullness = f }
      if let h { friends[i].happiness = h }
      // Don't clobber a fresh "you: pet" / "Linh: feed" line with "online now".
      if friends[i].lastActivity == nil || friends[i].lastActivity == "offline"
        || friends[i].lastActivity == "went offline" || friends[i].lastActivity == "online now"
      {
        friends[i].lastActivity = online ? "online now" : "offline"
      }
    } else {
      friends.append(FriendBond(
        code: code,
        partnerName: (partner?.isEmpty == false && partner != displayName) ? partner! : "friend",
        online: online,
        waiting: partner == nil,
        fullness: f ?? 80,
        happiness: h ?? 80,
        lastActivity: online ? "online now" : nil,
        species: partnerSpecies))
      if activeCode == nil { activeCode = code }
    }
    saveFriends()

    if code == activeCode {
      if let partner, online, partner != displayName {
        onStatus?("🟢 \(partner) online")
      } else if let name = friends.first(where: { $0.code == code })?.partnerName {
        onStatus?(online ? "🟢 \(name) online" : "⚪️ \(name) offline")
      }
    }
    onPresence?()
    onFriendsChanged?()
  }

  private func applyPresence(_ json: [String: Any]) {
    let code = (json["code"] as? String) ?? activeCode
    let online = (json["partnerOnline"] as? Bool) ?? false
    let partner = json["partner"] as? String
    guard let code else { return }
    if let i = friends.firstIndex(where: { $0.code == code }) {
      let was = friends[i].online
      friends[i].online = online
      // Presence `partner` is the other person — never overwrite with our own displayName.
      if let partner, !partner.isEmpty, partner != displayName {
        friends[i].partnerName = partner
        friends[i].waiting = false
      }
      if friends[i].lastActivity == nil || friends[i].lastActivity == "offline"
        || friends[i].lastActivity == "went offline" || friends[i].lastActivity == "online now"
      {
        friends[i].lastActivity = online ? "online now" : "went offline"
      }
      saveFriends()
      if code == activeCode {
        onStatus?(online ? "🟢 \(friends[i].partnerName) online" : "⚪️ \(friends[i].partnerName) offline")
        if was != online { onPresence?() }
      }
    }
    onFriendsChanged?()
    onPresence?()
  }

  private static func num(_ json: [String: Any], _ key: String) -> Double? {
    if let d = json[key] as? Double { return d }
    if let i = json[key] as? Int { return Double(i) }
    if let n = json[key] as? NSNumber { return n.doubleValue }
    return nil
  }
}
