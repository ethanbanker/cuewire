import Foundation

/// The eight-pixel WS2812 strip under the Nexus 4 pod keys, painted with
/// Syndicate's hot-cue colours.
///
/// Syndicate colours hot cue *n* with `general.cueColor<n>` from its settings,
/// the same swatch its own deck draws, so the strip matches the screen without
/// asking the host for anything it does not already publish. The palette is
/// global rather than per deck — every deck shows the same eight colours — so
/// one palette covers the strip whichever deck is loaded.
///
/// Pixel *n* sits under pod key *n*, and the firmware accepts colour and level
/// per pixel through `/Nexus/Light/led/<n>`. Frames are sent once per change:
/// the board latches the last colour it was given and drops repeats.
public struct PodStrip: Sendable {
    /// Pixels on the strip, one per hot cue.
    public static let pixelCount = 8

    /// Syndicate's factory hot-cue palette (`AARRGGBB`, alpha dropped), used
    /// when its settings file cannot be read. Without it a bridge that started
    /// before Syndicate would leave the strip on the firmware's idle colour.
    public static let fallbackColours: [String] = [
        "e7463d", "f28c32", "ffd85a", "f2e9c8",
        "5db1d1", "3567ad", "65528d", "4e8b78",
    ]

    /// The eight colours to paint, in pixel order, with the fallback filling
    /// any slot the settings file does not name.
    public static func palette(from settings: SyndicateSettings?) -> [String] {
        let reported = settings?.cueColours ?? []
        return (0..<pixelCount).map { index in
            let colour = index < reported.count ? reported[index] : ""
            return normalised(colour) ?? fallbackColours[index]
        }
    }

    /// `/Nexus/Light/led/<n>` for every pixel. `level` is 0…1 and scales the
    /// colour; the firmware's power cap is applied on top of it, not here.
    public static func messages(for palette: [String], level: Double = 1) -> [OSCMessage] {
        let clamped = Float(max(0, min(1, level)))
        return (0..<pixelCount).map { index in
            let colour = index < palette.count
                ? normalised(palette[index]) ?? fallbackColours[index]
                : fallbackColours[index]
            return OSCMessage("/Nexus/Light/led/\(index + 1)",
                              [.float(clamped), .string("#" + colour)])
        }
    }

    /// `rrggbb` from `AARRGGBB`, `#rrggbb` or `rrggbb`; nil when the text is not
    /// six or eight hex digits. Alpha is dropped: a WS2812 has none.
    public static func normalised(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8 else { return nil }
        guard value.allSatisfy({ $0.isHexDigit }) else { return nil }
        return String(value.suffix(6))
    }
}
