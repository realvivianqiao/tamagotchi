import AppKit
import Foundation

/// Quietly checks the site for a newer CoPet.zip and can replace this .app in place.
@MainActor enum Updater {
  private static let versionPath = "/version.json"
  private static var checking = false

  static var currentVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  }

  /// Call on launch — only prompts if a newer build is available.
  static func checkOnLaunch() {
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      await check(forcePrompt: false)
    }
  }

  /// Menu / manual — always tells the user what happened.
  static func checkNow() {
    Task { @MainActor in
      await check(forcePrompt: true)
    }
  }

  private static func check(forcePrompt: Bool) async {
    guard !checking else { return }
    checking = true
    defer { checking = false }

    do {
      let info = try await fetchVersion()
      guard isNewer(info.version, than: currentVersion) else {
        if forcePrompt {
          alert("You’re on the latest CoPet (\(currentVersion)).")
        }
        return
      }
      let notes = info.notes.trimmingCharacters(in: .whitespacesAndNewlines)
      let body =
        notes.isEmpty
        ? "CoPet \(info.version) is ready (you have \(currentVersion))."
        : "CoPet \(info.version) is ready (you have \(currentVersion)).\n\n\(notes)"
      let go = confirm(body, ok: "Update", cancel: "Later")
      guard go else { return }
      Online.shared.onStatus?("downloading update…")
      try await install(from: info.url)
    } catch {
      if forcePrompt {
        alert("Couldn’t check for updates.\n\n\(error.localizedDescription)")
      }
    }
  }

  private struct VersionInfo {
    var version: String
    var url: URL
    var notes: String
  }

  private static func fetchVersion() async throws -> VersionInfo {
    let root = Online.shared.httpRootForUpdates
    guard let url = URL(string: versionPath, relativeTo: root)?.absoluteURL else {
      throw UpdateError.badURL
    }
    var req = URLRequest(url: url)
    req.timeoutInterval = 30
    req.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, resp) = try await URLSession.shared.data(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard status < 400 else { throw UpdateError.http(status) }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let version = json["version"] as? String, !version.isEmpty
    else { throw UpdateError.badJSON }

    let rawURL = (json["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "/CoPet.zip"
    let download: URL
    if let abs = URL(string: rawURL), abs.scheme != nil {
      download = abs
    } else if let rel = URL(string: rawURL, relativeTo: root)?.absoluteURL {
      download = rel
    } else {
      throw UpdateError.badURL
    }
    let notes = (json["notes"] as? String) ?? ""
    return VersionInfo(version: version, url: download, notes: notes)
  }

  private static func install(from zipURL: URL) async throws {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("CoPet-update-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let zipFile = tmp.appendingPathComponent("CoPet.zip")

    let (dl, resp) = try await URLSession.shared.download(from: zipURL)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard status < 400 else { throw UpdateError.http(status) }
    try? FileManager.default.removeItem(at: zipFile)
    try FileManager.default.moveItem(at: dl, to: zipFile)

    let unzipped = tmp.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: unzipped, withIntermediateDirectories: true)
    try run("/usr/bin/ditto", args: ["-x", "-k", zipFile.path, unzipped.path])

    guard let newApp = findApp(in: unzipped) else { throw UpdateError.noAppInZip }
    let currentApp = Bundle.main.bundleURL
    guard currentApp.pathExtension == "app" else { throw UpdateError.notBundled }

    let script = tmp.appendingPathComponent("install.sh")
    let pid = ProcessInfo.processInfo.processIdentifier
    let safer = """
    #!/bin/bash
    set -euo pipefail
    SRC="\(escapeSh(newApp.path))"
    DST="\(escapeSh(currentApp.path))"
    while kill -0 \(pid) 2>/dev/null; do sleep 0.25; done
    sleep 0.4
    rm -rf "$DST"
    /usr/bin/ditto "$SRC" "$DST"
    /usr/bin/xattr -dr com.apple.quarantine "$DST" 2>/dev/null || true
    /usr/bin/open "$DST"
    """
    try safer.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: script.path)

    Online.shared.onStatus?("installing update…")
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/bash")
    proc.arguments = [script.path]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    try proc.run()

    // Quit so the install script can replace the bundle.
    NSApp.terminate(nil)
  }

  private static func findApp(in dir: URL) -> URL? {
    let fm = FileManager.default
    guard let en = fm.enumerator(
      at: dir, includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles])
    else { return nil }
    for case let url as URL in en {
      if url.pathExtension == "app", url.lastPathComponent == "CoPet.app" {
        return url
      }
    }
    // Fallback: any .app
    if let en2 = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
      for case let url as URL in en2 where url.pathExtension == "app" {
        return url
      }
    }
    return nil
  }

  static func isNewer(_ candidate: String, than current: String) -> Bool {
    let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
    let b = current.split(separator: ".").map { Int($0) ?? 0 }
    let n = max(a.count, b.count)
    for i in 0..<n {
      let x = i < a.count ? a[i] : 0
      let y = i < b.count ? b[i] : 0
      if x != y { return x > y }
    }
    return false
  }

  private static func run(_ exe: String, args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw UpdateError.unzipFailed }
  }

  private static func escapeSh(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "$", with: "\\$")
      .replacingOccurrences(of: "`", with: "\\`")
  }

  private static func alert(_ message: String) {
    let a = NSAlert()
    a.messageText = "CoPet"
    a.informativeText = message
    a.alertStyle = .informational
    a.addButton(withTitle: "OK")
    a.runModal()
  }

  private static func confirm(_ message: String, ok: String, cancel: String) -> Bool {
    let a = NSAlert()
    a.messageText = "Update available"
    a.informativeText = message
    a.alertStyle = .informational
    a.addButton(withTitle: ok)
    a.addButton(withTitle: cancel)
    return a.runModal() == .alertFirstButtonReturn
  }

  private enum UpdateError: LocalizedError {
    case badURL, badJSON, http(Int), noAppInZip, notBundled, unzipFailed
    var errorDescription: String? {
      switch self {
      case .badURL: return "bad update url"
      case .badJSON: return "bad version.json"
      case .http(let c): return "HTTP \(c)"
      case .noAppInZip: return "zip didn’t contain CoPet.app"
      case .notBundled: return "run CoPet from the .app (not a raw binary)"
      case .unzipFailed: return "couldn’t unpack the update"
      }
    }
  }
}
