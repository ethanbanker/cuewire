import AppKit

// Cuewire app icon: a dark squircle holding a gradient signal arc, open on the
// right like a cable connector, with a small waveform at its centre.
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let full = NSRect(x: 0, y: 0, width: size, height: size)
let tileRect = full.insetBy(dx: 62, dy: 62)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 188, yRadius: 188)

// Soft drop shadow so the icon sits like a macOS app tile.
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
shadow.shadowBlurRadius = 42
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.set()
NSColor.black.setFill()
tile.fill()
NSGraphicsContext.current?.restoreGraphicsState()

let background = NSGradient(colors: [
    NSColor(srgbRed: 0.105, green: 0.125, blue: 0.205, alpha: 1),
    NSColor(srgbRed: 0.035, green: 0.043, blue: 0.075, alpha: 1),
])!
background.draw(in: tile, angle: -90)

// Ambient light in the upper left.
for step in 0..<7 {
    let spread = CGFloat(step) * 46
    let glow = NSBezierPath(ovalIn: NSRect(x: 110 - spread, y: 470 - spread,
                                          width: 760 + spread * 2, height: 760 + spread * 2))
    NSColor(srgbRed: 0.30, green: 0.44, blue: 0.98, alpha: 0.035).setFill()
    glow.fill()
}

// Inner rim highlight.
let rim = NSBezierPath(roundedRect: tileRect.insetBy(dx: 3, dy: 3), xRadius: 186, yRadius: 186)
NSColor(white: 1, alpha: 0.11).setStroke()
rim.lineWidth = 3
rim.stroke()

// Signal arc: a cable that leaves the tile on the right.
let centre = NSPoint(x: 512, y: 512)
let radius: CGFloat = 238
let startAngle: CGFloat = 38
let endAngle: CGFloat = 322
let strokeWidth: CGFloat = 78
let blue = NSColor(srgbRed: 0.40, green: 0.57, blue: 1.0, alpha: 1)
let teal = NSColor(srgbRed: 0.30, green: 0.90, blue: 0.78, alpha: 1)

func blend(_ t: CGFloat) -> NSColor {
    NSColor(srgbRed: blue.redComponent + (teal.redComponent - blue.redComponent) * t,
            green: blue.greenComponent + (teal.greenComponent - blue.greenComponent) * t,
            blue: blue.blueComponent + (teal.blueComponent - blue.blueComponent) * t,
            alpha: 1)
}

let segments = 96
for index in 0..<segments {
    let t0 = CGFloat(index) / CGFloat(segments)
    let t1 = CGFloat(index + 1) / CGFloat(segments) + 0.002
    let a0 = (startAngle + (endAngle - startAngle) * t0) * .pi / 180
    let a1 = (startAngle + (endAngle - startAngle) * t1) * .pi / 180
    let path = NSBezierPath()
    path.move(to: NSPoint(x: centre.x + cos(a0) * radius, y: centre.y + sin(a0) * radius))
    path.line(to: NSPoint(x: centre.x + cos(a1) * radius, y: centre.y + sin(a1) * radius))
    path.lineWidth = strokeWidth
    path.lineCapStyle = .butt
    blend((t0 + t1) / 2).setStroke()
    path.stroke()
}

// Rounded connector ends.
for (angle, colour) in [(startAngle, blue), (endAngle, teal)] {
    let radians = angle * .pi / 180
    let point = NSPoint(x: centre.x + cos(radians) * radius, y: centre.y + sin(radians) * radius)
    let cap = NSBezierPath(ovalIn: NSRect(x: point.x - strokeWidth / 2, y: point.y - strokeWidth / 2,
                                          width: strokeWidth, height: strokeWidth))
    colour.setFill()
    cap.fill()
}

// Centred waveform: three rounded bars, the middle one taller.
let bars: [(CGFloat, CGFloat)] = [(70, 0.80), (150, 1.0), (70, 0.80)]
let barWidth: CGFloat = 26
let barGap: CGFloat = 22
let totalWidth = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * barGap
var x = centre.x - totalWidth / 2
for (height, alpha) in bars {
    let rect = NSRect(x: x, y: centre.y - height / 2, width: barWidth, height: height)
    let bar = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
    NSColor(white: 1, alpha: 0.92 * alpha).setFill()
    bar.fill()
    x += barWidth + barGap
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("icon rendering failed\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: output))
