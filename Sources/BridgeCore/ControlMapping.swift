import Foundation

public enum MappingSourceKind: String, Codable, CaseIterable, Sendable {
    case midiNote, midiCC, serial, osc

    public var label: String {
        switch self {
        case .midiNote: return "MIDI note"
        case .midiCC: return "MIDI CC"
        case .serial: return "Serial OSC"
        case .osc: return "OSC in"
        }
    }
}

public enum MappingMode: String, Codable, CaseIterable, Sendable {
    /// Send 1 when pressed; no release message.
    case trigger
    /// Send 1 while held, 0 on release.
    case momentary
    /// Flip the target between 0 and 1 using confirmed feedback.
    case toggle
    /// Scale the control's 0…1 position into the configured output range.
    case absolute
    /// Scale the control's -1…+1 position into the configured output range.
    case bipolar
    /// Encoder movement, sent as a signed integer delta.
    case relative
    /// Forward the OSC message exactly as received (serial/OSC sources only).
    case passthrough

    public var label: String {
        switch self {
        case .trigger: return "Trigger (press)"
        case .momentary: return "Momentary (press/release)"
        case .toggle: return "Toggle (feedback)"
        case .absolute: return "Absolute 0…1"
        case .bipolar: return "Bipolar -1…+1"
        case .relative: return "Relative encoder"
        case .passthrough: return "Passthrough"
        }
    }

    public var isContinuous: Bool {
        self == .absolute || self == .bipolar || self == .relative
    }
}

public struct ControlMapping: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var source: MappingSourceKind
    public var channel: Int?
    public var number: Int?
    public var control: String?
    public var address: String
    /// Second target for a relative control, used for anticlockwise movement.
    /// A browser wheel is two routes (`Browser/Up` and `Browser/Down`), not one
    /// parameter, so a relative mapping needs somewhere to send the other
    /// direction. Nil keeps the plain signed-delta behaviour for a tempo nudge
    /// or any other parameter that takes the delta itself.
    public var reverseAddress: String?
    public var mode: MappingMode
    public var deck: Int
    public var minimum: Double
    public var maximum: Double
    public var endpointID: UUID?
    public var enabled: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String = "", source: MappingSourceKind,
                channel: Int? = nil, number: Int? = nil,                control: String? = nil,
                address: String, reverseAddress: String? = nil, mode: MappingMode, deck: Int = 1,
                minimum: Double = 0, maximum: Double = 1,
                endpointID: UUID? = nil, enabled: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.source = source
        self.channel = channel
        self.number = number
        self.control = control
        self.address = address
        self.reverseAddress = reverseAddress
        self.mode = mode
        self.deck = deck
        self.minimum = minimum
        self.maximum = maximum
        self.endpointID = endpointID
        self.enabled = enabled
        self.createdAt = createdAt
    }

    public var sourceLabel: String {
        switch source {
        case .midiNote:
            return "Note \(number.map(String.init) ?? "?") · CH \((channel ?? 0) + 1)"
        case .midiCC:
            return "CC \(number.map(String.init) ?? "?") · CH \((channel ?? 0) + 1)"
        case .serial, .osc:
            return control ?? "—"
        }
    }

    public var targetLabel: String {
        address.replacingOccurrences(of: "{deck}", with: String(deck))
            .replacingOccurrences(of: "{ch}", with: String(deck))
    }

    public func resolvedAddress(deck override: Int? = nil) -> String {
        resolved(address, deck: override)
    }

    /// Fill the `{deck}`/`{ch}` placeholders in any template this mapping owns.
    public func resolved(_ template: String, deck override: Int? = nil) -> String {
        let number = override ?? deck
        return template
            .replacingOccurrences(of: "{deck}", with: String(number))
            .replacingOccurrences(of: "{ch}", with: String(number))
    }

    public var displayName: String {
        name.isEmpty ? targetLabel.split(separator: "/").last.map(String.init) ?? targetLabel : name
    }

    public var sourceIdentity: String {
        switch source {
        case .midiNote: return "note:\(channel ?? 0):\(number ?? 0)"
        case .midiCC: return "cc:\(channel ?? 0):\(number ?? 0)"
        case .serial: return "serial:\((control ?? "").lowercased())"
        case .osc: return "osc:\((control ?? "").lowercased())"
        }
    }

    public var isValid: Bool {
        guard address.hasPrefix("/"), !address.contains(" "), !address.contains("\n") else { return false }
        switch source {
        case .midiNote, .midiCC:
            return (0...15).contains(channel ?? -1) && (0...127).contains(number ?? -1)
        case .serial, .osc:
            return !(control ?? "").isEmpty
        }
    }
}

public struct OSCEndpoint: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var host: String
    public var port: Int
    /// OSC namespace this endpoint owns, for example "/Resolume". The longest
    /// matching enabled prefix wins; unmatched traffic goes to Syndicate.
    public var prefix: String
    public var enabled: Bool

    public init(id: UUID = UUID(), label: String, host: String = "127.0.0.1",
                port: Int = 7000, prefix: String = "", enabled: Bool = true) {
        self.id = id
        self.label = label
        self.host = host
        self.port = port
        self.prefix = prefix
        self.enabled = enabled
    }

    public var isValid: Bool {
        guard !label.isEmpty, port >= 1, port <= 65_535 else { return false }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy {
            guard let value = Int($0), (0...255).contains(value) else { return false }
            return true
        }
    }

    public func matches(_ address: String) -> Bool {
        guard enabled else { return false }
        let prefix = self.prefix.trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty, prefix != "/" else { return false }
        let lower = address.lowercased()
        let normalized = (prefix.hasSuffix("/") ? prefix : prefix + "/").lowercased()
        return lower == prefix.lowercased() || lower.hasPrefix(normalized)
    }
}

public struct MappingDocument: Codable, Sendable {
    public var version: Int
    public var mappings: [ControlMapping]
    public var endpoints: [OSCEndpoint]

    public init(version: Int = 1, mappings: [ControlMapping] = [], endpoints: [OSCEndpoint] = []) {
        self.version = version
        self.mappings = mappings
        self.endpoints = endpoints
    }
}

/// JSON-backed user mapping. The stock FLX4 map stays in code; anything learned
/// or edited here overrides it and can also address extra hub destinations.
public final class MappingStore {
    public private(set) var mappings: [ControlMapping]
    public private(set) var endpoints: [OSCEndpoint]
    public private(set) var path: String
    public var onChange: (() -> Void)?

    public static var defaultDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cuewire")
            .path
    }

    public static var defaultPath: String {
        (defaultDirectory as NSString).appendingPathComponent("mappings.json")
    }

    /// Pre-1.0 builds stored mappings under the working title "FLX Bridge".
    public static var legacyDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FLX Bridge")
            .path
    }

    public init(path: String = MappingStore.defaultPath) {
        self.path = path
        mappings = []
        endpoints = []
        migrateLegacyFileIfNeeded()
        load()
    }

    private func migrateLegacyFileIfNeeded() {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: path) else { return }
        let legacy = (MappingStore.legacyDirectory as NSString).appendingPathComponent("mappings.json")
        guard fileManager.fileExists(atPath: legacy) else { return }
        try? fileManager.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                         withIntermediateDirectories: true)
        try? fileManager.copyItem(atPath: legacy, toPath: path)
    }

    public func load() {
        guard let data = FileManager.default.contents(atPath: path) else {
            mappings = []
            endpoints = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let document = try? decoder.decode(MappingDocument.self, from: data) {
            mappings = document.mappings.map(Self.normalized)
            endpoints = document.endpoints
        } else if let legacy = try? decoder.decode([ControlMapping].self, from: data) {
            // Early development builds wrote a bare array; keep those files usable.
            mappings = legacy.map(Self.normalized)
            endpoints = []
        } else {
            mappings = []
            endpoints = []
        }
    }

    /// Move a mapping saved under the app's pre-rename root onto `/Syndicate`.
    /// Other destinations keep their own prefix, and the reverse route is part
    /// of the same target set. Run on load and on save, so a file saved by an
    /// older build is repaired before the engine sees it, and a mapping the
    /// editor gets wrong is corrected as it is written rather than a restart
    /// later.
    static func normalized(_ mapping: ControlMapping) -> ControlMapping {
        var mapping = mapping
        mapping.address = HubRouter.rebrand(mapping.address)
        mapping.reverseAddress = mapping.reverseAddress.map(HubRouter.rebrand)
        // The controller renamed its namespace from /Aether to /Nexus. A control
        // address saved against the old firmware follows, or the mapping stops
        // matching the board it was learned on.
        mapping.control = mapping.control.map(NexusAddress.canonical)
        // A signed-delta source cannot drive a press mode: its anticlockwise
        // detent arrives as -1, which a Momentary route turns into a release
        // and a Trigger route into nothing at all, so one direction of the knob
        // looks dead. Older builds let that pairing be saved, so repair it here.
        if LearnedControl(source: mapping.source, control: mapping.control, label: "")
            .isRelativeSource, mapping.mode != .relative {
            mapping.mode = .relative
        }
        // The mirror image, and the one that bit: the board publishes a pot as
        // the position it is at, so Relative throws that position away. The
        // delta is the truncated value, which is zero for every position below
        // full scale, so a whole turn sends a single integer at its very top -
        // a knob that appears to slam its target to the end and then do nothing.
        // Only serial: an OSC-in controller may legitimately send deltas for an
        // address this app knows nothing about, and MIDI CCs keep the mode the
        // user picked.
        if mapping.source == .serial,
           !LearnedControl(source: mapping.source, control: mapping.control, label: "")
            .isRelativeSource,
           mapping.mode == .relative {
            mapping.mode = .absolute
            mapping.reverseAddress = nil
        }
        return mapping
    }

    @discardableResult
    public func save() -> Error? {
        do {
            let directory = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(MappingDocument(mappings: mappings, endpoints: endpoints))
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return nil
        } catch {
            return error
        }
    }

    public func add(_ mapping: ControlMapping) {
        let mapping = Self.normalized(mapping)
        mappings.removeAll { $0.sourceIdentity == mapping.sourceIdentity }
        mappings.append(mapping)
        changed()
    }

    public func update(_ mapping: ControlMapping) {
        let mapping = Self.normalized(mapping)
        if let index = mappings.firstIndex(where: { $0.id == mapping.id }) {
            mappings[index] = mapping
        } else {
            mappings.removeAll { $0.sourceIdentity == mapping.sourceIdentity }
            mappings.append(mapping)
        }
        changed()
    }

    public func remove(id: UUID) {
        mappings.removeAll { $0.id == id }
        changed()
    }

    public func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = mappings.firstIndex(where: { $0.id == id }) else { return }
        mappings[index].enabled = enabled
        changed()
    }

    public func addEndpoint(_ endpoint: OSCEndpoint) {
        endpoints.append(endpoint)
        changed()
    }

    public func updateEndpoint(_ endpoint: OSCEndpoint) {
        if let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) {
            endpoints[index] = endpoint
        } else {
            endpoints.append(endpoint)
        }
        changed()
    }

    public func removeEndpoint(id: UUID) {
        endpoints.removeAll { $0.id == id }
        for index in mappings.indices where mappings[index].endpointID == id {
            mappings[index].endpointID = nil
        }
        changed()
    }

    public func mapping(id: UUID) -> ControlMapping? {
        mappings.first { $0.id == id }
    }

    private func changed() {
        _ = save()
        onChange?()
    }
}

// MARK: - Learn

public enum LearnFilter: String, Codable, CaseIterable, Sendable {
    case any, midi, serial, osc

    public var label: String {
        switch self {
        case .any: return "Any control"
        case .midi: return "MIDI only"
        case .serial: return "Serial OSC only"
        case .osc: return "OSC input only"
        }
    }
}

public struct LearnedControl: Equatable, Sendable {
    public var source: MappingSourceKind
    public var channel: Int?
    public var number: Int?
    public var control: String?
    public var label: String

    public init(source: MappingSourceKind, channel: Int? = nil, number: Int? = nil,
                control: String? = nil, label: String) {
        self.source = source
        self.channel = channel
        self.number = number
        self.control = control
        self.label = label
    }

    /// A source that reports signed movement rather than a position, such as a
    /// controller's rotary encoder. `/Nexus/Encoder/1` turns and
    /// `/Nexus/Encoder/1/Push` presses, so only the former is relative.
    public var isRelativeSource: Bool {
        guard let control else { return false }
        let lower = control.lowercased()
        return lower.contains("/encoder") && !lower.hasSuffix("/push")
    }

    public func draft(address: String = "/Syndicate/Deck/{deck}/PlayPause",
                      mode: MappingMode = .trigger, deck: Int = 1) -> ControlMapping {
        ControlMapping(name: label, source: source, channel: channel, number: number,
                       control: control, address: address, mode: mode, deck: deck)
    }
}

public enum LearnState: Equatable, Sendable {
    case off
    case waiting(LearnFilter)
    case learned(LearnedControl)

    public var isWaiting: Bool {
        if case .waiting = self { return true }
        return false
    }

    public var isActive: Bool {
        self != .off
    }
}

// MARK: - Mode defaults

public enum MappingModeResolver {
    /// A route tells you what shape of control it expects: a 0…1 parameter is
    /// driven by an absolute fader, a −1…+1 parameter by a bipolar fader. The
    /// editor starts new mappings on `Trigger`, so choosing a continuous route
    /// has to replace that leftover default; otherwise a fader sends a single 1
    /// and then nothing at all as it travels.
    public static func resolvedMode(for address: String, selected: MappingMode) -> MappingMode {
        guard selected == .trigger else { return selected }
        let kind = SyndicateCatalog.route(for: address).kind
        switch kind {
        case .continuous, .bipolar:
            return kind.suggestedMode
        default:
            return selected
        }
    }
}

// MARK: - Hub routing

public enum HubRouter {
    /// Rewrite the pre-rename `/AutoPilot` root to `/Syndicate`, leaving every
    /// other namespace untouched. Mappings saved before the rename are migrated
    /// with this, so the editor and the wire both speak the current name.
    public static func rebrand(_ address: String) -> String {
        let lower = address.lowercased()
        guard lower == "/autopilot" || lower.hasPrefix("/autopilot/") else { return address }
        return "/Syndicate" + address.dropFirst("/AutoPilot".count)
    }

    /// Fold controller abbreviations and the legacy AUTO/PILOT namespace onto
    /// Syndicate's command namespace before sending.
    public static func commandAddress(_ address: String) -> String? {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.hasPrefix("/") { value = "/" + value }
        let lower = value.lowercased()
        if lower.hasPrefix("/syndicate/") {
            return "/Syndicate/" + value.dropFirst("/Syndicate/".count)
        }
        // Mappings saved before the rename still spell the root /AutoPilot.
        if lower.hasPrefix("/autopilot/") {
            return rebrand(value)
        }
        let areas = ["deck", "mixer", "header", "browser", "feedback"]
        for area in areas where lower == "/" + area || lower.hasPrefix("/\(area)/") {
            return "/Syndicate" + value
        }
        if lower.hasPrefix("/ap/") {
            return "/Syndicate/" + value.dropFirst(4)
        }
        return value
    }

    /// Rewrite the `/Syndicate` command root onto the root the running app
    /// actually listens on.
    ///
    /// A customised OSC root (`/Stage/Left`) or a pre-rename build that still
    /// listens on `/AutoPilot` receives none of the default `/Syndicate/...`
    /// commands, so outbound commands have to follow the detected root or a
    /// controller press reaches a port that quietly discards it.
    public static func retarget(_ address: String, root: String?) -> String {
        guard let root else { return address }
        var trimmed = root.trimmingCharacters(in: .whitespaces)
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, trimmed != "/" else { return address }
        if !trimmed.hasPrefix("/") { trimmed = "/" + trimmed }
        let lower = address.lowercased()
        if lower == "/syndicate" || lower.hasPrefix("/syndicate/") {
            guard trimmed.lowercased() != "/syndicate" else { return address }
            return trimmed + address.dropFirst("/Syndicate".count)
        }
        if lower == "/autopilot" || lower.hasPrefix("/autopilot/") {
            guard trimmed.lowercased() != "/autopilot" else { return address }
            return trimmed + address.dropFirst("/AutoPilot".count)
        }
        return address
    }

    /// Return the extra endpoint that owns this address, or nil for Syndicate.
    public static func endpoint(for address: String, endpoints: [OSCEndpoint]) -> OSCEndpoint? {
        guard let command = commandAddress(address) else { return nil }
        return endpoints
            .filter { $0.matches(command) }
            .max { $0.prefix.count < $1.prefix.count }
    }

    public static func endpoint(id: UUID?, in endpoints: [OSCEndpoint]) -> OSCEndpoint? {
        guard let id else { return nil }
        return endpoints.first { $0.id == id && $0.enabled }
    }
}
