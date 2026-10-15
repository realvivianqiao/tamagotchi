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

  var displayName: String {
    get {
      let n = UserDefaults.standard.string(forKey: "mochiName")?.trimmingCharacters(in: .whitespacesAndNewlines)
      return (n?.isEmpty == false) ? n! : NSFullUserName().split(separator: " ").first.map(String.init) ?? "me"
    }
    set { UserDefaults.standard.set(newValue, forKey: "mochiName") }
  }

  var mySpecies: Species {
    get { Species.parse(UserDefaults.standard.string(forKey: "mochiSpecies")) }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: "mochiSpecies") }
  }

  private(set) var friends: [FriendBond] = []
  private(set) var activeCode: String?
  private(set) var connected = false

  /// Convenience for the friend currently on your desktop.
  var partner: String? { activeFriend?.partnerName }
  var partnerOnline: Bool { activeFriend?.online ?? false }
  var isBonded: Bool { friends.contains { !$0.waiting } }

  var onSync: ((Double, Double, String?, String) -> Void)?
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

  // MARK: - Public API

  func create(fullness: Double, happiness: Double) {
    onStatus?("creating invite…")
    Task { @MainActor in
      do {
        let res = try await postJSON(path: "/api/invite", body: [
          "name": displayName, "fullness": fullness, "happiness": happiness,
        ])
        guard let c = res["code"] as? String else {
          onStatus?("invite failed")
          return
        }
        upsert(FriendBond(
          code: c, partnerName: "waiting…", online: false, waiting: true,
          fullness: fullness, happiness: happiness, lastActivity: "invite sent"))
        activeCode = c
        saveFriends()
        onStatus?("waiting · code \(c)")
        onFriendsChanged?()
        ensureSocket()
        attach(code: c)
      } catch {
        onStatus?("invite failed: \(error.localizedDescription)")
      }
    }
  }

  func join(code raw: String) {
    let token = Self.extractCode(raw)
    onStatus?("claiming \(token)…")
    Task { @MainActor in
      do {
        let res = try await postJSON(path: "/api/claim", body: ["name": displayName, "code": token])
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
          fullness: f, happiness: h, lastActivity: "just bonded"))
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
    loadFriends()
    guard !friends.isEmpty else { return }
    if activeCode == nil { activeCode = friends.first?.code }
    onFriendsChanged?()
    onPresence?()
    ensureSocket()
    for f in friends { attach(code: f.code) }
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

  // MARK: - HTTP / WS

  private func postJSON(path: String, body: [String: Any]) async throws -> [String: Any] {
    guard let url = URL(string: path, relativeTo: httpRoot)?.absoluteURL else {
      throw NSError(domain: "Mochi", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad url"])
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
      throw NSError(domain: "Mochi", code: status, userInfo: [NSLocalizedDescriptionKey: (json["error"] as? String) ?? "HTTP \(status)"])
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
      send([
        "type": "attach", "code": code, "name": displayName,
        "species": mySpecies.rawValue,
      ])
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
    case "sync":
      let code = (json["code"] as? String) ?? activeCode
      let f = Self.num(json, "fullness") ?? 0
      let h = Self.num(json, "happiness") ?? 0
      let action = json["action"] as? String
      let from = (json["from"] as? String) ?? ""
      let fromMe = !from.isEmpty && from == displayName
      if let code, let i = friends.firstIndex(where: { $0.code == code }) {
        // Only adopt stats when the *friend* reports theirs — never overwrite with our echo.
        if !fromMe {
          friends[i].fullness = f
          friends[i].happiness = h
          friends[i].waiting = false
          if let sp = json["species"] as? String, !sp.isEmpty {
            friends[i].species = sp
          }
          if friends[i].partnerName == "waiting…", !from.isEmpty {
            friends[i].partnerName = from
          }
          if let action {
            friends[i].lastActivity = "\(from.isEmpty ? "friend" : from): \(action)"
          }
          saveFriends()
        }
      }
      // Actions from a friend land on *your* dog; ignore our own echo.
      if !fromMe {
        onSync?(f, h, action, from)
      }
      onFriendsChanged?()

    case "system":
      onStatus?(json["text"] as? String ?? "ok")
    case "error":
      onStatus?(json["text"] as? String ?? "error")
    default:
      break
    }
  }

  private func applyRoom(_ json: [String: Any]) {
    guard let code = json["code"] as? String else { return }
    let online = (json["partnerOnline"] as? Bool) ?? ((json["partner"] as? String)?.isEmpty == false)
    let partner = json["partner"] as? String
    let partnerSpecies = (json["partnerSpecies"] as? String) ?? Species.dog.rawValue
    let f = Self.num(json, "fullness")
    let h = Self.num(json, "happiness")

    if let i = friends.firstIndex(where: { $0.code == code }) {
      friends[i].online = online
      if let partner, !partner.isEmpty {
        friends[i].partnerName = partner
        friends[i].waiting = false
      }
      if let sp = json["partnerSpecies"] as? String, !sp.isEmpty {
        friends[i].species = sp
      }
      if let f { friends[i].fullness = f }
      if let h { friends[i].happiness = h }
      friends[i].lastActivity = online ? "online now" : "offline"
    } else {
      friends.append(FriendBond(
        code: code,
        partnerName: partner ?? "friend",
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
      if let partner, online {
        onStatus?("🟢 \(partner) online")
      } else if let name = friends.first(where: { $0.code == code })?.partnerName {
        onStatus?(online ? "🟢 \(name) online" : "⚪️ \(name) offline")
      }
      // Room stats are the friend's pet — stored on FriendBond above, not applied to your dog.
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
      if let partner, !partner.isEmpty {
        friends[i].partnerName = partner
        friends[i].waiting = false
      }
      friends[i].lastActivity = online ? "online now" : "went offline"
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
