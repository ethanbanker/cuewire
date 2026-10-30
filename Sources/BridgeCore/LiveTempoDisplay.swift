import Foundation

/// Turns a measured pitch ratio into the number a deck card prints.
///
/// The playhead measurement is accurate to about a tenth of a BPM, and a deck
/// sitting at its native tempo can read 129.04 or 129.13. Syndicate's own UI
/// shows 129, so the card should too: a measurement within a quarter BPM of a
/// whole number snaps to that whole number. Anything further away keeps one
/// decimal, which is what makes a real fader move visible.
///
/// The second rule is a deadband around the value already on screen. Without it
/// the estimate can cross a tenth boundary every few hundred milliseconds and
/// the number appears to bounce, even when the deck is not moving. The deadband
/// is wider than the snap so a value sitting on its edge cannot flip back and
/// forth between 129 and 129.1.
public enum LiveTempoDisplay {
    /// Whole-BPM snap width. This is the measurement's own error, not a fader
    /// step: below it the card shows the tempo the host UI shows.
    public static let wholeSnap = 0.28

    /// How far the *raw* estimate must move before the displayed number may
    /// change. Larger than the snap width so a value sitting on a boundary
    /// cannot flip back and forth.
    public static let deadband = 0.34

    /// The number to print for a track tempo and a measured pitch ratio.
    public static func value(trackBpm: Double, rate: Double) -> Double {
        guard trackBpm > 0, rate.isFinite, rate > 0 else { return 0 }
        let raw = trackBpm * rate
        let whole = raw.rounded()
        if abs(raw - whole) < wholeSnap { return whole }
        return (raw * 10).rounded() / 10
    }

    /// Whether `raw` is far enough from the number already shown to replace it.
    public static func shouldReplace(previous: Double?, raw: Double) -> Bool {
        guard let previous else { return true }
        return abs(raw - previous) >= deadband
    }
}
