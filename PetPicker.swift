import AppKit

/// First-launch (or re-open) species chooser — pick which pet lives on your desktop.
@MainActor enum PetPicker {
  static var hasChosen: Bool {
    UserDefaults.standard.object(forKey: "mochiSpecies") != nil
  }

  /// Blocks until the user picks a species. Returns the choice.
  @discardableResult
  static func runModal(force: Bool = false) -> Species {
    if !force, hasChosen { return Online.shared.mySpecies }

    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
      styleMask: [.titled, .fullSizeContentView],
      backing: .buffered,
      defer: false)
    panel.title = "Pick your pet"
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.backgroundColor = NSColor(srgbRed: 0.86, green: 0.92, blue: 1, alpha: 1)
    panel.titlebarAppearsTransparent = true
    panel.isMovableByWindowBackground = true

    let root = NSView(frame: panel.contentView!.bounds)
    root.autoresizingMask = [.width, .height]
    panel.contentView = root

    let title = NSTextField(labelWithString: "Who’s moving in?")
    title.font = .systemFont(ofSize: 18, weight: .bold)
    title.textColor = NSColor(srgbRed: 0.29, green: 0.17, blue: 0.07, alpha: 1)
    title.alignment = .center
    title.frame = NSRect(x: 20, y: 230, width: 480, height: 28)
    root.addSubview(title)

    let subtitle = NSTextField(labelWithString: "You can change this later in the menu.")
    subtitle.font = .systemFont(ofSize: 12, weight: .regular)
    subtitle.textColor = NSColor(srgbRed: 0.29, green: 0.17, blue: 0.07, alpha: 0.65)
    subtitle.alignment = .center
    subtitle.frame = NSRect(x: 20, y: 208, width: 480, height: 18)
    root.addSubview(subtitle)

    var chosen: Species?
    let boxW: CGFloat = 88
    let gap: CGFloat = 12
    let total = CGFloat(Species.allCases.count) * boxW + CGFloat(Species.allCases.count - 1) * gap
    let startX = (520 - total) / 2

    for (i, sp) in Species.allCases.enumerated() {
      let x = startX + CGFloat(i) * (boxW + gap)
      let card = SpeciesCard(species: sp, frame: NSRect(x: x, y: 36, width: boxW, height: 160)) {
        chosen = sp
        NSApp.stopModal()
      }
      root.addSubview(card)
    }

    panel.center()
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    NSApp.runModal(for: panel)
    panel.orderOut(nil)

    let pick = chosen ?? .dog
    Online.shared.mySpecies = pick
    return pick
  }
}

@MainActor private final class SpeciesCard: NSView {
  private let species: Species
  private let onPick: () -> Void
  private let spriteView = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private var hovering = false

  init(species: Species, frame: NSRect, onPick: @escaping () -> Void) {
    self.species = species
    self.onPick = onPick
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 14
    layer?.backgroundColor = NSColor.white.withAlphaComponent(0.72).cgColor

    let look = Look(species: species, pose: .sit, eyes: .happy, tongue: true, wag: 1)
    let sprite = Dog.sprite(look)
    let img = NSImage(cgImage: sprite.image, size: NSSize(width: Canvas.w * 3, height: Canvas.h * 3))
    img.isTemplate = false
    spriteView.image = img
    spriteView.imageScaling = .scaleNone
    spriteView.animates = false
    spriteView.frame = NSRect(x: (frame.width - 76) / 2, y: 48, width: 76, height: 76)
    addSubview(spriteView)

    label.stringValue = "\(species.emoji)\n\(species.title)"
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = NSColor(srgbRed: 0.29, green: 0.17, blue: 0.07, alpha: 1)
    label.alignment = .center
    label.maximumNumberOfLines = 2
    label.frame = NSRect(x: 4, y: 8, width: frame.width - 8, height: 36)
    addSubview(label)

    let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
    addGestureRecognizer(click)
  }

  @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

  @objc private func clicked() { onPick() }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: bounds,
        options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self,
        userInfo: nil))
  }

  override func mouseEntered(with event: NSEvent) {
    hovering = true
    layer?.backgroundColor = NSColor.white.cgColor
    layer?.borderWidth = 2
    layer?.borderColor = NSColor(srgbRed: 0.85, green: 0.45, blue: 0.35, alpha: 1).cgColor
  }

  override func mouseExited(with event: NSEvent) {
    hovering = false
    layer?.backgroundColor = NSColor.white.withAlphaComponent(0.72).cgColor
    layer?.borderWidth = 0
  }
}
