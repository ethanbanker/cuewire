import Foundation

/// Works out which decks are playing from the feedback that is actually sent.
///
/// `/Deck/<n>/Playing` is a subscribed, change-only route: a bridge that starts
/// after the transition misses it until the next change or a
/// `/Syndicate/Feedback/Resend`. What Syndicate does stream continuously is
/// `/Deck/<n>/Progress` (and `Position`), about 160 times a second, **only while
/// a deck's transport is running**. So "position moved recently" is a play
/// signal that needs no resend, and this tracker turns it back into the state the
/// panels and LEDs expect.
///
/// A deck that has never streamed position stays unknown: it is not reported at
/// all, so an empty deck reads as ready rather than paused.
public struct DeckPlaybackTracker: Sendable {
    /// How long a deck may go without a position update before it reads paused.
    /// Long enough to survive a dropped packet, short enough that a pause shows.
    public var timeout: TimeInterval

    private var lastPosition: [Int: Date] = [:]

    public init(timeout: TimeInterval = 0.6) {
        self.timeout = timeout
    }

    /// Note position feedback in `packet`. Returns the decks it touched.
    @discardableResult
    public mutating func observe(_ packet: OSCPacket, at now: Date = Date()) -> Set<Int> {
        var touched: Set<Int> = []
        for message in packet.messages {
            guard Self.isPosition(message.address), let deck = Self.deck(in: message.address) else { continue }
            lastPosition[deck] = now
            touched.insert(deck)
        }
        return touched
    }

    /// Decks whose state can be stated, and whether each is playing. Decks that
    /// have never reported a position are omitted.
    public func states(at now: Date = Date()) -> [Int: Bool] {
        var out: [Int: Bool] = [:]
        for (deck, seenAt) in lastPosition {
            out[deck] = now.timeIntervalSince(seenAt) < timeout
        }
        return out
    }

    public mutating func reset() {
        lastPosition.removeAll()
    }

    /// `…/Deck/<n>/Progress` and `…/Deck/<n>/Position`, in any namespace.
    public static func isPosition(_ address: String) -> Bool {
        let lower = address.lowercased()
        return lower.hasSuffix("/progress") || lower.hasSuffix("/position")
    }

    public static func deck(in address: String) -> Int? {
        let parts = address.split(separator: "/")
        guard let mark = parts.firstIndex(where: { $0.lowercased() == "deck" }),
              parts.index(after: mark) < parts.endIndex
        else { return nil }
        let number = parts[parts.index(after: mark)]
        guard let deck = Int(number), (1...8).contains(deck) else { return nil }
        return deck
    }
}
