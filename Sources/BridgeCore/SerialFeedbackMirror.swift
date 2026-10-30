import Foundation

/// Picks the feedback messages that are mirrored back to a serial controller.
///
/// Three kinds of address qualify:
///
/// - **Routes a serial mapping owns.** A mapped button or fader gets the
///   destination's confirmed state back, which is what makes toggles and pickup
///   behave.
/// - **Deck play state.** `/Syndicate/Deck/<n>/Playing` is published on change
///   and refreshes once a second, so a booted board and a paused deck both agree
///   without any mapping.
/// - **Deck metadata.** Title, artist, BPM, duration, loop state and track
///   position are what a CDJ-style card shows. They are mirrored too, but the
///   playhead is throttled: Syndicate sends `Progress` around 175 times a
///   second, and the board only needs about ten.
///
/// Everything else is left alone: Syndicate publishes nearly 300 paths, and a
/// controller that drives one button should not pay for all of them.
public struct SerialFeedbackMirror: Sendable {
    /// Canonical deck play-state addresses, one per deck.
    public static let deckStateAddresses: Set<String> = Set(
        (1...4).map { "/syndicate/deck/\($0)/playing" }
    )

    /// Deck routes mirrored to the board, without their prefix.
    public static let deckRoutes: Set<String> = [
        "playing", "trackinfo", "bpm", "progress", "loaded", "loopinfo", "sync",
        // Documented in the OSC reference (14.10): 1 while the deck accepts the
        // tempo fader, which is true for the tempo master or a deck with SYNC
        // off. The board needs it to tell the master from a follower that is
        // running at the same tempo.
        "temposliderenabled",
    ]

    /// Routes that change continuously and are rate limited instead of deduped.
    static let playheadRoutes: Set<String> = ["progress"]

    /// The master tempo. Changes as often as a moved fader, so it is throttled
    /// like the playhead and drives the board's MASTER tag.
    static let headerTempoAddress = "/syndicate/header/bpm"

    /// The master clock: an int beat within the bar, published once per beat at
    /// the session tempo. The board's four-dot clock follows this instead of
    /// counting beats from a deck's playhead, which drifts against the audible
    /// grid and lags the 10 Hz position stream.
    static let headerClockAddress = "/syndicate/header/clock"

    /// Unchanged feedback is still resent this often, so a controller that
    /// rebooted (or was plugged in late) catches up.
    public var refreshInterval: TimeInterval = 1.0

    /// Minimum spacing between playhead updates.
    public var playheadInterval: TimeInterval = 0.1

    private var owned: Set<String> = []
    private var lastSent: [String: (arguments: [OSCArgument], at: Date)] = [:]
    private var lastPlayhead: [String: Date] = [:]
    /// Last value seen per non-playhead address. Syndicate only sends track
    /// metadata when it changes, so this is what lets a rebooted board catch up
    /// without the track being reloaded.
    private var latest: [String: OSCMessage] = [:]

    public init() {}

    /// Addresses owned by enabled serial mappings, in `FLX4Engine.canonical` form.
    public mutating func setOwned(_ addresses: Set<String>) {
        owned = addresses
    }

    public var ownedAddresses: Set<String> { owned }

    /// Forget what was last sent, so the next packet republishes everything.
    /// The cached last-known values survive, because those are the only record
    /// of change-only messages.
    public mutating func reset() {
        lastSent.removeAll()
        lastPlayhead.removeAll()
    }

    /// Everything worth replaying to a controller that just connected, in a
    /// stable order.
    public func snapshot() -> [OSCMessage] {
        latest.keys.sorted().compactMap { latest[$0] }
    }

    /// Messages to write to the serial device for one incoming feedback packet.
    public mutating func messages(for packet: OSCPacket, at now: Date = Date()) -> [OSCMessage] {
        var out: [OSCMessage] = []
        for message in packet.messages {
            let key = FLX4Engine.canonical(message.address)
            let isDeckState = Self.deckStateAddresses.contains(key)
            let isDeckInfo = Self.deckRoute(of: key) != nil
            let isHeaderTempo = key == Self.headerTempoAddress
            let isHeaderClock = key == Self.headerClockAddress
            guard owned.contains(key) || isDeckState || isDeckInfo || isHeaderTempo
                || isHeaderClock else { continue }
            guard let address = HubRouter.commandAddress(message.address) else { continue }

            if isHeaderClock {
                // Same beat resent inside the refresh window is a repeat, not a
                // new beat; every real beat changes the number.
                if let last = lastSent[key], last.arguments == message.arguments,
                   now.timeIntervalSince(last.at) < refreshInterval {
                    continue
                }
            } else if isHeaderTempo {
                if let last = lastPlayhead[key], now.timeIntervalSince(last) < playheadInterval {
                    continue
                }
                lastPlayhead[key] = now
            } else if let route = Self.deckRoute(of: key) {
                if Self.playheadRoutes.contains(route) {
                    if let last = lastPlayhead[key], now.timeIntervalSince(last) < playheadInterval {
                        continue
                    }
                    lastPlayhead[key] = now
                } else if let last = lastSent[key], last.arguments == message.arguments,
                          now.timeIntervalSince(last.at) < refreshInterval {
                    continue
                }
            }

            let forwarded = OSCMessage(address, message.arguments)
            lastSent[key] = (message.arguments, now)
            if Self.deckRoute(of: key) != nil && !Self.playheadRoutes.contains(Self.deckRoute(of: key) ?? "") {
                latest[key] = forwarded
            }
            out.append(forwarded)
        }
        return out
    }

    /// Route name of a canonical `/syndicate/deck/<n>/<route>` address, when it
    /// is one this board displays.
    static func deckRoute(of canonicalAddress: String) -> String? {
        let parts = canonicalAddress.split(separator: "/")
        guard parts.count >= 4, parts[0] == "syndicate", parts[1] == "deck" else { return nil }
        guard Int(parts[2]) != nil else { return nil }
        let route = String(parts[3...].joined(separator: "/"))
        return deckRoutes.contains(route) ? route : nil
    }
}
