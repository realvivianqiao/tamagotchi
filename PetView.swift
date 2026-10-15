import AppKit

// MARK: - View

/// A speech bubble; market alerts carry a level that sets its colour.
struct Bubble {
  let text: String
  var level: MarketAlert.Level?
}

@MainActor final class PetView: NSView {
  weak var pet: Pet?

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { pet?.grab() }
  override func mouseDragged(with event: NSEvent) { pet?.drag() }
  override func mouseUp(with event: NSEvent) { pet?.release() }

  override func rightMouseDown(with event: NSEvent) {
    guard let pet else { return }
    NSMenu.popUpContextMenu(pet.menu, with: event, for: self)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let pet, let ctx = NSGraphicsContext.current?.cgContext else { return }
    let rect = CGRect(origin: spriteOrigin, size: spriteSize)
    ctx.saveGState()
    ctx.interpolationQuality = .none
    if pet.dir < 0 {
      ctx.translateBy(x: rect.midX, y: 0)
      ctx.scaleBy(x: -1, y: 1)
      ctx.translateBy(x: -rect.midX, y: 0)
    }
    ctx.draw(pet.sprite.image, in: rect)
    ctx.restoreGState()

    for p in pet.particles {
      let alpha = min(1, Double(p.life) / Double(p.maxLife) * 2)
      (p.text as NSString).draw(
        at: p.pos, withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black.withAlphaComponent(alpha)])
    }
    if let bubble = pet.bubble { drawBubble(bubble, at: pet.headPoint) }
  }

  private func drawBubble(_ bubble: Bubble, at head: CGPoint) {
    let text = bubble.text as NSString
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor(white: 0.15, alpha: 1),
    ]
    let size = text.boundingRect(
      with: CGSize(width: 250, height: 200), options: [.usesLineFragmentOrigin], attributes: attrs
    ).size
    var box = CGRect(x: head.x - size.width / 2 - 8, y: head.y + 10, width: size.width + 16, height: size.height + 8)
    box.origin.x = min(max(box.minX, 2), bounds.width - box.width - 2)

    let tail = NSBezierPath()
    tail.move(to: CGPoint(x: head.x - 5, y: box.minY + 1))
    tail.line(to: CGPoint(x: head.x, y: head.y + 2))
    tail.line(to: CGPoint(x: head.x + 5, y: box.minY + 1))
    let body = NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9)
    let (ink, paper, width): (NSColor, NSColor, CGFloat) =
      switch bubble.level {
      case .urgent: (NSColor(srgbRed: 0.85, green: 0.26, blue: 0.31, alpha: 1), NSColor(srgbRed: 1, green: 0.93, blue: 0.93, alpha: 1), 2.5)
      case .warn: (NSColor(srgbRed: 0.91, green: 0.57, blue: 0.17, alpha: 1), NSColor(srgbRed: 1, green: 0.97, blue: 0.9, alpha: 1), 2)
      default: (NSColor(srgbRed: 0.29, green: 0.17, blue: 0.07, alpha: 1), .white, 1.5)
      }

    for path in [tail, body] {
      paper.setFill()
      path.fill()
      ink.setStroke()
      path.lineWidth = width
      path.stroke()
    }
    paper.setFill()
    CGRect(x: head.x - 3.5, y: box.minY - 1, width: 7, height: width + 1.5).fill() // join tail to bubble
    text.draw(
      with: CGRect(x: box.minX + 8, y: box.minY + 4, width: size.width + 1, height: size.height),
      options: [.usesLineFragmentOrigin], attributes: attrs)
  }
}

