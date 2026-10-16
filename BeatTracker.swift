import Foundation

/// Lightweight on-device beat clock: bass envelope → onsets → tempo → predicted beats.
/// Safe to feed from a Core Audio I/O thread (lock-free-ish via serial queue handoff upstream).
final class BeatTracker: @unchecked Sendable {
  /// Fired on `callbackQueue` when a beat should land (detected or predicted).
  var onBeat: (() -> Void)?
  var callbackQueue = DispatchQueue.main

  private let lock = NSLock()
  private var sampleRate: Double = 48_000
  private var lp: Double = 0
  private var env: Double = 0
  private var noiseFloor: Double = 0.002
  private var lastOnsetTime: Double = -1
  private var lastBeatFire: Double = -1
  private var interval: Double = 0.5 // 120 BPM default guess
  private var intervals: [Double] = []
  private var nextPredicted: Double = -1
  private var samplesSeen: Int = 0
  private var startedAt: CFAbsoluteTime = 0

  func reset(sampleRate: Double) {
    lock.lock()
    defer { lock.unlock() }
    self.sampleRate = max(8_000, sampleRate)
    lp = 0
    env = 0
    noiseFloor = 0.002
    lastOnsetTime = -1
    lastBeatFire = -1
    interval = 0.5
    intervals.removeAll(keepingCapacity: true)
    nextPredicted = -1
    samplesSeen = 0
    startedAt = CFAbsoluteTimeGetCurrent()
  }

  /// Mono interleaved float samples.
  func process(mono: UnsafePointer<Float>, count: Int) {
    guard count > 0 else { return }
    lock.lock()
    let sr = sampleRate
    let alphaLP = exp(-2.0 * .pi * 150.0 / sr) // ~150 Hz bass
    let alphaEnv = exp(-2.0 * .pi * 8.0 / sr)
    var localLP = lp
    var localEnv = env
    var localFloor = noiseFloor
    var onsetThisBlock = false
    var blockPeak: Double = 0

    for i in 0..<count {
      let x = Double(mono[i])
      localLP = alphaLP * localLP + (1 - alphaLP) * x
      let e = abs(localLP)
      localEnv = alphaEnv * localEnv + (1 - alphaEnv) * e
      localFloor = min(localFloor * 1.0002 + 1e-7, max(localFloor * 0.9995, e * 0.3))
      blockPeak = max(blockPeak, e)

      // Rising edge through adaptive threshold → onset candidate.
      let thresh = max(0.004, localFloor * 3.2)
      if e > thresh, e > localEnv * 1.25 {
        onsetThisBlock = true
      }
    }

    lp = localLP
    env = localEnv
    noiseFloor = localFloor
    samplesSeen += count
    let now = startedAt + Double(samplesSeen) / sr
    var fire = false

    if onsetThisBlock, blockPeak > 0.003 {
      if lastOnsetTime < 0 || now - lastOnsetTime > 0.22 {
        if lastOnsetTime > 0 {
          let ioi = now - lastOnsetTime
          if ioi >= 0.28, ioi <= 1.2 { // ~50–214 BPM
            intervals.append(ioi)
            if intervals.count > 8 { intervals.removeFirst() }
            let sorted = intervals.sorted()
            interval = sorted[sorted.count / 2]
          }
        }
        lastOnsetTime = now
        nextPredicted = now + interval
        fire = true
      }
    }

    // Predicted beat clock fills gaps when onsets miss.
    if nextPredicted > 0, now + 0.002 >= nextPredicted {
      if !fire { fire = true }
      nextPredicted += interval
      // Don't let prediction race ahead if audio went quiet.
      if now - lastOnsetTime > 3.0 {
        nextPredicted = -1
        fire = false
      }
    }

    if fire {
      if lastBeatFire < 0 || now - lastBeatFire >= 0.24 {
        lastBeatFire = now
        lock.unlock()
        let cb = onBeat
        callbackQueue.async { cb?() }
        return
      }
    }
    lock.unlock()
  }

  /// Estimated BPM if we have enough onsets, else nil.
  var bpm: Double? {
    lock.lock()
    defer { lock.unlock() }
    guard intervals.count >= 3, interval > 0.05 else { return nil }
    return 60.0 / interval
  }
}
