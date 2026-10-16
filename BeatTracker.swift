import Foundation

/// On-device beat clock tuned for dance / hip-hop kicks.
///
/// Pipeline:
/// 1. Low-band energy (~40–180 Hz) → short-window RMS
/// 2. Onset = sharp rise in that energy (kick punch)
/// 3. Inter-onset intervals → dominant period (histogram), prefer ~70–140 BPM
/// 4. Phase-locked metronome fires on the grid; strong onsets near a beat snap the phase
///
/// We do *not* fire on every onset (that would dance to snares / hats). Only the grid.
final class BeatTracker: @unchecked Sendable {
  /// Fired on `callbackQueue` with accent strength 0…1 (kick-aligned ≈ 1).
  var onBeat: ((Double) -> Void)?
  var callbackQueue = DispatchQueue.main

  private let lock = NSLock()
  private var sampleRate: Double = 48_000

  // Filters / envelope
  private var lp: Double = 0
  private var hp: Double = 0 // high-pass of lp → band focus
  private var env: Double = 0
  private var prevEnv: Double = 0
  private var noiseFloor: Double = 0.002

  // Tempo / phase
  private var period: Double = 0.5 // seconds per beat (120 BPM default)
  private var nextBeat: Double = -1
  private var lastOnset: Double = -1
  private var lastFire: Double = -1
  private var onsetTimes: [Double] = []
  private var iois: [Double] = []

  private var samplesSeen: Int = 0
  private var startedAt: CFAbsoluteTime = 0

  // Accumulate energy in ~11 ms frames for stabler onset detection
  private var frameAcc: Double = 0
  private var frameN: Int = 0
  private var frameSize: Int = 512

  func reset(sampleRate: Double) {
    lock.lock()
    defer { lock.unlock() }
    self.sampleRate = max(8_000, sampleRate)
    lp = 0
    hp = 0
    env = 0
    prevEnv = 0
    noiseFloor = 0.002
    period = 0.5
    nextBeat = -1
    lastOnset = -1
    lastFire = -1
    onsetTimes.removeAll(keepingCapacity: true)
    iois.removeAll(keepingCapacity: true)
    samplesSeen = 0
    startedAt = CFAbsoluteTimeGetCurrent()
    frameAcc = 0
    frameN = 0
    frameSize = max(128, Int(sampleRate * 0.011)) // ~11 ms
  }

  func process(mono: UnsafePointer<Float>, count: Int) {
    guard count > 0 else { return }
    lock.lock()
    let sr = sampleRate
    // Band-ish: lowpass ~180 Hz, then mild highpass ~40 Hz via leaky diff.
    let aLP = exp(-2.0 * .pi * 180.0 / sr)
    let aHP = exp(-2.0 * .pi * 40.0 / sr)
    let aEnv = exp(-2.0 * .pi * 12.0 / sr)

    var localLP = lp
    var localHP = hp
    var localEnv = env
    var localPrev = prevEnv
    var localFloor = noiseFloor
    var localAcc = frameAcc
    var localN = frameN
    var onsetStrength: Double = 0
    var onsetTime: Double = -1

    for i in 0..<count {
      let x = Double(mono[i])
      localLP = aLP * localLP + (1 - aLP) * x
      localHP = aHP * localHP + (1 - aHP) * localLP
      let band = localLP - localHP
      let e = abs(band)
      localEnv = aEnv * localEnv + (1 - aEnv) * e
      localAcc += e * e
      localN += 1

      if localN >= frameSize {
        let rms = sqrt(localAcc / Double(localN))
        localFloor = localFloor * 0.995 + rms * 0.005
        let flux = rms - localPrev
        localPrev = rms
        // Kick: rising flux well above the floor.
        let thresh = max(0.003, localFloor * 2.8)
        if flux > thresh, rms > localFloor * 1.6 {
          let t = startedAt + Double(samplesSeen + i) / sr
          // Debounce onsets closer than ~90 ms (ignore hats).
          if lastOnset < 0 || t - lastOnset > 0.09 {
            onsetStrength = min(1.0, flux / max(thresh, 1e-6))
            onsetTime = t
            lastOnset = t
          }
        }
        localAcc = 0
        localN = 0
      }
    }

    lp = localLP
    hp = localHP
    env = localEnv
    prevEnv = localPrev
    noiseFloor = localFloor
    frameAcc = localAcc
    frameN = localN
    samplesSeen += count
    let now = startedAt + Double(samplesSeen) / sr

    if onsetTime > 0 {
      noteOnset(at: onsetTime, strength: onsetStrength)
    }

    // Metronome: fire when we cross the next beat on the locked grid.
    var shouldFire = false
    var strength: Double = 0.55
    if nextBeat > 0, now + 0.001 >= nextBeat {
      shouldFire = true
      strength = 0.55
      // Advance grid (catch up if we lagged a buffer).
      while nextBeat > 0, now + 0.001 >= nextBeat {
        nextBeat += period
      }
    }

    // Strong onset near an expected beat → snap phase + accent.
    if onsetTime > 0, nextBeat > 0 {
      let expected = nextBeat - period
      let err = onsetTime - expected
      if abs(err) < period * 0.28 {
        nextBeat = onsetTime + period
        shouldFire = true
        strength = min(1.0, 0.65 + onsetStrength * 0.35)
      }
    } else if onsetTime > 0, nextBeat < 0, period > 0 {
      // First lock: start the grid from this kick.
      nextBeat = onsetTime + period
      shouldFire = true
      strength = 1.0
    }

    if shouldFire {
      // Don't double-fire (min ~half of period, at least 180 ms).
      let minGap = max(0.18, period * 0.45)
      if lastFire < 0 || now - lastFire >= minGap {
        lastFire = now
        lock.unlock()
        let cb = onBeat
        let s = strength
        callbackQueue.async { cb?(s) }
        return
      }
    }
    lock.unlock()
  }

  private func noteOnset(at t: Double, strength: Double) {
    _ = strength
    if let prev = onsetTimes.last {
      let ioi = t - prev
      // Keep plausible beat/half-beat IOIs (~50–180 BPM fundamental).
      if ioi >= 0.20, ioi <= 1.25 {
        iois.append(ioi)
        if iois.count > 24 { iois.removeFirst(iois.count - 24) }
        if let p = estimatePeriod(from: iois) {
          // Smooth tempo changes — don't jump wildly.
          period = period * 0.7 + p * 0.3
        }
      }
    }
    onsetTimes.append(t)
    if onsetTimes.count > 32 { onsetTimes.removeFirst(onsetTimes.count - 32) }
  }

  /// Histogram-ish period pick in dance range; doubles half-beats.
  private func estimatePeriod(from iois: [Double]) -> Double? {
    guard iois.count >= 4 else { return nil }
    // Candidate bins from 0.34s (176 BPM) … 0.86s (70 BPM).
    var bestScore = 0.0
    var bestPeriod = period
    var p = 0.34
    while p <= 0.86 {
      var score = 0.0
      for ioi in iois {
        // Reward IOIs near 1× or 2× the candidate (half-notes / downbeats).
        let e1 = abs(ioi - p) / p
        let e2 = abs(ioi - p * 0.5) / (p * 0.5)
        let e3 = abs(ioi - p * 2.0) / (p * 2.0)
        let e = min(e1, e2, e3)
        if e < 0.12 {
          score += 1.0 - e / 0.12
        }
      }
      // Slight preference for ~90–115 BPM (common dance).
      let bpm = 60.0 / p
      if bpm >= 88, bpm <= 118 { score *= 1.15 }
      if score > bestScore {
        bestScore = score
        bestPeriod = p
      }
      p += 0.01
    }
    guard bestScore >= 2.5 else { return nil }
    return bestPeriod
  }

  var bpm: Double? {
    lock.lock()
    defer { lock.unlock() }
    guard iois.count >= 4, period > 0.05 else { return nil }
    return 60.0 / period
  }
}
