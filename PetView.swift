import AppKit

// MARK: - View

@MainActor final class PetView: NSView {
  weak var pet: Pet?

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func mouseDown(with event: NSEvent) { pet?.grab(clickCount: event.clickCount) }
  override func mouseDragged(with event: NSEvent) { pet?.drag() }
  override func mouseUp(with event: NSEvent) { pet?.release(clickCount: event.clickCount) }

  override func rightMouseDown(with event: NSEvent) {
    guard let pet else { return }
    NSMenu.popUpContextMenu(pet.menu, with: event, for: self)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let pet, let ctx = NSGraphicsContext.current?.cgContext else { return }
    let rect = CGRect(origin: spriteOrigin, size: spriteSize)
    ctx.saveGState()
    ctx.interpolationQuality = .none
    // Landing / dance squash (or tall stretch on stretch beats).
    if pet.squashTicks > 0 {
      let t = CGFloat(pet.squashTicks) / 8
      let sy: CGFloat
      let sx: CGFloat
      if pet.danceStretch {
        sy = 1 + 0.28 * t
        sx = 1 - 0.14 * t
      } else {
        sy = 1 - 0.22 * t
        sx = 1 + 0.18 * t
      }
      ctx.translateBy(x: rect.midX, y: rect.minY)
      ctx.scaleBy(x: sx, y: sy)
      ctx.translateBy(x: -rect.midX, y: -rect.minY)
    }
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
    if let text = pet.bubble { drawBubble(text, at: pet.headPoint) }
  }

  private func drawBubble(_ text: String, at head: CGPoint) {
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor(white: 0.15, alpha: 1),
    ]
    let size = (text as NSString).size(withAttributes: attrs)
    var box = CGRect(x: head.x - size.width / 2 - 8, y: head.y + 10, width: size.width + 16, height: size.height + 8)
    box.origin.x = min(max(box.minX, 2), bounds.width - box.width - 2)

    let tail = NSBezierPath()
    tail.move(to: CGPoint(x: head.x - 5, y: box.minY + 1))
    tail.line(to: CGPoint(x: head.x, y: head.y + 2))
    tail.line(to: CGPoint(x: head.x + 5, y: box.minY + 1))
    let body = NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9)
    let ink = NSColor(srgbRed: 0.29, green: 0.17, blue: 0.07, alpha: 1)

    for path in [tail, body] {
      NSColor.white.setFill()
      path.fill()
      ink.setStroke()
      path.lineWidth = 1.5
      path.stroke()
    }
    NSColor.white.setFill()
    CGRect(x: head.x - 3.5, y: box.minY - 1, width: 7, height: 3).fill()
    (text as NSString).draw(at: CGPoint(x: box.minX + 8, y: box.minY + 4), withAttributes: attrs)
  }
}
