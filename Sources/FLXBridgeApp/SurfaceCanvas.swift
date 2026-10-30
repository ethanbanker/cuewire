import AppKit
import BridgeCore

/// Schematic DDJ-FLX4 surface. Everything is drawn from the published snapshot,
/// so a control lights up as soon as the engine reports a press or Syndicate feedback.
final class SurfaceCanvas: NSView {
    var snapshot: SurfaceSnapshot? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Palette.background.setFill()
        dirtyRect.fill()
        guard let snapshot else { return }

        let gap: CGFloat = 12
        let mixerWidth: CGFloat = 330
        let deckWidth = max((bounds.width - mixerWidth - gap * 2) / 2, 280)
        let height = bounds.height

        drawDeck(in: NSRect(x: 0, y: 0, width: deckWidth, height: height), side: 0, snapshot: snapshot)
        drawMixer(in: NSRect(x: deckWidth + gap, y: 0, width: mixerWidth, height: height), snapshot: snapshot)
        drawDeck(in: NSRect(x: deckWidth + gap + mixerWidth + gap, y: 0,
                            width: deckWidth, height: height), side: 1, snapshot: snapshot)
    }

    // MARK: - Deck

    private func drawDeck(in rect: NSRect, side: Int, snapshot: SurfaceSnapshot) {
        panel(rect)
        let inner = rect.insetBy(dx: 16, dy: 16)
        let deck = snapshot.selectedDecks[side]
        let noteChannel = UInt8(side)
        let padChannel = UInt8(7 + side * 2)

        text("DECK \(side == 0 ? "A" : "B")", in: NSRect(x: inner.minX, y: inner.minY, width: 90, height: 18),
             size: 11, weight: .bold, color: Palette.muted)
        fill(NSRect(x: inner.minX + 92, y: inner.minY, width: 22, height: 22), Palette.accent, radius: 11)
        text("\(deck + 1)", in: NSRect(x: inner.minX + 92, y: inner.minY + 3, width: 22, height: 16),
             size: 12, weight: .bold, color: Palette.background, alignment: .center)

        if snapshot.shifted[side] {
            pill("SHIFT", at: NSPoint(x: inner.maxX - 56, y: inner.minY + 2), color: Palette.amber)
        }

        var x = inner.minX
        let pillY = inner.minY + 32
        x = pill(snapshot.players[deck].label, at: NSPoint(x: x, y: pillY), color: Palette.teal) + 6
        _ = pill(snapshot.bankNames[side], at: NSPoint(x: x, y: pillY), color: Palette.muted)
        if let timing = snapshot.slipTiming[deck + 1] {
            let label = "REPEAT \(timing.rawValue.uppercased())"
            let width = textWidth(label, size: 9, weight: .semibold) + 16
            _ = pill(label, at: NSPoint(x: inner.maxX - width, y: pillY), color: Palette.amber)
        }

        // Pads 4x2
        let padTop = inner.minY + 62
        let padGap: CGFloat = 6
        let padWidth = (inner.width - padGap * 3) / 4
        let padHeight: CGFloat = 44
        let labels = snapshot.padLabels[side]
        for pad in 0..<8 {
            let column = pad % 4
            let row = pad / 4
            let padRect = NSRect(x: inner.minX + CGFloat(column) * (padWidth + padGap),
                                 y: padTop + CGFloat(row) * (padHeight + padGap),
                                 width: padWidth, height: padHeight)
            let isPressed = snapshot.pressed.contains(ControlID(kind: .note, channel: padChannel, number: UInt8(pad)))
            let isHeld = snapshot.held.contains(ControlID(kind: .note, channel: padChannel, number: UInt8(pad)))
            fill(padRect, isPressed ? Palette.accent : (isHeld ? Palette.held : Palette.elevated), radius: 7)
            stroke(padRect, isPressed ? Palette.accent : Palette.stroke, radius: 7)
            text(labels[pad], in: padRect.insetBy(dx: 4, dy: 14),
                 size: 10, weight: .semibold,
                 color: isPressed ? Palette.background : Palette.text, alignment: .center, clips: true)
        }

        var y = padTop + padHeight * 2 + padGap + 16
        line(from: NSPoint(x: inner.minX, y: y), to: NSPoint(x: inner.maxX, y: y))
        y += 14

        let keyGap: CGFloat = 6
        let keyWidth = (inner.width - keyGap * 3) / 4
        let rowOne: [(String, UInt8, Bool)] = [
            ("PLAY", 11, lit(snapshot, "/Syndicate/Deck/\(deck + 1)/Playing")),
            ("CUE", 12, false),
            ("SYNC", 88, lit(snapshot, "/Syndicate/Deck/\(deck + 1)/Sync")),
            ("LOOP", 77, lit(snapshot, "/Syndicate/Deck/\(deck + 1)/Loop")),
        ]
        let rowTwo: [(String, UInt8, Bool)] = [
            ("IN", 16, false), ("OUT", 17, false), ("GRID", 72, false), ("MASTER", 92, false),
        ]
        for (index, key) in rowOne.enumerated() {
            let keyRect = NSRect(x: inner.minX + CGFloat(index) * (keyWidth + keyGap), y: y,
                                 width: keyWidth, height: 30)
            drawKey(keyRect, label: key.0,
                    pressed: snapshot.pressed.contains(ControlID(kind: .note, channel: noteChannel, number: key.1)),
                    lit: key.2)
        }
        y += 36
        for (index, key) in rowTwo.enumerated() {
            let keyRect = NSRect(x: inner.minX + CGFloat(index) * (keyWidth + keyGap), y: y,
                                 width: keyWidth, height: 28)
            drawKey(keyRect, label: key.0,
                    pressed: snapshot.pressed.contains(ControlID(kind: .note, channel: noteChannel, number: key.1)),
                    lit: key.2)
        }

        // Tempo
        let faderTop = y + 44
        let faderHeight = max(inner.maxY - faderTop - 26, 40)
        let tempo = value(snapshot, "/Syndicate/Deck/\(deck + 1)/TempoSlider")
        let waiting = snapshot.pickup[ControlID(kind: .cc, channel: noteChannel, number: 0)] == false
        // The FLX4 tempo fader is wired with + at the bottom, so invert the
        // handle to match the hardware and draw the fill from the centre detent.
        drawFader(in: NSRect(x: inner.minX + 6, y: faderTop, width: 30, height: faderHeight),
                  value: tempo, waiting: waiting, bipolar: true, invert: true)
        text("TEMPO", in: NSRect(x: inner.minX + 6, y: faderTop + faderHeight + 6, width: 60, height: 12),
             size: 8, weight: .semibold, color: Palette.muted)
        // Syndicate's TempoSlider is a ±12-semitone wide-pitch control (its own UI
        // shows the same value), so a linear ±100% readout would be wrong
        // everywhere except centre and the ends.
        let semitones = tempo.map { ($0 * 2 - 1) * 12 }
        text(semitones.map { String(format: "%+.2f st", $0) } ?? "--",
             in: NSRect(x: inner.minX + 48, y: faderTop, width: 130, height: 22),
             size: 19, weight: .semibold, color: Palette.text, mono: true)
        text(snapshot.pickupEnabled ? (waiting ? "Waiting for pickup" : "Pickup ready") : "Absolute (knob position)",
             in: NSRect(x: inner.minX + 48, y: faderTop + 26, width: 160, height: 14),
             size: 10, weight: .regular, color: waiting ? Palette.amber : Palette.muted)
    }

    private func drawKey(_ rect: NSRect, label: String, pressed: Bool, lit: Bool) {
        fill(rect, pressed ? Palette.accent : (lit ? Palette.accentDim : Palette.elevated), radius: 6)
        stroke(rect, lit || pressed ? Palette.accent : Palette.stroke, radius: 6)
        text(label, in: rect.insetBy(dx: 3, dy: 9), size: 9, weight: .bold,
             color: pressed ? Palette.background : Palette.text, alignment: .center, clips: true)
    }

    // MARK: - Mixer

    private func drawMixer(in rect: NSRect, snapshot: SurfaceSnapshot) {
        panel(rect)
        let inner = rect.insetBy(dx: 16, dy: 16)
        text("MIXER", in: NSRect(x: inner.minX, y: inner.minY, width: 100, height: 16),
             size: 11, weight: .bold, color: Palette.muted)
        text("CH A / CH B follow the selected decks",
             in: NSRect(x: inner.minX, y: inner.minY + 18, width: inner.width, height: 14),
             size: 9, weight: .regular, color: Palette.muted.withAlphaComponent(0.8))

        let columnGap: CGFloat = 12
        let columnWidth = (inner.width - columnGap) / 2
        let top = inner.minY + 42
        for side in 0..<2 {
            let column = NSRect(x: inner.minX + CGFloat(side) * (columnWidth + columnGap), y: top,
                                width: columnWidth, height: inner.maxY - top)
            drawChannel(column, side: side, snapshot: snapshot)
        }
        let dividerX = inner.minX + columnWidth + columnGap / 2
        line(from: NSPoint(x: dividerX, y: top), to: NSPoint(x: dividerX, y: inner.maxY))
    }

    private func drawChannel(_ rect: NSRect, side: Int, snapshot: SurfaceSnapshot) {
        let deck = snapshot.selectedDecks[side]
        let channel = UInt8(side)
        text("CH \(deck + 1)", in: NSRect(x: rect.minX, y: rect.minY, width: 60, height: 18),
             size: 13, weight: .bold, color: Palette.text)
        text(side == 0 ? "A" : "B", in: NSRect(x: rect.minX + 56, y: rect.minY + 3, width: 14, height: 12),
             size: 8, weight: .bold, color: Palette.muted)

        let knobSize: CGFloat = 36
        let knobGap: CGFloat = 4
        let knobWidth = (rect.width - knobGap * 2) / 3
        let rows: [[(String, String, Double?)]] = [
            [("TRIM", "Trim", nil), ("HIGH", "EQ/High", nil), ("MID", "EQ/Mid", nil)],
            [("LOW", "EQ/Low", nil), ("FILTER", "Filter1", nil), ("CUE MIX", "", nil)],
        ]
        var y = rect.minY + 26
        for row in rows {
            for (index, knob) in row.enumerated() {
                let x = rect.minX + CGFloat(index) * (knobWidth + knobGap)
                let knobRect = NSRect(x: x + (knobWidth - knobSize) / 2, y: y, width: knobSize, height: knobSize)
                let knobValue: Double?
                let waiting: Bool
                var bipolar = false
                if knob.1.isEmpty {
                    knobValue = value(snapshot, "/Syndicate/Header/CueMix")
                    waiting = false
                } else if knob.1 == "Filter1" {
                    // Syndicate has separate low-pass (Filter1) and high-pass
                    // (Filter2) controls; the FLX4's single centre-detent knob
                    // is shown as one bipolar value.
                    let low = value(snapshot, "/Syndicate/Mixer/CH\(deck + 1)/Filter1") ?? 0
                    let high = value(snapshot, "/Syndicate/Mixer/CH\(deck + 1)/Filter2") ?? 0
                    knobValue = min(max(0.5 + (high - low) / 2, 0), 1)
                    waiting = snapshot.pickup[ControlID(kind: .cc, channel: 6, number: UInt8(23 + side))] == false
                    bipolar = true
                } else {
                    knobValue = value(snapshot, "/Syndicate/Mixer/CH\(deck + 1)/\(knob.1)")
                    let cc = ccFor(route: knob.1)
                    waiting = snapshot.pickup[ControlID(kind: .cc, channel: channel, number: cc)] == false
                }
                drawKnob(in: knobRect, value: knobValue, waiting: waiting, bipolar: bipolar)
                text(knob.0, in: NSRect(x: x - 2, y: y + knobSize + 4, width: knobWidth + 4, height: 11),
                     size: 8, weight: .semibold, color: Palette.muted, alignment: .center, clips: true)
            }
            y += knobSize + 22
        }

        // Volume fader, meter and cue
        let faderTop = y + 8
        let faderHeight = max(rect.maxY - faderTop - 22, 40)
        drawFader(in: NSRect(x: rect.minX + 10, y: faderTop, width: 26, height: faderHeight),
                  value: value(snapshot, "/Syndicate/Mixer/CH\(deck + 1)/Volume"),
                  waiting: snapshot.pickup[ControlID(kind: .cc, channel: channel, number: 19)] == false)
        text("VOL", in: NSRect(x: rect.minX + 4, y: faderTop + faderHeight + 4, width: 40, height: 11),
             size: 8, weight: .semibold, color: Palette.muted)
        drawMeter(in: NSRect(x: rect.minX + 52, y: faderTop, width: 10, height: faderHeight),
                  level: value(snapshot, "/Syndicate/Mixer/CH\(deck + 1)/Meter"))
        let cuePressed = snapshot.pressed.contains(ControlID(kind: .note, channel: channel, number: 84))
        let cueLit = lit(snapshot, "/Syndicate/Mixer/CH\(deck + 1)/Cue")
        let cueRect = NSRect(x: rect.minX + 78, y: faderTop + faderHeight - 30, width: 46, height: 28)
        drawKey(cueRect, label: "CUE", pressed: cuePressed, lit: cueLit)
    }

    private func ccFor(route: String) -> UInt8 {
        switch route {
        case "Trim": return 4
        case "EQ/High": return 7
        case "EQ/Mid": return 11
        case "EQ/Low": return 15
        case "Volume": return 19
        default: return 0
        }
    }

    // MARK: - Primitives

    private func panel(_ rect: NSRect) {
        fill(rect, Palette.card, radius: Palette.radius)
        stroke(rect, Palette.stroke, radius: Palette.radius)
    }

    private func fill(_ rect: NSRect, _ color: NSColor, radius: CGFloat) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    private func stroke(_ rect: NSRect, _ color: NSColor, radius: CGFloat, width: CGFloat = 1) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: width / 2, dy: width / 2),
                                xRadius: radius, yRadius: radius)
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }

    private func line(from: NSPoint, to: NSPoint) {
        let path = NSBezierPath()
        path.move(to: from)
        path.line(to: to)
        path.lineWidth = 1
        Palette.stroke.setStroke()
        path.stroke()
    }

    @discardableResult
    private func text(_ string: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight,
                      color: NSColor, alignment: NSTextAlignment = .left, mono: Bool = false,
                      clips: Bool = false) -> CGFloat {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                        : NSFont.systemFont(ofSize: size, weight: weight)
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = clips ? .byTruncatingTail : .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ]
        if clips { NSGraphicsContext.current?.saveGraphicsState() }
        (string as NSString).draw(in: rect, withAttributes: attributes)
        if clips { NSGraphicsContext.current?.restoreGraphicsState() }
        return (string as NSString).size(withAttributes: attributes).width
    }

    private func textWidth(_ string: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
    }

    @discardableResult
    private func pill(_ string: String, at point: NSPoint, color: NSColor) -> CGFloat {
        let width = textWidth(string, size: 9, weight: .semibold) + 16
        let rect = NSRect(x: point.x, y: point.y, width: width, height: 18)
        fill(rect, color.withAlphaComponent(0.16), radius: 9)
        stroke(rect, color.withAlphaComponent(0.4), radius: 9)
        text(string, in: NSRect(x: rect.minX + 8, y: rect.minY + 4, width: width - 16, height: 12),
             size: 9, weight: .semibold, color: Palette.text)
        return rect.maxX
    }

    private func drawKnob(in rect: NSRect, value: Double?, waiting: Bool, bipolar: Bool = false) {
        // An unknown bipolar value sits at the centre detent; an unknown
        // unipolar value sits at zero.
        let level = min(max(value ?? (bipolar ? 0.5 : 0), 0), 1)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 3
        let circle = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                width: radius * 2, height: radius * 2))
        Palette.elevated.setFill()
        circle.fill()
        if waiting {
            Palette.amber.withAlphaComponent(0.9).setStroke()
        } else {
            Palette.stroke.setStroke()
        }
        circle.lineWidth = 1
        circle.stroke()

        strokeArc(center: center, radius: radius, from: 135, to: 405, color: Palette.background, width: 3.5)
        let angle = 135 + 270 * level
        if bipolar {
            let centerAngle: CGFloat = 270
            strokeArc(center: center, radius: radius + 2, from: centerAngle - 1.5, to: centerAngle + 1.5,
                      color: Palette.muted, width: 1.5)
            if level > 0.5 {
                strokeArc(center: center, radius: radius, from: centerAngle, to: angle,
                          color: Palette.accent, width: 3.5)
            } else if level < 0.5 {
                strokeArc(center: center, radius: radius, from: angle, to: centerAngle,
                          color: Palette.accent, width: 3.5)
            }
        } else if level > 0 {
            strokeArc(center: center, radius: radius, from: 135, to: angle,
                      color: Palette.accent, width: 3.5)
        }
        let radians = angle * .pi / 180
        let dot = NSRect(x: center.x + cos(radians) * (radius * 0.6) - 1.75,
                         y: center.y + sin(radians) * (radius * 0.6) - 1.75,
                         width: 3.5, height: 3.5)
        Palette.text.setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    private func strokeArc(center: NSPoint, radius: CGFloat, from: CGFloat, to: CGFloat,
                           color: NSColor, width: CGFloat) {
        guard to > from else { return }
        let steps = max(Int((to - from) / 4), 8)
        let path = NSBezierPath()
        for index in 0...steps {
            let angle = (from + (to - from) * CGFloat(index) / CGFloat(steps)) * .pi / 180
            let point = NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.lineWidth = width
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    private func drawFader(in rect: NSRect, value: Double?, waiting: Bool,
                           bipolar: Bool = false, invert: Bool = false) {
        var level = min(max(value ?? (bipolar ? 0.5 : 0), 0), 1)
        if invert { level = 1 - level }
        let track = NSRect(x: rect.midX - 2.5, y: rect.minY, width: 5, height: rect.height)
        fill(track, Palette.background, radius: 2.5)
        let handleY = rect.maxY - rect.height * level - 4.5
        if bipolar {
            // Fill from the centre detent towards the handle, so a tempo fader
            // at 0% does not look like a half-open volume fader.
            let centerY = rect.midY
            let top = min(centerY, handleY + 4.5)
            let bottom = max(centerY, handleY + 4.5)
            fill(NSRect(x: track.minX, y: top, width: 5, height: max(bottom - top, 0)),
                 Palette.accent, radius: 2.5)
            let tick = NSRect(x: track.minX - 4, y: centerY - 0.5, width: 13, height: 1)
            Palette.muted.withAlphaComponent(0.55).setFill()
            tick.fill()
        } else {
            let fillHeight = rect.height * level
            fill(NSRect(x: track.minX, y: rect.maxY - fillHeight, width: 5, height: fillHeight),
                 Palette.accent, radius: 2.5)
        }
        let handle = NSRect(x: rect.midX - 10, y: handleY, width: 20, height: 9)
        fill(handle, Palette.elevated, radius: 2)
        let border: NSColor = value == nil ? Palette.muted : (waiting ? Palette.amber : Palette.accent)
        stroke(handle, border, radius: 2, width: 1.5)
    }

    private func drawMeter(in rect: NSRect, level: Double?) {
        let segments = 14
        let active = Int(((min(max(level ?? 0, 0), 1)) * Double(segments)).rounded())
        let gap: CGFloat = 2
        let height = (rect.height - CGFloat(segments - 1) * gap) / CGFloat(segments)
        for index in 0..<segments {
            let y = rect.maxY - CGFloat(index + 1) * height - CGFloat(index) * gap
            let color: NSColor
            if index >= segments - 2 { color = Palette.red }
            else if index >= segments - 5 { color = Palette.amber }
            else { color = Palette.green }
            fill(NSRect(x: rect.minX, y: y, width: rect.width, height: height),
                 index < active ? color : Palette.background, radius: 1)
        }
    }

    private func lit(_ snapshot: SurfaceSnapshot, _ address: String) -> Bool {
        (value(snapshot, address) ?? 0) >= 0.5
    }

    private func value(_ snapshot: SurfaceSnapshot, _ address: String) -> Double? {
        snapshot.values[address.lowercased()]
    }
}
