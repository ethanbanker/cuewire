import Foundation

/// Works out a deck's live tempo from its position.
///
/// Syndicate's `/Deck/<n>/BPM` is documented as the current tempo, but the
/// builds in the field only publish it on load and on occasional state changes —
/// it does not follow the pitch fader. What **is** streamed continuously is
/// `/Deck/<n>/Position`, the track time in seconds, about a hundred times a
/// second. The rate at which that advances is the pitch ratio, so live tempo is
/// `trackBpm × rate`: 1.0 at 0% pitch, the master's ratio on a synced deck.
///
/// The rate is fitted over a short window by least squares rather than measured
/// first-sample-to-last. A 1.2 s fit responds in about a second and averages the
/// arrival jitter across ~120 samples, which keeps a steady deck inside a tenth
/// of a BPM. The earlier one-second endpoint measurement (and the three-second
/// window that replaced it) either wobbled or felt sluggish.
public struct DeckTempoTracker: Sendable {
    /// Position history used for the fit. Long enough to average serial jitter,
    /// short enough that a fader move settles in about a second.
    public var window: TimeInterval = 1.2
    /// Shortest span before a fit is meaningful.
    public var minSpan: TimeInterval = 0.8
    /// A rate outside this range is a seek or a stall, not a tempo.
    public var minRate = 0.5
    public var maxRate = 1.5
    /// Exponential smoothing applied to each new fit.
    public var smoothing = 0.5
    /// A rate this close to 1.0 is treated as exactly 1.0. Position arrives as a
    /// float, so a stationary deck can measure 0.9996 and a card would read
    /// 132.1 where Syndicate reads 132.0.
    public var unityDeadband = 0.0015

    private struct Sample {
        let at: Date
        let position: Double
    }

    private var samples: [Int: [Sample]] = [:]
    private var lastRate: [Int: Double] = [:]

    public init() {}

    /// Feed one position update. Returns the latest pitch ratio, when known.
    public mutating func observe(deck: Int, position: Double, at now: Date) -> Double? {
        guard position >= 0, position.isFinite else { return lastRate[deck] }

        var window = samples[deck] ?? []
        // A backwards jump is a seek, a loop or a new track: start a fresh fit
        // so the old slope cannot drag the number the wrong way.
        if let previous = window.last, position < previous.position {
            window.removeAll()
        }
        window.append(Sample(at: now, position: position))
        while let first = window.first, now.timeIntervalSince(first.at) > self.window {
            window.removeFirst()
        }
        samples[deck] = window

        guard let first = window.first else { return lastRate[deck] }
        let span = now.timeIntervalSince(first.at)
        guard span >= minSpan, window.count >= 4 else { return lastRate[deck] }

        // Least-squares slope, in track seconds per wall second.
        let count = Double(window.count)
        var meanTime = 0.0
        var meanPosition = 0.0
        for sample in window {
            meanTime += sample.at.timeIntervalSince(first.at)
            meanPosition += sample.position
        }
        meanTime /= count
        meanPosition /= count

        var numerator = 0.0
        var denominator = 0.0
        for sample in window {
            let time = sample.at.timeIntervalSince(first.at) - meanTime
            numerator += time * (sample.position - meanPosition)
            denominator += time * time
        }
        guard denominator > 0 else { return lastRate[deck] }

        let measured = numerator / denominator
        guard measured >= minRate, measured <= maxRate else { return lastRate[deck] }

        var previous = lastRate[deck] ?? measured
        if abs(previous - 1.0) < unityDeadband { previous = 1.0 }
        var rate = previous + (measured - previous) * smoothing
        if abs(rate - 1.0) < unityDeadband { rate = 1.0 }
        lastRate[deck] = rate
        return rate
    }

    public func rate(for deck: Int) -> Double? { lastRate[deck] }

    public mutating func forget(deck: Int) {
        samples[deck] = nil
        lastRate[deck] = nil
    }
}
