import AppKit
import BridgeCore

/// Live latency board: one row per path, each with p50/p95/max and a rolling
/// trace of its recent samples.
///
/// The view is fully custom-drawn so the rows, numbers and sparklines share one
/// coordinate space and the whole card redraws in a single pass. It only marks
/// itself dirty when a number or trace actually changed, so the 10 Hz status
/// refresh does not repaint a static panel.
final class LatencyPanelView: NSView {
    private struct Row {
        let title: String
        let color: NSColor
        let stats: LatencyStats
        let history: [Double]
        let ceiling: Double
    }

    private var rows: [Row] = []

    /// Fixed full-scale ceilings keep the traces from rescaling on every sample.
    /// A value above its ceiling simply pegs the line at the top. The serial
    /// ping settles around 5-6 ms on this board; the first reply after a boot
    /// can be much slower while the panels repaint.
    private static let ceilings: [Double] = [1.0, 2.0, 2.0, 20.0]
    private static let titles = ["MIDI", "SERIAL", "OSC IN", "LINK"]
    private static let colors: [NSColor] = [Palette.accent, Palette.teal, Palette.amber, Palette.green]

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "Input → OSC wire for MIDI, serial and OSC; LINK is the serial ping round-trip."
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Replace the readout. Identical data is ignored so the panel does not
    /// redraw at the status cadence.
    func update(stats: [LatencySource: LatencyStats], history: [LatencySource: [Double]],
                linkRoundTrip: LatencyStats, linkRoundTripHistory: [Double]) {
        let sources: [(LatencyStats, [Double])] = [
            (stats[.midi] ?? .empty, history[.midi] ?? []),
            (stats[.serial] ?? .empty, history[.serial] ?? []),
            (stats[.osc] ?? .empty, history[.osc] ?? []),
            // The LINK row is the ping, not the command/feedback probe, so a
            // stopped transport still shows whether the wire is healthy.
            (linkRoundTrip, linkRoundTripHistory),
        ]
        let next = sources.enumerated().map { index, pair in
            Row(title: Self.titles[index], color: Self.colors[index], stats: pair.0,
                history: Array(pair.1.suffix(60)), ceiling: Self.ceilings[index])
        }
        guard !same(as: next) else { return }
        rows = next
        needsDisplay = true
    }

    private func same(as next: [Row]) -> Bool {
        guard rows.count == next.count else { return false }
        for (a, b) in zip(rows, next) {
            if a.title != b.title || a.stats != b.stats || a.history != b.history {
                return false
            }
        }
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: card, xRadius: Palette.radius, yRadius: Palette.radius)
        Palette.panel.setFill()
        shape.fill()
        Palette.stroke.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        drawTitle()
        guard !rows.isEmpty else { return }

        let top: CGFloat = 34
        let rowHeight = max(1, (bounds.height - top - 8) / CGFloat(rows.count))
        let sparkWidth: CGFloat = 84
        let sparkX = bounds.width - 14 - sparkWidth

        for (index, row) in rows.enumerated() {
            let y = top + CGFloat(index) * rowHeight
            if index > 0 {
                Palette.stroke.setStroke()
                let divider = NSBezierPath()
                divider.move(to: NSPoint(x: 14, y: y))
                divider.line(to: NSPoint(x: bounds.width - 14, y: y))
                divider.lineWidth = 1
                divider.stroke()
            }
            drawRow(row, y: y, height: rowHeight, sparkX: sparkX, sparkWidth: sparkWidth)
        }
    }

    private func drawTitle() {
        draw("LATENCY", in: NSRect(x: 14, y: 10, width: 160, height: 16),
             font: .systemFont(ofSize: 10, weight: .bold), color: Palette.muted, kern: 1.2)
        draw("p50 / p95 / max · ms",
             in: NSRect(x: bounds.width - 14 - 160, y: 11, width: 160, height: 14),
             font: .systemFont(ofSize: 9, weight: .regular), color: Palette.muted, align: .right)
    }

    private func drawRow(_ row: Row, y: CGFloat, height: CGFloat,
                         sparkX: CGFloat, sparkWidth: CGFloat) {
        let center = y + height / 2
        let dot = NSRect(x: 14, y: center - 3, width: 6, height: 6)
        row.color.setFill()
        NSBezierPath(ovalIn: dot).fill()

        draw(row.title, in: NSRect(x: 26, y: center - 7, width: 66, height: 14),
             font: .systemFont(ofSize: 9, weight: .semibold), color: row.color, kern: 0.4)

        let stats = row.stats
        let values = stats.count > 0
            ? String(format: "%.2f   %.2f   %.2f", stats.p50, stats.p95, stats.maximum)
            : "—      —      —"
        let valueColor: NSColor = stats.p95 > 20 ? Palette.red
            : stats.p95 > 8 ? Palette.amber : Palette.text
        draw(values, in: NSRect(x: 100, y: center - 7, width: sparkX - 108, height: 14),
             font: .monospacedSystemFont(ofSize: 10, weight: .regular), color: valueColor)

        drawHistory(row.history, in: NSRect(x: sparkX, y: y + 6, width: sparkWidth,
                                            height: max(8, height - 12)),
                    color: row.color, ceiling: row.ceiling)
    }

    private func drawHistory(_ values: [Double], in rect: NSRect, color: NSColor,
                             ceiling: Double) {
        Palette.stroke.setStroke()
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: rect.minX, y: rect.maxY - 1))
        baseline.line(to: NSPoint(x: rect.maxX, y: rect.maxY - 1))
        baseline.lineWidth = 1
        baseline.stroke()

        guard values.count >= 2 else { return }
        let scale = max(ceiling, 0.001)
        let step = rect.width / CGFloat(values.count - 1)
        let path = NSBezierPath()
        var last = NSPoint.zero
        for (index, value) in values.enumerated() {
            let x = rect.minX + CGFloat(index) * step
            let normalized = min(1, max(0, value / scale))
            let y = rect.maxY - 1 - CGFloat(normalized) * (rect.height - 2)
            last = NSPoint(x: x, y: y)
            if index == 0 { path.move(to: last) } else { path.line(to: last) }
        }

        let fill = path.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: rect.maxX, y: rect.maxY - 1))
        fill.line(to: NSPoint(x: rect.minX, y: rect.maxY - 1))
        fill.close()
        color.withAlphaComponent(0.12).setFill()
        fill.fill()

        color.setStroke()
        path.lineWidth = 1.4
        path.lineJoinStyle = .round
        path.stroke()

        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: last.x - 1.6, y: last.y - 1.6, width: 3.2, height: 3.2)).fill()
    }

    private func draw(_ text: String, in rect: NSRect, font: NSFont, color: NSColor,
                      align: NSTextAlignment = .left, kern: CGFloat = 0) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = .byClipping
        let string = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .kern: kern,
            .paragraphStyle: style,
        ])
        string.draw(in: rect)
    }
}
