import AppKit

enum Palette {
    static let background = NSColor(srgbRed: 0.031, green: 0.039, blue: 0.063, alpha: 1)
    static let panel = NSColor(srgbRed: 0.055, green: 0.066, blue: 0.098, alpha: 1)
    static let card = NSColor(srgbRed: 0.078, green: 0.090, blue: 0.129, alpha: 1)
    static let elevated = NSColor(srgbRed: 0.110, green: 0.125, blue: 0.173, alpha: 1)
    static let stroke = NSColor(white: 1, alpha: 0.09)
    static let text = NSColor(srgbRed: 0.929, green: 0.941, blue: 0.969, alpha: 1)
    static let muted = NSColor(srgbRed: 0.541, green: 0.576, blue: 0.651, alpha: 1)
    static let accent = NSColor(srgbRed: 0.400, green: 0.570, blue: 1.000, alpha: 1)
    static let accentDim = NSColor(srgbRed: 0.176, green: 0.231, blue: 0.404, alpha: 1)
    static let accentSoft = NSColor(srgbRed: 0.400, green: 0.570, blue: 1.000, alpha: 0.16)
    static let teal = NSColor(srgbRed: 0.300, green: 0.900, blue: 0.780, alpha: 1)
    static let amber = NSColor(srgbRed: 0.980, green: 0.750, blue: 0.140, alpha: 1)
    static let green = NSColor(srgbRed: 0.350, green: 0.850, blue: 0.500, alpha: 1)
    static let red = NSColor(srgbRed: 0.970, green: 0.440, blue: 0.440, alpha: 1)
    static let held = NSColor(srgbRed: 0.120, green: 0.270, blue: 0.260, alpha: 1)

    /// Corner radius shared by cards, panels and scroll views.
    static let radius: CGFloat = 12
}
