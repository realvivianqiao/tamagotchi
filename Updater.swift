import AppKit
import Sparkle

/// Sparkle-powered updates (EdDSA-signed appcast on the site).
@MainActor final class Updater: NSObject {
  static let shared = Updater()

  private var controller: SPUStandardUpdaterController?

  private override init() {
    super.init()
  }

  /// Start automatic background checks (Info.plist SUEnableAutomaticChecks).
  func start() {
    guard controller == nil else { return }
    controller = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil)
  }

  /// Menu → Check for updates…
  func checkNow() {
    start()
    controller?.checkForUpdates(nil)
  }
}
