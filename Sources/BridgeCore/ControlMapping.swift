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
    public var mode: MappingMode
    public var deck: Int
    public var minimum: Double
    public var maximum: Double
    public var endpointID: UUID?
    public var enabled: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String = "", source: MappingSourceKind,
                channel: Int? = nil, number: Int? = nil, control: String? = nil,
                address: String, mode: MappingMode, deck: Int = 1,
                minimum: Double = 0, maximum: Double = 1,
                endpointID: UUID? = nil, enabled: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.source = source
        self.channel = channel
        self.number = number
        self.control = control
        self.address = address
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
        let number = override ?? deck
        return address
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
    /// matching enabled prefix wins; unmatched traffic goes to AUTO/PILOT.
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
            mappings = document.mappings
            endpoints = document.endpoints
        } else if let legacy = try? decoder.decode([ControlMapping].self, from: data) {
            // Early development builds wrote a bare array; keep those files usable.
            mappings = legacy
            endpoints = []
        } else {
            mappings = []
            endpoints = []
        }
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
        mappings.removeAll { $0.sourceIdentity == mapping.sourceIdentity }
        mappings.append(mapping)
        changed()
    }

    public func update(_ mapping: ControlMapping) {
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

    public func draft(address: String = "/AutoPilot/Deck/{deck}/PlayPause",
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
        let kind = AutoPilotCatalog.route(for: address).kind
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
    /// Fold controller abbreviations and AUTO/PILOT's feedback namespace onto
    /// the command namespace before sending.
    public static func commandAddress(_ address: String) -> String? {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.hasPrefix("/") { value = "/" + value }
        let lower = value.lowercased()
        if lower.hasPrefix("/syndicate/") {
            return "/AutoPilot/" + value.dropFirst("/Syndicate/".count)
        }
        if lower.hasPrefix("/autopilot/") {
            return "/AutoPilot/" + value.dropFirst("/AutoPilot/".count)
        }
        let areas = ["deck", "mixer", "header", "browser", "feedback"]
        for area in areas where lower == "/" + area || lower.hasPrefix("/\(area)/") {
            return "/AutoPilot" + value
        }
        if lower.hasPrefix("/ap/") {
            return "/AutoPilot/" + value.dropFirst(4)
        }
        return value
    }

    /// Return the extra endpoint that owns this address, or nil for AUTO/PILOT.
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
