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
    case off
    case paused
    case playing(Track)
  }

  private(set) var enabled: Bool {
    didSet { UserDefaults.standard.set(enabled, forKey: Self.defaultsKey) }
  }

  private(set) var playState: PlayState = .off
  private(set) var lastError: String?
  /// True when we should dance: Spotify reports playing, or we hear audio on the tap.
  private(set) var isHearingMusic = false

  var onBeat: (() -> Void)?
  var onTrackChange: ((Track) -> Void)?
  var onPlayingChange: ((Bool) -> Void)?
  var onError: ((String) -> Void)?

  private var pollTimer: Timer?
  private var retapTimer: Timer?
  private var lastAnnouncedTrack: String?
  private var wasHearing = false
  private var lastErrorShown: String?

  private var tap: AnyObject?
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
      onError?(lastError!)
      return
    }
    lastError = nil
    lastErrorShown = nil
    tracker.reset(sampleRate: 48_000)
    // Start listening as soon as Spotify is up — don't wait on AppleScript.
    ensureTapIfSpotifyUp()
    pollPlayback()
    pollTimer?.invalidate()
    pollTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
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
    if wasHearing {
      wasHearing = false
      isHearingMusic = false
      onPlayingChange?(false)
    }
    playState = .off
    lastAnnouncedTrack = nil
  }

  // MARK: - Poll

  private func pollPlayback() {
    guard enabled else { return }
    let state = Self.querySpotifyState()
    playState = state

    let scriptPlaying: Bool
    if case .playing = state { scriptPlaying = true } else { scriptPlaying = false }

    // Keep / start the tap whenever Spotify is running (headphones or speakers).
    if Self.isSpotifyAppRunning() {
      ensureTapIfSpotifyUp()
    } else {
      tearDownTap()
    }

    let hearingAudio = currentTapRMS() > 0.004
    let hearing = (scriptPlaying || hearingAudio) && Self.isSpotifyAppRunning()
    isHearingMusic = hearing

    if hearing != wasHearing {
      wasHearing = hearing
      onPlayingChange?(hearing)
    }

    if case .playing(let track) = state {
      if track.display != lastAnnouncedTrack {
        lastAnnouncedTrack = track.display
        onTrackChange?(track)
      }
    }

    // Retap if buffers go quiet while Spotify claims it's playing (BT device switch, etc.).
    if scriptPlaying, let age = tapBufferAge(), age > 2.5 {
      tearDownTap()
      ensureTapIfSpotifyUp()
    }

    if let err = lastError, err != lastErrorShown {
      lastErrorShown = err
      onError?(err)
    }
  }

  /// No System Events — that needs a separate Automation grant and often fails silently.
  static func querySpotifyState() -> PlayState {
    guard isSpotifyAppRunning() else { return .off }

    let source = """
    tell application "Spotify"
      try
        set st to player state as text
        if st is "playing" then
          try
            set t to name of current track
            set a to artist of current track
            return "playing|" & t & "|" & a
          on error
            return "playing|Unknown|"
          end try
        else if st is "paused" then
          return "paused"
        else
          return "off"
        end if
      on error
        return "off"
      end try
    end tell
    """
    var error: NSDictionary?
    guard let script = NSAppleScript(source: source) else { return .off }
    let result = script.executeAndReturnError(&error)
    if error != nil { return .off }
    guard let raw = result.stringValue else { return .off }
    if raw == "off" { return .off }
    if raw == "paused" { return .paused }
    if raw.hasPrefix("playing|") {
      let parts = raw.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
      let name = parts.count > 1 ? String(parts[1]) : "Unknown"
      let artist = parts.count > 2 ? String(parts[2]) : ""
      return .playing(Track(name: name.isEmpty ? "Unknown" : name, artist: artist))
    }
    return .off
  }

  static func isSpotifyAppRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains {
      ($0.bundleIdentifier ?? "").hasPrefix("com.spotify.client")
    }
  }

  // MARK: - Tap

  private func ensureTapIfSpotifyUp() {
    guard Self.isSpotifyAppRunning() else { return }
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
        retapTimer?.invalidate()
        retapTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
          Task { @MainActor in
            guard let self, self.enabled else { return }
            self.ensureTapIfSpotifyUp()
          }
        }
      }
    }
  }

  private func currentTapRMS() -> Double {
    if #available(macOS 14.2, *) {
      return (tap as? SpotifyTap)?.currentRMS ?? 0
    }
    return 0
  }

  private func tapBufferAge() -> CFAbsoluteTime? {
    if #available(macOS 14.2, *) {
      guard let t = tap as? SpotifyTap, t.isRunning, t.lastBufferAt > 0 else { return nil }
      return CFAbsoluteTimeGetCurrent() - t.lastBufferAt
    }
    return nil
  }

  private func tearDownTap() {
    if #available(macOS 14.2, *) {
      (tap as? SpotifyTap)?.stop()
    }
    tap = nil
  }
}
