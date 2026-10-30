import Foundation

public enum LatencySource: String, CaseIterable, Sendable {
    case midi, serial, osc
}

/// Millisecond timing summary. Empty summaries report zeros so the UI can render
/// a stable row before the first control moves.
public struct LatencyStats: Sendable, Equatable {
    public var count: Int = 0
    public var p50: Double = 0
    public var p95: Double = 0
    public var maximum: Double = 0
    public var average: Double = 0
    public var last: Double = 0

    public static let empty = LatencyStats()

    public var short: String {
        guard count > 0 else { return "--" }
        return String(format: "%.2f / %.2f ms", p50, p95)
    }

    public var detailed: String {
        guard count > 0 else { return "no samples" }
        return String(format: "p50 %.2f · p95 %.2f · max %.2f · last %.2f ms (%d)", p50, p95, maximum, last, count)
    }
}

/// Rolling timing for the two paths that matter to a live controller:
/// input → OSC on the wire, and command → Syndicate feedback.
///
/// The round-trip figures are a best-effort probe: Syndicate publishes on its
/// own 30 Hz feedback clock, so this measures "how long until the first packet
/// that confirms this route", not a dedicated ping. Expected probes expire
/// after a second so unrelated periodic feedback cannot invent numbers.
///
/// All calls are made on the bridge engine queue, so no locking is needed.
public final class LatencyMonitor {
    public static let maximumSamples = 512
    private var samples: [LatencySource: [Double]] = [:]
    private var pending: [String: Date] = [:]
    private var roundTrips: [Double] = []
    /// Ping/pong round-trip to the serial board, kept apart from the
    /// Syndicate feedback probe: it measures the wire itself.
    private var linkRoundTrips: [Double] = []

    public init() {}

    public func begin() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    /// Record the elapsed time from `begin()` to now for an input event.
    public func finish(_ start: UInt64, source: LatencySource) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= start else { return }
        record(milliseconds: Double(now - start) / 1_000_000, source: source)
    }

    public func record(milliseconds: Double, source: LatencySource) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        var values = samples[source, default: []]
        Self.append(milliseconds, to: &values)
        samples[source] = values
    }

    public func stats(_ source: LatencySource) -> LatencyStats {
        Self.summary(samples[source] ?? [])
    }

    public var roundTrip: LatencyStats {
        Self.summary(roundTrips)
    }

    public var linkRoundTrip: LatencyStats {
        Self.summary(linkRoundTrips)
    }

    /// Recent input-to-wire samples, oldest first, for a sparkline.
    public func recent(_ source: LatencySource, limit: Int = 60) -> [Double] {
        Self.tail(samples[source] ?? [], limit: limit)
    }

    public func recentLinkRoundTrips(limit: Int = 60) -> [Double] {
        Self.tail(linkRoundTrips, limit: limit)
    }

    /// Record one `/Nexus/Pong` round trip.
    public func recordLinkRoundTrip(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        Self.append(milliseconds, to: &linkRoundTrips)
    }

    // MARK: - Feedback probes

    public func expectFeedback(address: String, at date: Date = Date()) {
        let key = FLX4Engine.canonical(address)
        pending[key] = date
        if pending.count > 256 {
            let cutoff = date.addingTimeInterval(-1)
            pending = pending.filter { $0.value >= cutoff }
            if pending.count > 256 { pending.removeAll() }
        }
    }

    @discardableResult
    public func recordFeedback(address: String, at date: Date = Date()) -> Double? {
        let key = FLX4Engine.canonical(address)
        guard let sent = pending.removeValue(forKey: key) else { return nil }
        let seconds = date.timeIntervalSince(sent)
        guard seconds >= 0, seconds <= 1 else { return nil }
        let milliseconds = seconds * 1_000
        Self.append(milliseconds, to: &roundTrips)
        return milliseconds
    }

    public func cancelFeedback(address: String) {
        pending.removeValue(forKey: FLX4Engine.canonical(address))
    }

    public func reset() {
        samples.removeAll()
        pending.removeAll()
        roundTrips.removeAll()
        linkRoundTrips.removeAll()
    }

    // MARK: - Summary

    private static func append(_ value: Double, to values: inout [Double]) {
        values.append(value)
        if values.count > maximumSamples {
            values.removeFirst(values.count - maximumSamples)
        }
    }

    private static func tail(_ values: [Double], limit: Int) -> [Double] {
        guard limit > 0 else { return [] }
        return Array(values.suffix(limit))
    }

    static func summary(_ values: [Double]) -> LatencyStats {
        guard !values.isEmpty else { return .empty }
        let sorted = values.sorted()
        func percentile(_ fraction: Double) -> Double {
            let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
            return sorted[index]
        }
        return LatencyStats(
            count: sorted.count,
            p50: percentile(0.50),
            p95: percentile(0.95),
            maximum: sorted.last ?? 0,
            average: sorted.reduce(0, +) / Double(sorted.count),
            last: values.last ?? 0
        )
    }
}
