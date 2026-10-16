// CoPet — a tiny pet that lives on your desktop.
//
// Build:   ./build.sh && open build/CoPet.app
// Preview: build/CoPet.app/Contents/MacOS/CoPet --preview sprites.png

import AppKit

// MARK: - Main

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  private var pet: Pet?
  func applicationDidFinishLaunching(_ notification: Notification) { pet = Pet() }
  func applicationWillTerminate(_ notification: Notification) { pet?.save() }

  /// Opening CoPet again while it’s already running (and hidden) brings the pet back.
  func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    pet?.revealIfHidden()
    return true
  }
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--preview"), i + 1 < args.count {
  writePreview(to: args[i + 1])
  exit(0)
}

MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.setActivationPolicy(.accessory)
  app.delegate = delegate
  app.run()
}
