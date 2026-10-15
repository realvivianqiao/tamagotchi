import AppKit
import Foundation

/// Tiny WebSocket client for Mochi bond rooms (create / join / sync stats).
@MainActor final class Online: NSObject, URLSessionWebSocketDelegate {
  static let shared = Online()

  /// Live public server by default. Override with UserDefaults `mochiServer` if needed.
  var serverURL: URL {
    let raw = UserDefaults.standard.string(forKey: "mochiServer")?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let raw, !raw.isEmpty, let url = URL(string: raw) { return url }
    return URL(string: "wss://tamagotchi-udtz.onrender.com")!
  }

  var displayName: String {
    get {
      let n = UserDefaults.standard.string(forKey: "mochiName")?.trimmingCharacters(in: .whitespacesAndNewlines)
      return (n?.isEmpty == false) ? n! : NSFullUserName().split(separator: " ").first.map(String.init) ?? "me"
    }
    set { UserDefaults.standard.set(newValue, forKey: "mochiName") }
  }

  private(set) var code: String?
  private(set) var partner: String?
  private(set) var connected = false

  /// Called on the main actor when remote (or echoed) sync arrives.
  var onSync: ((Double, Double, String?, String) -> Void)?
  var onStatus: ((String) -> Void)?

  private var session: URLSession!
  private var task: URLSessionWebSocketTask?
  private var receiveLoop = false

  override init() {
    super.init()
    session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
  }

  var isBonded: Bool { connected && code != nil }

  func create(fullness: Double, happiness: Double) {
    connectThen {
      self.send([
        "type": "create",
        "name": self.displayName,
        "fullness": fullness,
        "happiness": happiness,
      ])
    }
  }

  func join(code: String) {
    connectThen {
      self.send([
        "type": "join",
        "code": code.uppercased(),
        "name": self.displayName,
      ])
    }
  }

  func sync(fullness: Double, happiness: Double, action: String? = nil) {
    guard connected else { return }
    var msg: [String: Any] = [
      "type": "sync",
      "fullness": fullness,
      "happiness": happiness,
      "updatedAt": Int(Date().timeIntervalSince1970 * 1000),
    ]
    if let action { msg["action"] = action }
    send(msg)
  }

  func disconnect() {
    task?.cancel(with: .goingAway, reason: nil)
    task = nil
    connected = false
    code = nil
    partner = nil
    receiveLoop = false
    onStatus?("offline")
  }

  // MARK: - Internals

  private func connectThen(_ body: @escaping @MainActor () -> Void) {
    disconnect()
    let t = session.webSocketTask(with: serverURL)
    task = t
    receiveLoop = true
    t.resume()
    connected = true
    onStatus?("connecting…")
    listen()
    // Give the socket a beat, then send.
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 150_000_000)
      body()
    }
  }

  private func send(_ msg: [String: Any]) {
    guard let task, let data = try? JSONSerialization.data(withJSONObject: msg),
          let text = String(data: data, encoding: .utf8)
    else { return }
    task.send(.string(text)) { error in
      if let error {
        Task { @MainActor in self.onStatus?("send failed: \(error.localizedDescription)") }
      }
    }
  }

  private func listen() {
    guard let task, receiveLoop else { return }
    task.receive { [weak self] result in
      Task { @MainActor in
        guard let self else { return }
        switch result {
        case .failure(let error):
          self.connected = false
          self.onStatus?("disconnected: \(error.localizedDescription)")
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
      code = json["code"] as? String
      partner = json["partner"] as? String
      connected = true
      if let f = Self.num(json, "fullness"), let h = Self.num(json, "happiness") {
        onSync?(f, h, nil, partner ?? displayName)
      }
      if let partner {
        onStatus?("bonded with \(partner) · \(code ?? "")")
      } else {
        onStatus?("room \(code ?? "") — waiting for partner")
      }

    case "sync":
      let f = Self.num(json, "fullness") ?? 0
      let h = Self.num(json, "happiness") ?? 0
      let action = json["action"] as? String
      let from = (json["from"] as? String) ?? ""
      // Ignore our own echo for action animations; still apply stats.
      onSync?(f, h, from == displayName ? nil : action, from)

    case "system":
      onStatus?(json["text"] as? String ?? "ok")

    case "error":
      onStatus?(json["text"] as? String ?? "error")
      connected = false

    default:
      break
    }
  }

  private static func num(_ json: [String: Any], _ key: String) -> Double? {
    if let d = json[key] as? Double { return d }
    if let i = json[key] as? Int { return Double(i) }
    if let n = json[key] as? NSNumber { return n.doubleValue }
    return nil
  }
}
