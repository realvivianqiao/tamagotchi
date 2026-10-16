import AppKit

/// Soft pad “character sheet” for the menu — name, meters, friends-can-visit switch.
/// Feels like a companion HUD, not a Status: Online checkbox.
@MainActor final class PadMenuCard: NSView {
  var onVisitChanged: ((Bool) -> Void)?

  private let titleLabel = NSTextField(labelWithString: "")
  private let visitLabel = NSTextField(labelWithString: "")
  private let fullnessTrack = MeterTrack(tint: NSColor(calibratedRed: 1, green: 0.55, blue: 0.28, alpha: 1))
  private let happinessTrack = MeterTrack(tint: NSColor(calibratedRed: 1, green: 0.42, blue: 0.55, alpha: 1))
  private let fullnessCaption = NSTextField(labelWithString: "Full")
  private let happinessCaption = NSTextField(labelWithString: "Happy")
  private let visitSwitch = MenuFirstSwitch()
  private let hairline = NSBox()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true

    for label in [titleLabel, visitLabel, fullnessCaption, happinessCaption] {
      label.font = .systemFont(ofSize: label === titleLabel ? 13 : 11, weight: label === titleLabel ? .semibold : .medium)
      label.textColor = label === titleLabel ? .labelColor : .secondaryLabelColor
      label.lineBreakMode = .byTruncatingTail
      label.isEditable = false
      label.isBezeled = false
      label.drawsBackground = false
      addSubview(label)
    }

    hairline.boxType = .separator
    addSubview(hairline)
    addSubview(fullnessTrack)
    addSubview(happinessTrack)

    visitSwitch.target = self
    visitSwitch.action = #selector(visitToggled)
    visitSwitch.controlSize = .small
    addSubview(visitSwitch)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func configure(emoji: String, name: String, fullness: Double, happiness: Double, friendsCanVisit: Bool) {
    titleLabel.stringValue = "\(emoji)  \(name)"
    fullnessTrack.progress = fullness / 100
    happinessTrack.progress = happiness / 100
    fullnessCaption.stringValue = "Full  \(Int(fullness))%"
    happinessCaption.stringValue = "Happy  \(Int(happiness))%"
    visitSwitch.state = friendsCanVisit ? .on : .off
    visitLabel.stringValue = friendsCanVisit ? "Friends can visit" : "Hidden from friends"
    needsLayout = true
  }

  override var intrinsicContentSize: NSSize { NSSize(width: 248, height: 108) }

  override func layout() {
    super.layout()
    let inset: CGFloat = 14
    let w = bounds.width - inset * 2
    titleLabel.frame = NSRect(x: inset, y: bounds.height - 28, width: w, height: 18)

    let meterY = bounds.height - 52
    let captionW: CGFloat = 78
    fullnessCaption.frame = NSRect(x: inset, y: meterY, width: captionW, height: 14)
    fullnessTrack.frame = NSRect(x: inset + captionW + 4, y: meterY + 3, width: w - captionW - 4, height: 8)

    let meterY2 = meterY - 18
    happinessCaption.frame = NSRect(x: inset, y: meterY2, width: captionW, height: 14)
    happinessTrack.frame = NSRect(x: inset + captionW + 4, y: meterY2 + 3, width: w - captionW - 4, height: 8)

    hairline.frame = NSRect(x: inset, y: 36, width: w, height: 1)

    let sw = visitSwitch.fittingSize
    visitSwitch.frame = NSRect(
      x: bounds.width - inset - sw.width,
      y: 10,
      width: sw.width,
      height: sw.height)
    visitLabel.frame = NSRect(
      x: inset,
      y: 12,
      width: visitSwitch.frame.minX - inset - 8,
      height: 16)
  }

  @objc private func visitToggled() {
    let on = visitSwitch.state == .on
    visitLabel.stringValue = on ? "Friends can visit" : "Hidden from friends"
    onVisitChanged?(on)
  }
}

/// Tiny filled meter — warm game HUD, not ASCII blocks.
private final class MeterTrack: NSView {
  var tint: NSColor
  var progress: CGFloat = 0 { didSet { needsDisplay = true } }

  init(tint: NSColor) {
    self.tint = tint
    super.init(frame: .zero)
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func draw(_ dirtyRect: NSRect) {
    let radius = bounds.height / 2
    NSColor.separatorColor.withAlphaComponent(0.45).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    guard progress > 0.01 else { return }
    var fill = bounds
    fill.size.width = max(bounds.height, bounds.width * min(1, max(0, progress)))
    tint.setFill()
    NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
  }
}

/// Agent (LSUIElement) menus need first-mouse so the switch works without a key window.
private final class MenuFirstSwitch: NSSwitch {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
