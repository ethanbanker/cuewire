import Foundation

/// Track metadata for one deck, as a CDJ card needs it.
public struct DeckMetadata: Codable, Equatable, Sendable {
    public var title: String
    public var artist: String
    /// Musical key (`11A`), empty when Syndicate reports `-`.
    public var key: String
    /// The track's own tempo, as published in `TrackInfo`.
    public var bpm: Double
    /// What the deck is running at now (master sync or pitch), when known.
    public var currentBpm: Double?
    /// Deck SYNC as last reported. Change-only upstream, so a board that reboots
    /// would otherwise not know which deck follows which until it is toggled.
    public var synced: Bool?
    public var duration: Double

    public init(title: String, artist: String, key: String = "", bpm: Double,
                currentBpm: Double? = nil, synced: Bool? = nil, duration: Double) {
        self.title = title
        self.artist = artist
        self.key = key
        self.bpm = bpm
        self.currentBpm = currentBpm
        self.synced = synced
        self.duration = duration
    }

    private enum CodingKeys: String, CodingKey {
        case title, artist, key, bpm, currentBpm, synced, duration
    }

    /// `key` arrived after the first cached files, so it is optional on disk.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decode(String.self, forKey: .artist)
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        bpm = try container.decode(Double.self, forKey: .bpm)
        currentBpm = try container.decodeIfPresent(Double.self, forKey: .currentBpm)
        synced = try container.decodeIfPresent(Bool.self, forKey: .synced)
        duration = try container.decode(Double.self, forKey: .duration)
    }

    public var isEmpty: Bool { title.isEmpty && artist.isEmpty }
}

/// What each deck is playing, kept across relaunches.
///
/// Syndicate publishes `TrackInfo` on load and whenever it changes, and the
/// documented `/Feedback/Resend` replays it when a surface reconnects. The cache
/// is still the fallback for the cases the bridge cannot ask about — Syndicate
/// restarting, a resend that is missed, or a controller that boots while the
/// host is busy — so a card never reads `NO TRACK` for a track that is loaded.
public struct DeckMetadataCache: Codable, Equatable, Sendable {
    public private(set) var decks: [Int: DeckMetadata]
    /// Last master tempo seen on `/Header/BPM`. Change-only upstream, so this is
    /// what a board that boots while a resend is in flight can be given.
    public private(set) var masterTempo: Double?

    public init(decks: [Int: DeckMetadata] = [:], masterTempo: Double? = nil) {
        self.decks = decks
        self.masterTempo = masterTempo
    }

    @discardableResult
    public mutating func recordMasterTempo(_ bpm: Double) -> Bool {
        guard bpm > 0 else { return false }
        var changed = false
        if masterTempo != bpm {
            masterTempo = bpm
            changed = true
        }
        // A synced deck runs at this tempo by definition. Repairing the cached
        // live tempo even when the header itself is unchanged keeps a card that
        // loaded while paused on the master's exact number rather than the
        // track's own BPM.
        for deck in decks.keys where decks[deck]?.synced == true {
            if decks[deck]?.currentBpm != bpm {
                decks[deck]?.currentBpm = bpm
                changed = true
            }
        }
        return changed
    }

    /// `/Header/BPM` to replay, when a tempo has been seen.
    public func masterTempoMessage() -> OSCMessage? {
        guard let masterTempo, masterTempo > 0 else { return nil }
        return OSCMessage("/Syndicate/Header/BPM", [.float(Float(masterTempo))])
    }

    /// Fold a mirrored `TrackInfo` in. Returns true when the cache changed.
    @discardableResult
    public mutating func record(trackInfo message: OSCMessage) -> Bool {
        guard let deck = Self.deckNumber(in: message.address) else { return false }

        let strings = message.arguments.compactMap { argument -> String? in
            if case .string(let value) = argument { return value }
            return nil
        }
        guard let title = strings.first else { return false }
        // Syndicate publishes an empty TrackInfo for an empty deck. Caching it
        // would mark the card loaded with no title, and the board would ask for
        // the missing metadata every five seconds, forever.
        if title.isEmpty { return clear(deck: deck) }
        let artist = strings.count > 1 ? strings[1] : ""
        let rawKey = strings.count > 2 ? strings[2] : ""
        let bpm = Self.number(message.arguments, at: 3)
        let duration = Self.number(message.arguments, at: 4)

        let previous = decks[deck]
        let isNewTrack = previous?.title != title
        // Loading a track on a synced deck does not unlock it: the new track is
        // pulled onto the session tempo, so the card must not show the file's
        // own BPM while the playhead is still stopped.
        var currentBpm = isNewTrack ? bpm : previous?.currentBpm
        if previous?.synced == true, let masterTempo, masterTempo > 0 {
            currentBpm = masterTempo
        }
        let metadata = DeckMetadata(title: title, artist: artist,
                                    key: rawKey == "-" ? "" : rawKey,
                                    bpm: bpm,
                                    currentBpm: currentBpm,
                                    synced: isNewTrack ? nil : previous?.synced,
                                    duration: duration)
        guard previous != metadata else { return false }
        decks[deck] = metadata
        return true
    }

    /// Remember the deck's SYNC state, so a reconnecting board can show the
    /// master tag without waiting for the button to be pressed again.
    @discardableResult
    public mutating func recordSync(deck: Int, synced: Bool) -> Bool {
        guard var metadata = decks[deck] else { return false }
        var changed = false
        if metadata.synced != synced {
            metadata.synced = synced
            changed = true
        }
        // A deck that is synced locks to the header tempo, so the card can show
        // the exact number without waiting for a playhead measurement. This
        // also repairs a stale value when the flag itself did not change, which
        // is the normal case after a relaunch: the cached flag is already true.
        if synced, let masterTempo, masterTempo > 0, metadata.currentBpm != masterTempo {
            metadata.currentBpm = masterTempo
            changed = true
        }
        guard changed else { return false }
        decks[deck] = metadata
        return true
    }

    /// `/Deck/<n>/Sync` to replay, when it has been seen.
    public func syncMessage(for deck: Int) -> OSCMessage? {
        guard let synced = decks[deck]?.synced else { return nil }
        return OSCMessage("/Syndicate/Deck/\(deck)/Sync", [.int(synced ? 1 : 0)])
    }

    /// Remember the tempo the deck is actually running at (`/Deck/n/BPM`).
    @discardableResult
    public mutating func recordLiveBpm(deck: Int, bpm: Double) -> Bool {
        guard var metadata = decks[deck], bpm > 0 else { return false }
        guard metadata.currentBpm != bpm else { return false }
        metadata.currentBpm = bpm
        decks[deck] = metadata
        return true
    }

    /// A deck reported `Loaded 0`: forget it, so a stale title cannot linger.
    @discardableResult
    public mutating func clear(deck: Int) -> Bool {
        decks.removeValue(forKey: deck) != nil
    }

    /// Deck number in any deck address shape: `/Deck/2/…`,
    /// `/Syndicate/Deck/2/…` or `/Syndicate/Deck/2/…`.
    public static func deckNumber(in address: String) -> Int? {
        let parts = address.split(separator: "/")
        guard let index = parts.firstIndex(where: { $0.lowercased() == "deck" }),
              parts.index(after: index) < parts.endIndex,
              let deck = Int(parts[parts.index(after: index)]),
              (1...8).contains(deck) else { return nil }
        return deck
    }

    /// `TrackInfo` messages to replay, in deck order.
    public func messages() -> [OSCMessage] {
        decks.keys.sorted().compactMap { message(for: $0) }
    }

    /// `/Deck/<n>/BPM` for one deck, when its live tempo is known.
    public func liveBpmMessage(for deck: Int) -> OSCMessage? {
        guard let metadata = decks[deck], let live = metadata.currentBpm, live > 0,
              live != metadata.bpm else { return nil }
        return OSCMessage("/Syndicate/Deck/\(deck)/BPM", [.float(Float(live))])
    }

    /// `TrackInfo` for one deck, in the shape Syndicate sends.
    public func message(for deck: Int) -> OSCMessage? {
        guard let metadata = decks[deck], !metadata.isEmpty else { return nil }
        return OSCMessage("/Syndicate/Deck/\(deck)/TrackInfo", [
            .string(metadata.title),
            .string(metadata.artist),
            .string(metadata.key.isEmpty ? "-" : metadata.key),
            .float(Float(metadata.bpm)),
            .float(Float(metadata.duration)),
            .int(0),
            .int(0),
            .string("track"),
        ])
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) -> DeckMetadataCache {
        (try? JSONDecoder().decode(DeckMetadataCache.self, from: data)) ?? DeckMetadataCache()
    }

    private static func number(_ arguments: [OSCArgument], at index: Int) -> Double {
        guard arguments.indices.contains(index) else { return 0 }
        switch arguments[index] {
        case .float(let value): return Double(value)
        case .int(let value): return Double(value)
        case .string, .blob: return 0
        }
    }
}
