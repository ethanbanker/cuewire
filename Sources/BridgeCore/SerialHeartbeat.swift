import Foundation

/// What a `/Nexus/Pong` says about the link's history.
public enum PongOutcome: Equatable {
    /// First reply on a freshly opened port.
    case linked
    /// Ordinary reply on a healthy link.
    case steady
    /// The board went quiet and came back, so it most likely rebooted.
    case resynced
}

/// Ping/pong watchdog for the OSC serial link.
///
/// A USB serial descriptor outlives the device behind it: unplugging a
/// controller leaves the port open, reads stop arriving and no error is
/// reported, so the app keeps believing it is connected while the panels freeze.
/// The firmware answers `/Nexus/Ping` with `/Nexus/Pong`, which turns a silent
/// link into an observable one. This type owns only the timing decisions; the
/// transport does the sending and reopening.
public struct SerialHeartbeat {
    /// How often the host pings a healthy link.
    public var pingInterval: TimeInterval = 2
    /// Silence past this long means the link is wedged, even if the fd is open.
    public var silenceLimit: TimeInterval = 6
    /// Never reopen faster than this, so a board that is genuinely rebooting gets
    /// a moment to come back instead of being reset in a loop.
    public var restartInterval: TimeInterval = 6
    /// A gap this long means the board restarted underneath us, so change-only
    /// state (titles, BPM, loop) has to be republished.
    public var resyncGap: TimeInterval = 3

    private var lastPing: Date = .distantPast
    private var lastPong: Date?
    private var openedAt: Date = .distantPast
    private var lastRestart: Date = .distantPast

    public private(set) var restarts = 0

    public init() {}

    /// Called whenever a port opens. The pong clock restarts, because the
    /// descriptor (and often the board) is new.
    public mutating func opened(at now: Date) {
        openedAt = now
        lastPong = nil
        lastPing = .distantPast
    }

    /// True at most once per `pingInterval`.
    public mutating func pingDue(at now: Date) -> Bool {
        guard now.timeIntervalSince(lastPing) >= pingInterval else { return false }
        lastPing = now
        return true
    }

    /// Records a reply and reports whether the host needs to republish state.
    public mutating func recordPong(at now: Date) -> PongOutcome {
        let gap = lastPong.map { now.timeIntervalSince($0) }
        lastPong = now
        guard let gap else { return .linked }
        return gap > resyncGap ? .resynced : .steady
    }

    /// True when the link has gone quiet long enough to be reopened.
    public mutating func shouldRestart(at now: Date) -> Bool {
        let reference = lastPong ?? openedAt
        guard now.timeIntervalSince(reference) > silenceLimit else { return false }
        guard now.timeIntervalSince(lastRestart) > restartInterval else { return false }
        lastRestart = now
        restarts += 1
        return true
    }

    /// Seconds of silence, for diagnostics.
    public func silence(at now: Date) -> TimeInterval {
        now.timeIntervalSince(lastPong ?? openedAt)
    }
}
