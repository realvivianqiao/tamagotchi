import AppKit
import AudioToolbox
import CoreAudio
import Foundation

/// Captures Spotify desktop audio via Core Audio process taps (macOS 14.2+).
/// Includes every audio process whose bundle ID starts with `com.spotify.client`
/// (main app + Chromium helpers). Works with Bluetooth headphones — we tap Spotify,
/// not the speaker.
@available(macOS 14.2, *)
final class SpotifyTap {
  enum TapError: LocalizedError {
    case unsupported
    case noSpotify
    case createTap(OSStatus)
    case createAggregate(OSStatus)
    case start(OSStatus)

    var errorDescription: String? {
      switch self {
      case .unsupported: return "Dance to Spotify needs macOS 14.2 or later."
      case .noSpotify: return "Spotify isn’t running."
      case .createTap(let s):
        return "Couldn’t tap Spotify audio (\(s)). Allow CoPet under System Settings → Privacy & Security → Screen & System Audio Recording."
      case .createAggregate(let s): return "Couldn’t open Spotify audio device (\(s))."
      case .start(let s): return "Couldn’t start Spotify audio capture (\(s))."
      }
    }
  }

  private var tapID: AudioObjectID = kAudioObjectUnknown
  private var aggregateID: AudioObjectID = kAudioObjectUnknown
  private var ioProcID: AudioDeviceIOProcID?
  private let ioQueue = DispatchQueue(label: "copet.spotify.tap", qos: .userInteractive)
  private(set) var sampleRate: Double = 48_000
  private(set) var isRunning = false

  /// Last time we received any audio frames (wall clock).
  private(set) var lastBufferAt: CFAbsoluteTime = 0
  /// Recent RMS energy (0…~1), updated on the IO queue.
  private var recentRMS: Double = 0
  private let rmsLock = NSLock()

  /// Called on `ioQueue` with mono float samples.
  var onSamples: ((UnsafePointer<Float>, Int) -> Void)?

  var currentRMS: Double {
    rmsLock.lock()
    defer { rmsLock.unlock() }
    return recentRMS
  }

  func start() throws {
    stop()
    let processes = Self.spotifyProcessObjectIDs()
    guard !processes.isEmpty else { throw TapError.noSpotify }

    let desc = CATapDescription(stereoMixdownOfProcesses: processes)
    desc.name = "CoPet Spotify"
    desc.uuid = UUID()
    desc.muteBehavior = .unmuted
    desc.isPrivate = true

    var newTap = AudioObjectID(kAudioObjectUnknown)
    let tapStatus = AudioHardwareCreateProcessTap(desc, &newTap)
    guard tapStatus == noErr, newTap != kAudioObjectUnknown else {
      throw TapError.createTap(tapStatus)
    }
    tapID = newTap

    let asbd = try Self.readTapFormat(tapID)
    sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000

    // Prefer aggregate tied to the current default output (works with BT headphones /
    // AirPods A2DP). Fall back to tap-only if that fails.
    do {
      try createAggregate(tapUUID: desc.uuid.uuidString, withOutputDevice: true)
    } catch {
      try createAggregate(tapUUID: desc.uuid.uuidString, withOutputDevice: false)
    }

    let channels = max(1, Int(asbd.mChannelsPerFrame))
    var procID: AudioDeviceIOProcID?
    let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
      [weak self] _, inInput, _, _, _ in
      guard let self else { return }
      self.handleIO(abl: inInput.pointee, channels: channels, asbd: asbd)
    }
    guard status == noErr, let procID else {
      stop()
      throw TapError.start(status)
    }
    ioProcID = procID

    let startStatus = AudioDeviceStart(aggregateID, procID)
    guard startStatus == noErr else {
      stop()
      throw TapError.start(startStatus)
    }
    isRunning = true
    lastBufferAt = CFAbsoluteTimeGetCurrent()
  }

  func stop() {
    isRunning = false
    if aggregateID != kAudioObjectUnknown {
      if let ioProcID {
        AudioDeviceStop(aggregateID, ioProcID)
        AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
      }
      AudioHardwareDestroyAggregateDevice(aggregateID)
      aggregateID = kAudioObjectUnknown
    }
    ioProcID = nil
    if tapID != kAudioObjectUnknown {
      AudioHardwareDestroyProcessTap(tapID)
      tapID = kAudioObjectUnknown
    }
    rmsLock.lock()
    recentRMS = 0
    rmsLock.unlock()
  }

  deinit { stop() }

  // MARK: - Aggregate

  private func createAggregate(tapUUID: String, withOutputDevice: Bool) throws {
    let aggregateUID = "com.vivianqiao.copet.spotify.\(UUID().uuidString)"
    var description: [String: Any] = [
      kAudioAggregateDeviceNameKey: "CoPet Spotify Tap",
      kAudioAggregateDeviceUIDKey: aggregateUID,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapUIDKey: tapUUID,
        kAudioSubTapDriftCompensationKey: true,
      ]],
    ]

    if withOutputDevice,
       let outputUID = try? Self.readDefaultOutputUID()
    {
      // Clock the aggregate off the device actually playing (speakers or BT headphones).
      description[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
      description[kAudioAggregateDeviceSubDeviceListKey] = [[
        kAudioSubDeviceUIDKey: outputUID,
      ]]
    }

    var agg = AudioObjectID(kAudioObjectUnknown)
    let aggStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg)
    guard aggStatus == noErr, agg != kAudioObjectUnknown else {
      if !withOutputDevice {
        AudioHardwareDestroyProcessTap(tapID)
        tapID = kAudioObjectUnknown
      }
      throw TapError.createAggregate(aggStatus)
    }
    aggregateID = agg
  }

  // MARK: - IO

  private var monoScratch = [Float](repeating: 0, count: 4096)

  private func handleIO(abl: AudioBufferList, channels: Int, asbd: AudioStreamBasicDescription) {
    let buf = abl.mBuffers
    guard buf.mDataByteSize > 0, let raw = buf.mData else { return }
    let frameBytes = Int(asbd.mBytesPerFrame)
    guard frameBytes > 0 else { return }
    let frames = Int(buf.mDataByteSize) / frameBytes
    guard frames > 0 else { return }

    if monoScratch.count < frames {
      monoScratch = [Float](repeating: 0, count: frames)
    }

    let interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
    var sumSq: Double = 0
    if interleaved, channels >= 1 {
      raw.withMemoryRebound(to: Float.self, capacity: frames * channels) { ptr in
        for i in 0..<frames {
          let s: Float
          if channels == 1 {
            s = ptr[i]
          } else {
            s = 0.5 * (ptr[i * channels] + ptr[i * channels + 1])
          }
          monoScratch[i] = s
          sumSq += Double(s) * Double(s)
        }
      }
    } else {
      raw.withMemoryRebound(to: Float.self, capacity: frames) { ptr in
        for i in 0..<frames {
          let s = ptr[i]
          monoScratch[i] = s
          sumSq += Double(s) * Double(s)
        }
      }
    }

    let rms = sqrt(sumSq / Double(frames))
    rmsLock.lock()
    recentRMS = recentRMS * 0.85 + rms * 0.15
    rmsLock.unlock()
    lastBufferAt = CFAbsoluteTimeGetCurrent()

    monoScratch.withUnsafeBufferPointer { bp in
      guard let base = bp.baseAddress else { return }
      onSamples?(base, frames)
    }
  }

  // MARK: - Process discovery

  static func spotifyProcessObjectIDs() -> [AudioObjectID] {
    let list: [AudioObjectID]
    do {
      list = try readProcessObjectList()
    } catch {
      return fallbackFromRunningApps()
    }

    var ids: [AudioObjectID] = []
    for obj in list {
      guard let bid = readBundleID(obj), bid.hasPrefix("com.spotify.client") else { continue }
      ids.append(obj)
    }
    if ids.isEmpty { return fallbackFromRunningApps() }
    return ids
  }

  static func isSpotifyRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains {
      ($0.bundleIdentifier ?? "").hasPrefix("com.spotify.client")
    }
  }

  private static func fallbackFromRunningApps() -> [AudioObjectID] {
    var ids: [AudioObjectID] = []
    for app in NSWorkspace.shared.runningApplications {
      guard let bid = app.bundleIdentifier, bid.hasPrefix("com.spotify.client") else { continue }
      if let obj = try? translatePID(app.processIdentifier) {
        ids.append(obj)
      }
    }
    return ids
  }

  private static func readDefaultOutputUID() throws -> String {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var err = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
    guard err == noErr, device != kAudioObjectUnknown else {
      throw TapError.createAggregate(err)
    }

    addr.mSelector = kAudioDevicePropertyDeviceUID
    size = 0
    err = AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size)
    guard err == noErr, size > 0 else { throw TapError.createAggregate(err) }
    var cf: Unmanaged<CFString>?
    err = withUnsafeMutablePointer(to: &cf) { ptr in
      AudioObjectGetPropertyData(device, &addr, 0, nil, &size, ptr)
    }
    guard err == noErr, let cf else { throw TapError.createAggregate(err) }
    return cf.takeRetainedValue() as String
  }

  private static func readProcessObjectList() throws -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyProcessObjectList,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    var err = AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    guard err == noErr, size > 0 else { throw TapError.noSpotify }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var value = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
    err = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value)
    guard err == noErr else { throw TapError.noSpotify }
    return value
  }

  private static func translatePID(_ pid: pid_t) throws -> AudioObjectID {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var inPID = pid
    let err = withUnsafePointer(to: &inPID) { pidPtr in
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address,
        UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &object)
    }
    guard err == noErr, object != kAudioObjectUnknown else { throw TapError.noSpotify }
    return object
  }

  private static func readBundleID(_ object: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyBundleID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0
    else { return nil }
    var cf: Unmanaged<CFString>?
    let err = withUnsafeMutablePointer(to: &cf) { ptr in
      AudioObjectGetPropertyData(object, &address, 0, nil, &size, ptr)
    }
    guard err == noErr, let cf else { return nil }
    return cf.takeRetainedValue() as String
  }

  private static func readTapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyFormat,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let err = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
    guard err == noErr else { throw TapError.createTap(err) }
    return asbd
  }
}
