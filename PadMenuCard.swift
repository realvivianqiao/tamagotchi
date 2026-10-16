import AppKit

/// Soft pad “character sheet” — name + tiny presence button on the same row, then meters.
@MainActor final class PadMenuCard: NSView {
  var onVisitChanged: ((Bool) -> Void)?

  private let titleLabel = NSTextField(labelWithString: "")
  private let fullnessTrack = MeterTrack(tint: NSColor(calibratedRed: 1, green: 0.55, blue: 0.28, alpha: 1))
  private let happinessTrack = MeterTrack(tint: NSColor(calibratedRed: 1, green: 0.42, blue: 0.55, alpha: 1))
  private let fullnessCaption = NSTextField(labelWithString: "Full")
  private let happinessCaption = NSTextField(labelWithString: "Happy")
  private let presenceButton = PresenceDotButton()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true

    for label in [titleLabel, fullnessCaption, happinessCaption] {
      label.font = .systemFont(ofSize: label === titleLabel ? 13 : 11, weight: label === titleLabel ? .semibold : .medium)
      label.textColor = label === titleLabel ? .labelColor : .secondaryLabelColor
      label.lineBreakMode = .byTruncatingTail
      label.isEditable = false
      label.isBezeled = false
      label.drawsBackground = false
      addSubview(label)
    }

    addSubview(fullnessTrack)
    addSubview(happinessTrack)

    presenceButton.target = self
    presenceButton.action = #selector(presenceClicked)
    addSubview(presenceButton)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func configure(emoji: String, name: String, fullness: Double, happiness: Double, friendsCanVisit: Bool) {
    titleLabel.stringValue = "\(emoji)  \(name)"
    fullnessTrack.progress = fullness / 100
    happinessTrack.progress = happiness / 100
    fullnessCaption.stringValue = "Full  \(Int(fullness))%"
    happinessCaption.stringValue = "Happy  \(Int(happiness))%"
    presenceButton.isOn = friendsCanVisit
    presenceButton.toolTip = friendsCanVisit
      ? "Friends can visit — click to hide"
      : "Hidden — click so friends can visit"
    needsLayout = true
  }

  override var intrinsicContentSize: NSSize { NSSize(width: 248, height: 72) }

  override func layout() {
    super.layout()
    let inset: CGFloat = 14
    let w = bounds.width - inset * 2
    let dot: CGFloat = 18
    let titleY = bounds.height - 26

    presenceButton.frame = NSRect(
      x: bounds.width - inset - dot,
      y: titleY - 1,
      width: dot,
      height: dot)
    titleLabel.frame = NSRect(
      x: inset,
      y: titleY,
      width: presenceButton.frame.minX - inset - 8,
      height: 18)

    let meterY = bounds.height - 48
    let captionW: CGFloat = 78
    fullnessCaption.frame = NSRect(x: inset, y: meterY, width: captionW, height: 14)
    fullnessTrack.frame = NSRect(x: inset + captionW + 4, y: meterY + 3, width: w - captionW - 4, height: 8)

    let meterY2 = meterY - 18
    happinessCaption.frame = NSRect(x: inset, y: meterY2, width: captionW, height: 14)
    happinessTrack.frame = NSRect(x: inset + captionW + 4, y: meterY2 + 3, width: w - captionW - 4, height: 8)
  }

  @objc private func presenceClicked() {
    presenceButton.isOn.toggle()
    let on = presenceButton.isOn
    presenceButton.toolTip = on
      ? "Friends can visit — click to hide"
      : "Hidden — click so friends can visit"
    onVisitChanged?(on)
  }
}

/// Tiny lit / dim dot beside the pad name — presence without a whole status row.
private final class PresenceDotButton: NSButton {
  var isOn = true { didSet { needsDisplay = true } }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    title = ""
    isBordered = false
    imagePosition = .imageOnly
    focusRingType = .none
    setButtonType(.momentaryChange)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    let inset = bounds.insetBy(dx: 3, dy: 3)
    let ring = NSBezierPath(ovalIn: inset.insetBy(dx: -0.5, dy: -0.5))
    NSColor.separatorColor.withAlphaComponent(0.7).setStroke()
    ring.lineWidth = 1
    ring.stroke()

    let fill = NSBezierPath(ovalIn: inset)
    if isOn {
      NSColor.systemGreen.withAlphaComponent(0.95).setFill()
    } else {
      NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
    }
    fill.fill()
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
