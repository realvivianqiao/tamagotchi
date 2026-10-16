import AppKit
import Foundation

/// Opt-in “Dance to Spotify”: AppleScript play/track + process tap + local beat clock.
@MainActor final class SpotifyDance {
  static let shared = SpotifyDance()
  static let defaultsKey = "mochiDanceToSpotify"

  struct Track: Equatable {
    var name: String
    var artist: String
    var display: String {
      let a = artist.trimmingCharacters(in: .whitespacesAndNewlines)
      if a.isEmpty { return name }
      return "\(name) — \(a)"
    }
  }

  enum PlayState: Equatable {
    case off // Spotify not running / unknown
    case paused
    case playing(Track)
  }

  private(set) var enabled: Bool {
    didSet { UserDefaults.standard.set(enabled, forKey: Self.defaultsKey) }
  }

  private(set) var playState: PlayState = .off
  private(set) var lastError: String?

  var onBeat: (() -> Void)?
  var onTrackChange: ((Track) -> Void)?
  var onPlayingChange: ((Bool) -> Void)?

  private var pollTimer: Timer?
  private var retapTimer: Timer?
  private var lastAnnouncedTrack: String?
  private var wasPlaying = false

  private var tap: AnyObject? // SpotifyTap when available
  private let tracker = BeatTracker()

  private init() {
    enabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
    tracker.onBeat = { [weak self] in
      Task { @MainActor in self?.onBeat?() }
    }
  }

  var isAvailable: Bool {
    if #available(macOS 14.2, *) { return true }
    return false
  }

  func setEnabled(_ on: Bool) {
    guard on != enabled else { return }
    enabled = on
    if on {
      start()
    } else {
      stop()
    }
  }

  func start() {
    guard enabled else { return }
    guard isAvailable else {
      lastError = "Dance to Spotify needs macOS 14.2 or later."
      return
    }
    lastError = nil
    tracker.reset(sampleRate: 48_000)
    pollPlayback()
    pollTimer?.invalidate()
    pollTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.pollPlayback() }
    }
    if let t = pollTimer { RunLoop.main.add(t, forMode: .common) }
  }

  func stop() {
    pollTimer?.invalidate()
    pollTimer = nil
    retapTimer?.invalidate()
    retapTimer = nil
    tearDownTap()
    if wasPlaying {
      wasPlaying = false
      onPlayingChange?(false)
    }
    playState = .off
    lastAnnouncedTrack = nil
  }

  // MARK: - Playback poll (AppleScript — never launches Spotify)

  private func pollPlayback() {
    guard enabled else { return }
    let state = Self.querySpotifyState()
    let prev = playState
    playState = state

    let playing: Bool
    if case .playing = state { playing = true } else { playing = false }

    if playing != wasPlaying {
      wasPlaying = playing
      onPlayingChange?(playing)
      if playing {
        ensureTap()
      } else {
        // Keep tap briefly so pause→play is snappy; tear down after idle.
        scheduleIdleTearDown()
      }
    }

    if case .playing(let track) = state {
      ensureTap()
      if track.display != lastAnnouncedTrack {
        lastAnnouncedTrack = track.display
        if case .playing = prev { /* mid-session skip */ }
        onTrackChange?(track)
      }
    }
  }

  /// Returns play state without launching Spotify.
  static func querySpotifyState() -> PlayState {
    // Never ask AppleScript if the app isn't already up — that would launch it.
    let running = NSWorkspace.shared.runningApplications.contains {
      ($0.bundleIdentifier ?? "").hasPrefix("com.spotify.client")
    }
    guard running else { return .off }

    let source = """
    tell application "System Events"
      if not (exists process "Spotify") then return "off"
    end tell
    tell application "Spotify"
      set st to player state as text
      if st is "playing" then
        try
          set t to name of current track
          set a to artist of current track
          return "playing|" & t & "|" & a
        on error
          return "playing||"
        end try
      else if st is "paused" then
        return "paused"
      else
        return "off"
      end if
    end tell
    """
    var error: NSDictionary?
    guard let script = NSAppleScript(source: source) else { return .off }
    let result = script.executeAndReturnError(&error)
    guard error == nil, let raw = result.stringValue else { return .off }
    if raw == "off" { return .off }
    if raw == "paused" { return .paused }
    if raw.hasPrefix("playing|") {
      let parts = raw.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
      let name = parts.count > 1 ? String(parts[1]) : "Unknown"
      let artist = parts.count > 2 ? String(parts[2]) : ""
      let title = name.isEmpty ? "Unknown" : name
      return .playing(Track(name: title, artist: artist))
    }
    return .off
  }

  // MARK: - Tap lifecycle

  private func ensureTap() {
    if #available(macOS 14.2, *) {
      if let existing = tap as? SpotifyTap, existing.isRunning { return }
      do {
        let t = SpotifyTap()
        t.onSamples = { [weak self] ptr, count in
          self?.tracker.process(mono: ptr, count: count)
        }
        try t.start()
        tracker.reset(sampleRate: t.sampleRate)
        tap = t
        lastError = nil
        retapTimer?.invalidate()
        retapTimer = nil
      } catch {
        lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        tearDownTap()
        // Retry — Spotify helpers can appear a moment after play.
        retapTimer?.invalidate()
        retapTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
          Task { @MainActor in
            guard let self, self.enabled, self.wasPlaying else { return }
            self.ensureTap()
          }
        }
      }
    }
  }

  private func scheduleIdleTearDown() {
    retapTimer?.invalidate()
    retapTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
      Task { @MainActor in
        guard let self, !self.wasPlaying else { return }
        self.tearDownTap()
      }
    }
  }

  private func tearDownTap() {
    if #available(macOS 14.2, *) {
      (tap as? SpotifyTap)?.stop()
    }
    tap = nil
  }
}
