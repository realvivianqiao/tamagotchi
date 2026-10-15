import AppKit

struct MarketAlert: Equatable {
  enum Level: Int, Comparable {
    case info, warn, urgent
    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
  }

  let id: String // alerts with an id already shown are never repeated
  let level: Level
  let text: String
  let stealthText: String // shown in stealth mode: no numbers, safe over-the-shoulder
}

struct MarketSnapshot {
  var pnlBps: Double?
  var pnlUSD: Double?
  var alerts: [MarketAlert] = []
}

@MainActor protocol MarketFeed: AnyObject {
  var name: String { get }
  var interval: TimeInterval { get }
  func fetch() async throws -> MarketSnapshot
}

/// Polls a feed on a fixed cadence, pauses while the screen is asleep or locked, and backs off on errors.
@MainActor final class MarketWatcher {
  var feed: MarketFeed {
    didSet {
      seen.removeAll()
      latest = nil
      restart()
    }
  }
  var enabled = true { didSet { restart() } }
  private(set) var latest: MarketSnapshot?
  private(set) var lastError: String?

  private let onUpdate: @MainActor (MarketSnapshot, [MarketAlert]) -> Void
  private var seen = Set<String>()
  private var task: Task<Void, Never>?
  private var screenAway = false { didSet { restart() } }

  init(feed: MarketFeed, onUpdate: @escaping @MainActor (MarketSnapshot, [MarketAlert]) -> Void) {
    self.feed = feed
    self.onUpdate = onUpdate
    observeScreen()
    restart()
  }

  func restart() {
    task?.cancel()
    guard enabled, !screenAway else { return }
    task = Task { [weak self] in
      while let self, !Task.isCancelled {
        await self.poll()
        let wait = self.feed.interval * (self.lastError == nil ? 1 : 5)
        try? await Task.sleep(for: .seconds(wait))
      }
    }
  }

  private func poll() async {
    do {
      let snapshot = try await feed.fetch()
      lastError = nil
      latest = snapshot
      onUpdate(snapshot, snapshot.alerts.filter { seen.insert($0.id).inserted })
    } catch {
      lastError = error.localizedDescription
    }
  }

  private func observeScreen() {
    let ws = NSWorkspace.shared.notificationCenter
    ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.screenAway = true }
    }
    ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.screenAway = false }
    }
    let dc = DistributedNotificationCenter.default()
    dc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.screenAway = true }
    }
    dc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.screenAway = false }
    }
  }
}

// MARK: - Demo feed

/// Fake book and headlines so the alert flow can be tried without touching prod.
@MainActor final class DemoFeed: MarketFeed {
  let name = "Demo (fake data)"
  let interval: TimeInterval = 15
  private var bps = 0.0
  private var n = 0
  private let names = ["NVDA", "TSM", "AVGO", "MU", "SK Hynix", "AMD", "ASML", "META", "Kioxia"]

  func fetch() async throws -> MarketSnapshot {
    n += 1
    let move = Double.random(in: -9...9)
    bps += move
    var alerts: [MarketAlert] = []
    if abs(move) > 7 {
      alerts.append(
        .init(
          id: "pnl-\(n)", level: .warn,
          text: "\(move > 0 ? "📈" : "📉") Book \(signed(move))bp in 15s, now \(signed(bps))bp",
          stealthText: move > 0 ? "📈 book moving up fast" : "📉 book moving down fast"))
    }
    if Int.random(in: 0..<3) == 0 {
      let name = names.randomElement()!, pct = Double.random(in: -6...6)
      alerts.append(
        .init(
          id: "mover-\(n)", level: abs(pct) > 4 ? .urgent : .info,
          text: "\(pct > 0 ? "🟢" : "🔴") \(name) \(signed(pct))% in 10 min",
          stealthText: "\(pct > 0 ? "🟢" : "🔴") big move in a book name"))
    }
    if n % 8 == 0 {
      alerts.append(
        .init(
          id: "macro-\(n)", level: .urgent, text: "🚨 CPI hot: core +0.4% m/m vs +0.3% est, NQ −1.1%",
          stealthText: "🚨 macro release just hit"))
    }
    return MarketSnapshot(pnlBps: bps, pnlUSD: bps * 300_000, alerts: alerts)
  }
}

func signed(_ v: Double, digits: Int = 1) -> String {
  (v >= 0 ? "+" : "−") + String(format: "%.\(digits)f", abs(v))
}
