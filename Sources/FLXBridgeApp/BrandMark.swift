import AppKit

/// Small version of the app icon for the window header: the signal arc and
/// waveform on the same dark squircle.
final class BrandMark: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 30, height: 30) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let tile = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        let gradient = NSGradient(colors: [
            NSColor(srgbRed: 0.145, green: 0.176, blue: 0.278, alpha: 1),
            NSColor(srgbRed: 0.047, green: 0.059, blue: 0.098, alpha: 1),
        ])!
        gradient.draw(in: tile, angle: -90)
        NSColor(white: 1, alpha: 0.14).setStroke()
        tile.lineWidth = 1
        tile.stroke()

        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let radius: CGFloat = 7.6
        let arc = NSBezierPath()
        arc.appendArc(withCenter: centre, radius: radius, startAngle: 40, endAngle: 320, clockwise: false)
        arc.lineWidth = 3.4
        arc.lineCapStyle = .round
        Palette.accent.setStroke()
        arc.stroke()

        // Teal connector on the open side.
        let capPoint = NSPoint(x: centre.x + cos(40 * .pi / 180) * radius,
                               y: centre.y + sin(40 * .pi / 180) * radius)
        Palette.teal.setFill()
        NSBezierPath(ovalIn: NSRect(x: capPoint.x - 1.9, y: capPoint.y - 1.9,
                                    width: 3.8, height: 3.8)).fill()

        for (offset, height) in [(-3.3, 4.4), (0.0, 8.4), (3.3, 4.4)] {
            let bar = NSRect(x: centre.x + CGFloat(offset) - 0.7, y: centre.y - CGFloat(height) / 2,
                             width: 1.4, height: CGFloat(height))
            NSColor(white: 1, alpha: 0.94).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 0.7, yRadius: 0.7).fill()
        }
    }
}
