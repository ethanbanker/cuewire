import Foundation

public enum LogLevel: String, Sendable {
    case info, warn, error
}

public struct ControlID: Hashable, Sendable {
    public enum Kind: String, Sendable { case note, cc }
    public var kind: Kind
    public var channel: UInt8
    public var number: UInt8

    public init(kind: Kind, channel: UInt8, number: UInt8) {
        self.kind = kind
        self.channel = channel
        self.number = number
    }
}

public enum EngineEffect: Equatable, Sendable {
    case osc(OSCMessage)
    /// Send to one extra hub destination instead of Syndicate.
    case oscTo(OSCMessage, UUID)
    case midi([UInt8])
    case log(LogLevel, String)
    /// A control was captured by Learn; the UI turns it into a mapping.
    case learned(LearnedControl)
}

/// Everything the SwiftUI surface needs. Produced by the engine, never mutated by views.
public struct SurfaceSnapshot: Sendable {
    public var selectedDecks: [Int] = [0, 1]
    public var players: [PlayerType] = [.unknown, .unknown, .unknown, .unknown]
    public var bankNames: [String] = ["Hot cues", "Hot cues"]
    public var padLabels: [[String]] = Array(repeating: Array(repeating: "--", count: 8), count: 2)
    public var shifted: [Bool] = [false, false]
    public var slipTiming: [Int: SlipTiming] = [:]
    public var pressed: Set<ControlID> = []
    public var held: Set<ControlID> = []
    public var pickup: [ControlID: Bool] = [:]
    /// False when the engine sends physical knob positions directly; the
    /// surface uses this to avoid showing a pickup state that cannot happen.
    public var pickupEnabled = true
    public var values: [String: Double] = [:]

    public init() {}
}

struct NoteKey: Hashable {
    var channel: UInt8
    var note: UInt8
}

struct CCKey: Hashable {
    var channel: UInt8
    var cc: UInt8
}

struct CaptureKey: Hashable {
    var control: CCKey
    var address: String
}

struct Hold {
    var owner: String
    var address: String
    var press: Int32
    var release: Int32
    var timing: SlipTiming?
}

enum FeedbackScale {
    case unit, bipolar, meter, switchLED, text
}

/// The FLX4 protocol engine. Pure: it takes MIDI/OSC input and returns the
/// OSC packets and MIDI bytes to send, so it can be unit tested without hardware.
public final class FLX4Engine {
    private var selected: [Int] = [0, 1]
    private var banks: [Int] = [0, 0, 0, 0]
    private var players: [PlayerType] = [.unknown, .unknown, .unknown, .unknown]
    private var shifts: [Bool] = [false, false]
    private var pressed: Set<NoteKey> = []
    private var held: [NoteKey: Hold] = [:]
    private var msb: [CCKey: UInt8] = [:]
    private var positions: [CCKey: UInt16] = [:]
    private var captured: Set<CaptureKey> = []
    private var ledsSent: [String: UInt8] = [:]
    private var pendingToggles: [String: (expected: Double, at: Date)] = [:]
    private var controlWriters: [String: (owner: String, pending: Bool)] = [:]
    private var holds: [Hold] = []
    private var slipModes: [String: SlipTiming] = [:]
    private var values: [String: Double] = [:]
    private var texts: [String: String] = [:]
    private var scales: [String: FeedbackScale] = [:]
    private var warned: Set<String> = []
    private var lastKeepalive = Date.distantPast
    private var mappingByNote: [String: ControlMapping] = [:]
    private var mappingByCC: [String: ControlMapping] = [:]
    private var mappingByControl: [String: ControlMapping] = [:]
    private var observed: [String: [OSCArgument]] = [:]
    private var ccPressed: Set<CCKey> = []

    /// User mappings override the stock FLX4 rules. They are installed by the
    /// service after the JSON store is loaded, and re-applied after every edit.
    public var userMappings: [ControlMapping] = [] {
        didSet { rebuildMappingIndex() }
    }

    /// The built-in FLX4 surface is a preset, not the product. When no DDJ-FLX4
    /// is connected, stock routes are disabled so a generic controller's notes
    /// and CCs cannot accidentally trigger FLX4 transport or mixer bindings.
    /// Learned mappings keep working either way.
    public var flx4PresetEnabled = true
    public private(set) var learnState: LearnState = .off

    /// True: analog controls must cross Syndicate's confirmed value before they send
    /// (soft takeover). False: every movement sends the knob/fader's physical
    /// position immediately, the way rekordbox and Serato behave. The engine
    /// defaults to pickup; the app turns it off unless the user asks for it.
    /// Turning pickup on starts from a clean slate, so captures made while
    /// absolute mode was active cannot skip the gate.
    public var analogPickup = true {
        didSet {
            if analogPickup && !oldValue { captured.removeAll() }
        }
    }

    public var observedAddresses: [String] { Array(observed.keys).sorted() }

    public private(set) var oscSent = 0
    public private(set) var feedbackAccepted = 0
    public private(set) var lastFeedback: Date?
    public private(set) var lastWarning: String?

    public init() {
        for rule in FLX4Mapping.analog {
            let scale: FeedbackScale = rule.bipolar ? .bipolar : .unit
            for deck in 0..<4 {
                register(FLX4Mapping.resolved(rule.address, deck: deck), scale)
                if let shifted = rule.shiftedAddress {
                    register(FLX4Mapping.resolved(shifted, deck: deck), scale)
                }
            }
        }
        for rule in FLX4Mapping.buttons {
            if case .toggle(let address) = rule.behavior {
                for deck in 0..<4 {
                    register(FLX4Mapping.resolved(address, deck: deck), .switchLED)
                }
            }
        }
        for led in FLX4Mapping.leds {
            for deck in 0..<4 {
                register(FLX4Mapping.resolved(led.address, deck: deck),
                         led.kind == .switchLED ? .switchLED : .meter)
            }
        }
        for deck in 0..<4 {
            register("/Syndicate/Deck/\(deck + 1)/PlayerType", .text)
        }
    }

    private func register(_ address: String, _ scale: FeedbackScale) {
        scales[address.lowercased()] = scale
    }

    // MARK: - User mappings and learn

    private func rebuildMappingIndex() {
        mappingByNote.removeAll()
        mappingByCC.removeAll()
        mappingByControl.removeAll()
        for mapping in userMappings where mapping.enabled {
            switch mapping.source {
            case .midiNote:
                mappingByNote["\(mapping.channel ?? 0):\(mapping.number ?? 0)"] = mapping
                register(mapping.resolvedAddress(), .switchLED)
            case .midiCC:
                mappingByCC["\(mapping.channel ?? 0):\(mapping.number ?? 0)"] = mapping
                register(mapping.resolvedAddress(), mapping.mode == .toggle ? .switchLED : .unit)
            case .serial, .osc:
                if let control = mapping.control {
                    mappingByControl[control.lowercased()] = mapping
                }
                register(mapping.resolvedAddress(), mapping.mode == .toggle ? .switchLED : .unit)
            }
            if mapping.mode == .bipolar {
                register(mapping.resolvedAddress(), .bipolar)
            }
        }
    }

    public func beginLearn(_ filter: LearnFilter = .any) {
        learnState = .waiting(filter)
    }

    public func cancelLearn() {
        learnState = .off
    }

    public func mapping(forSerial control: String) -> ControlMapping? {
        mappingByControl[control.lowercased()]
    }

    public func mapping(forControl control: String) -> ControlMapping? {
        mappingByControl[control.lowercased()]
    }

    /// Feed one message received from the ESP32-S3 through learned serial mappings.
    public func handle(serial message: OSCMessage, now: Date = Date()) -> [EngineEffect] {
        handle(control: message, source: .serial, now: now)
    }

    /// Feed one message received on the UDP control-input port.
    public func handle(osc message: OSCMessage, now: Date = Date()) -> [EngineEffect] {
        handle(control: message, source: .osc, now: now)
    }

    /// The service calls this only when a mapping is installed; otherwise the
    /// message passes straight through the hub.
    public func handle(control message: OSCMessage, source: MappingSourceKind,
                       now: Date = Date()) -> [EngineEffect] {
        if case .waiting(let filter) = learnState,
           filter == .any || (source == .serial && filter == .serial) || (source == .osc && filter == .osc) {
            let labelPrefix = source == .serial ? "Serial" : "OSC"
            let learned = LearnedControl(source: source, control: message.address,
                                         label: "\(labelPrefix) \(message.address)")
            learnState = .learned(learned)
            return [.learned(learned)]
        }
        guard let mapping = mappingByControl[message.address.lowercased()], mapping.enabled else {
            return []
        }
        // A serial switch sends 1 on press and 0 on release. A command or a
        // toggle is one gesture per press, so the release must not fire again:
        // without this, one click of the board's knob switch advanced two menu
        // levels or flipped a toggle straight back.
        let isRelease = Self.isRelease(message)
        switch mapping.mode {
        case .passthrough:
            return emit(mapping, message.arguments, address: message.address)
        case .trigger:
            return isRelease ? [] : emit(mapping, [.int(1)])
        case .toggle:
            return isRelease ? [] : toggleMapping(mapping, now: now)
        case .relative:
            let delta = message.firstInt ?? Int32(message.firstFloat ?? 0)
            guard delta != 0 else { return [] }
            // A browser wheel is two routes, not one parameter: forward one
            // trigger per detent to the route for that direction. Without a
            // reverse address the delta itself is the value, which is what a
            // tempo nudge or any signed parameter expects.
            if let reverse = mapping.reverseAddress?.trimmingCharacters(in: .whitespaces),
               !reverse.isEmpty {
                let target = delta > 0 ? mapping.resolvedAddress() : mapping.resolved(reverse)
                let steps = Int(delta > 0 ? delta : -delta)
                return (0..<steps).flatMap { _ in emit(mapping, [.int(1)], address: target) }
            }
            return emit(mapping, [.int(delta)])
        case .absolute, .bipolar:
            let value = mapping.mode == .bipolar
                ? serialBipolarValue(message)
                : serialValue(message)
            guard let value else { return [] }
            return emitContinuous(mapping, value: value)
        case .momentary:
            guard let value = serialValue(message) else { return [] }
            return emit(mapping, [.int(value >= 0.5 ? 1 : 0)])
        }
    }

    /// True when a press/release control reports an explicit zero. A message
    /// carrying no number, or a partial value such as 0.4, is not a release.
    private static func isRelease(_ message: OSCMessage) -> Bool {
        if let value = message.firstInt { return value == 0 }
        if let value = message.firstFloat { return value == 0 }
        return false
    }

    private func serialValue(_ message: OSCMessage) -> Double? {
        for argument in message.arguments {
            switch argument {
            case .float(let value): return Double(value)
            case .int(let value):
                let number = Double(value)
                return number >= 0 && number <= 1 ? number : number / 127.0
            default: continue
            }
        }
        return nil
    }

    /// Bipolar serial input is either already -1…+1 or a 0…127 / ±1 integer
    /// from a simple firmware encoder.
    private func serialBipolarValue(_ message: OSCMessage) -> Double? {
        for argument in message.arguments {
            switch argument {
            case .float(let value): return Double(value)
            case .int(let value):
                let number = Double(value)
                if abs(number) <= 1 { return number }
                return (number / 127.0) * 2 - 1
            default: continue
            }
        }
        return nil
    }

    private func emitContinuous(_ mapping: ControlMapping, value: Double) -> [EngineEffect] {
        let normalized: Double
        switch mapping.mode {
        case .bipolar:
            normalized = min(max((value + 1) / 2, 0), 1)
        default:
            normalized = min(max(value, 0), 1)
        }
        let minimum = mapping.minimum
        let maximum = mapping.maximum
        let output = minimum + normalized * (maximum - minimum)
        return emit(mapping, [.float(Float(output))])
    }

    private func emit(_ mapping: ControlMapping, _ arguments: [OSCArgument],
                      address: String? = nil) -> [EngineEffect] {
        let target = address ?? mapping.resolvedAddress()
        let message = OSCMessage(target, arguments)
        oscSent += 1
        if let endpoint = mapping.endpointID {
            return [.oscTo(message, endpoint)]
        }
        return [.osc(message)]
    }

    private func toggleMapping(_ mapping: ControlMapping, now: Date) -> [EngineEffect] {
        let address = mapping.resolvedAddress()
        let key = address.lowercased()
        if let pending = pendingToggles[key] {
            if now.timeIntervalSince(pending.at) >= 1 {
                pendingToggles.removeValue(forKey: key)
                return warnOnce("\(address): toggle blocked waiting for Syndicate confirmation; enable its subscription and press again.")
            }
            return warnOnce("\(address): toggle blocked; waiting for Syndicate confirmation of the last press.")
        }
        guard let current = values[key] ?? observedSwitchValue(address) else {
            return warnOnce("\(address): toggle blocked; no confirmed feedback for this route.")
        }
        let next: Int32 = current >= 0.5 ? 0 : 1
        pendingToggles[key] = (Double(next), now)
        if let endpoint = mapping.endpointID {
            oscSent += 1
            return [.oscTo(OSCMessage(address, [.int(next)]), endpoint)]
        }
        return send(address, .int(next))
    }

    private func observedSwitchValue(_ address: String) -> Double? {
        guard let arguments = observed[address.lowercased()] else { return nil }
        for argument in arguments {
            if case .int(let value) = argument, value == 0 || value == 1 { return Double(value) }
            if case .float(let value) = argument, value == 0 || value == 1 { return Double(value) }
        }
        return nil
    }

    // MARK: - Lifecycle

    public func start() -> [EngineEffect] {
        var effects: [EngineEffect] = []
        for side in 0..<2 {
            effects.append(contentsOf: modeFeedback(side))
            effects.append(contentsOf: refreshLEDs(side))
        }
        // Ask Syndicate to republish everything it has. Without this the first seconds
        // after launch have no switch/LED state and pickup stays blocked.
        effects.append(contentsOf: send("/Syndicate/Feedback/Resend", .int(1)))
        return effects
    }

    public func tick(now: Date = Date()) -> [EngineEffect] {
        guard now.timeIntervalSince(lastKeepalive) >= 0.2 else { return [] }
        lastKeepalive = now
        return [.midi(FLX4Mapping.keepalive)]
    }

    public func shutdown() -> [EngineEffect] {
        var effects: [EngineEffect] = []
        for hold in holds {
            effects.append(contentsOf: sendRelease(hold))
        }
        holds.removeAll()
        for side in 0..<2 {
            for led in FLX4Mapping.leds where led.channel == UInt8(side) {
                effects.append(.midi([(led.kind == .switchLED ? 0x90 : 0xb0) + UInt8(side), led.number, led.off]))
            }
            effects.append(.midi([0x90 + UInt8(side), FLX4Mapping.bankNotes[0], 127]))
        }
        return effects
    }

    // MARK: - MIDI input

    /// Split a MIDI byte stream into channel-voice messages.
    ///
    /// CoreMIDI hands over whatever the controller put in one packet, and the
    /// FLX4 packs a 14-bit control as two messages (`B0 13 7E B0 33 73` for the
    /// channel fader), repeats a status byte as running status, and interleaves
    /// realtime bytes. Treating an input as one three-byte message silently
    /// dropped every fader, trim, EQ and filter move.
    static func messages(in bytes: [UInt8]) -> [[UInt8]] {
        var messages: [[UInt8]] = []
        var status: UInt8?
        var data: [UInt8] = []
        var inSysEx = false

        func dataLength(for status: UInt8) -> Int {
            switch status & 0xf0 {
            case 0x80, 0x90, 0xa0, 0xb0, 0xe0: return 2
            case 0xc0, 0xd0: return 1
            default: return 0
            }
        }

        for byte in bytes {
            if byte >= 0xf8 { continue } // realtime: may sit between any two bytes
            if byte >= 0x80 {
                data.removeAll(keepingCapacity: true)
                if inSysEx, byte != 0xf0 {
                    // Any status byte ends a SysEx, terminated or not.
                    inSysEx = false
                    if byte == 0xf7 {
                        status = nil
                        continue
                    }
                }
                if byte == 0xf0 {
                    inSysEx = true
                    status = nil
                    continue
                }
                if byte >= 0xf0 {
                    status = nil
                    continue
                }
                status = byte
                continue
            }
            if inSysEx { continue }
            guard let status, dataLength(for: status) > 0 else { continue }
            data.append(byte)
            if data.count == dataLength(for: status) {
                messages.append([status] + data)
                data.removeAll(keepingCapacity: true) // running status keeps `status`
            }
        }
        return messages
    }

    public func handle(midi bytes: [UInt8], now: Date = Date()) -> [EngineEffect] {
        if case .waiting(let filter) = learnState, filter != .serial {
            if let learned = learn(from: bytes) {
                learnState = .learned(learned)
                return [.learned(learned)]
            }
        }
        var effects: [EngineEffect] = []
        for message in FLX4Engine.messages(in: bytes) {
            let kind = message[0] & 0xf0
            let channel = message[0] & 0x0f
            switch kind {
            case 0xb0:
                effects.append(contentsOf: controlChange(channel: channel, number: message[1],
                                                         value: message[2], now: now))
            case 0x90, 0x80:
                effects.append(contentsOf: note(channel: channel, number: message[1],
                                                value: message[2], on: kind == 0x90, now: now))
            default:
                break
            }
        }
        return effects
    }

    private func learn(from bytes: [UInt8]) -> LearnedControl? {
        for message in FLX4Engine.messages(in: bytes) {
            let kind = message[0] & 0xf0
            let channel = message[0] & 0x0f
            if kind == 0x90, message[2] > 0 {
                let canonical = FLX4Mapping.physicalKey(channel: channel, note: message[1])
                return LearnedControl(source: .midiNote, channel: Int(canonical.0), number: Int(canonical.1),
                                      label: "Note \(canonical.1) · CH \(Int(canonical.0) + 1)")
            }
            if kind == 0xb0 {
                let raw = Int(message[1])
                let hasFourteenBitRule = raw >= 32 && FLX4Mapping.analog.contains {
                    $0.channel == channel && $0.cc == UInt8(raw - 32)
                }
                let number = hasFourteenBitRule ? raw - 32 : raw
                return LearnedControl(source: .midiCC, channel: Int(channel), number: number,
                                      label: "CC \(number) · CH \(Int(channel) + 1)")
            }
        }
        return nil
    }

    private func note(channel: UInt8, number: UInt8, value: UInt8, on: Bool, now: Date) -> [EngineEffect] {
        let canonical = FLX4Mapping.physicalKey(channel: channel, note: number)
        let key = NoteKey(channel: canonical.0, note: canonical.1)
        let isOn = on && value > 0

        if let mapping = mappingByNote["\(canonical.0):\(canonical.1)"], mapping.enabled {
            let wasPressed = pressed.contains(key)
            if isOn {
                pressed.insert(key)
            } else {
                pressed.remove(key)
            }
            if !isOn && !wasPressed { return [] }
            return applyNote(mapping, pressed: isOn, velocity: value, now: now)
        }

        // A controller without the FLX4 preset must never inherit its transport
        // or mixer bindings by sharing a channel and note number.
        guard flx4PresetEnabled else { return [] }

        if channel <= 1 && canonical.1 == 0x3f && !isOn {
            var effects = shift(side: Int(channel), on: false)
            effects.append(contentsOf: release(key))
            return effects
        }
        if !isOn {
            return release(key)
        }
        guard pressed.insert(key).inserted else { return [] }

        if channel <= 1 || channel == 6 {
            return button(key: key, channel: channel, raw: number, now: now)
        }
        if let index = FLX4Mapping.padChannels.firstIndex(of: channel) {
            guard number & 0x0f < 8 else { return [] }
            let side = index / 2
            let deck = selected[side]
            let shifted = index % 2 != 0
            guard let action = FLX4Mapping.pads[banks[deck]].action(player: players[deck], pad: Int(number & 0x0f), shifted: shifted) else {
                return []
            }
            return press(key: key, action: action, deck: deck)
        }
        return []
    }

    private func applyNote(_ mapping: ControlMapping, pressed: Bool, velocity: UInt8, now: Date) -> [EngineEffect] {
        switch mapping.mode {
        case .trigger:
            return pressed ? emit(mapping, [.int(1)]) : []
        case .momentary, .passthrough:
            return emit(mapping, [.int(pressed ? 1 : 0)])
        case .toggle:
            return pressed ? toggleMapping(mapping, now: now) : []
        case .relative:
            return pressed ? emit(mapping, [.int(1)]) : []
        case .absolute, .bipolar:
            let value = Double(velocity) / 127.0
            return emitContinuous(mapping, value: mapping.mode == .bipolar ? value * 2 - 1 : value)
        }
    }

    private func mappingForCC(channel: UInt8, number: UInt8) -> (ControlMapping, fourteenBit: Bool)? {
        if let mapping = mappingByCC["\(channel):\(number)"] {
            // A learned override on an FLX4 14-bit control waits for its LSB,
            // exactly like the stock fader path. Other CCs are 7-bit by default.
            let stockFourteenBit = FLX4Mapping.analog.contains {
                $0.channel == channel && $0.cc == number
            }
            return (mapping, stockFourteenBit)
        }
        if number >= 32, let mapping = mappingByCC["\(channel):\(number - 32)"] {
            return (mapping, true)
        }
        return nil
    }

    private func learnedCC(_ mapping: ControlMapping, channel: UInt8, number: UInt8,
                           value: UInt8, fourteenBit: Bool, now: Date) -> [EngineEffect] {
        let key = CCKey(channel: channel, cc: number < 32 ? number : number - 32)
        var normalized = Double(value) / 127.0
        var relative = Int32(value < 64 ? Int(value) : Int(value) - 128)

        if fourteenBit {
            if number < 32 {
                msb[key] = value
                return [] // wait for the LSB half of the FLX4's packed fader update
            }
            if let high = msb[key] {
                let full = UInt16(high) << 7 | UInt16(value)
                if let previous = positions.updateValue(full, forKey: key) {
                    relative = Int32(Int(full) - Int(previous))
                } else {
                    relative = 0
                }
                normalized = Double(full) / 16383.0
            } else {
                positions[key] = UInt16(value)
            }
        }

        switch mapping.mode {
        case .trigger:
            if value > 0 {
                guard ccPressed.insert(key).inserted else { return [] }
                return emit(mapping, [.int(1)])
            }
            ccPressed.remove(key)
            return []
        case .momentary:
            if value > 0 {
                guard ccPressed.insert(key).inserted else { return [] }
                return emit(mapping, [.int(1)])
            }
            if ccPressed.remove(key) != nil {
                return emit(mapping, [.int(0)])
            }
            return []
        case .toggle:
            guard value > 0 else { return [] }
            return toggleMapping(mapping, now: now)
        case .relative:
            guard relative != 0 else { return [] }
            return emit(mapping, [.int(relative)])
        case .absolute, .bipolar:
            return emitContinuous(mapping, value: mapping.mode == .bipolar ? normalized * 2 - 1 : normalized)
        case .passthrough:
            return emit(mapping, [.int(Int32(value))])
        }
    }

    private func button(key: NoteKey, channel: UInt8, raw: UInt8, now: Date) -> [EngineEffect] {
        guard let rule = FLX4Mapping.buttons.first(where: { $0.channel == channel && $0.note == raw }) else {
            return warnOnce("DDJ-FLX4 note \(raw) on channel \(channel) has no Syndicate route; ignored")
        }
        let side = rule.side
        let deck = selected[side]
        switch rule.behavior {
        case .action(let action):
            return press(key: key, action: action, deck: deck)
        case .toggle(let address):
            return toggle(address: FLX4Mapping.resolved(address, deck: deck), now: now)
        case .bank(let bank):
            banks[deck] = bank
            return modeFeedback(side)
        case .shift:
            return shift(side: side, on: true)
        case .selectDeck:
            return selectDeck(side: side)
        case .browse(let address):
            let target = routed(FLX4Mapping.resolved(address, deck: deck), deck: deck)
            guard let resolved = target.address else { return target.effects }
            return send(resolved, .int(1))
        }
    }

    private func release(_ key: NoteKey) -> [EngineEffect] {
        pressed.remove(key)
        guard let hold = held.removeValue(forKey: key) else { return [] }
        return releaseHold(owner: hold.owner)
    }

    private func controlChange(channel: UInt8, number: UInt8, value: UInt8, now: Date) -> [EngineEffect] {
        if let (mapping, fourteenBit) = mappingForCC(channel: channel, number: number) {
            return learnedCC(mapping, channel: channel, number: number, value: value, fourteenBit: fourteenBit, now: now)
        }
        guard flx4PresetEnabled else { return [] }
        let encoder = FLX4Mapping.browserEncoder
        if channel == encoder.channel && number == encoder.cc {
            if value == 0 || value == 64 { return [] }
            let delta = value < 64 ? Int(value) : Int(value) - 128
            guard delta != 0 else { return [] }
            let address = delta > 0 ? encoder.down : encoder.up
            return (0..<abs(delta)).flatMap { _ in send(address, .int(1)) }
        }
        guard number < 64 else { return [] }
        let base = number & 0x1f
        let key = CCKey(channel: channel, cc: base)
        if number < 32 {
            msb[key] = value
            return []
        }
        guard let high = msb[key] else { return [] }
        let full = UInt16(high) << 7 | UInt16(value)
        let previous = positions.updateValue(full, forKey: key)
        guard previous != full else { return [] }
        guard let rule = FLX4Mapping.analog.first(where: { $0.channel == channel && $0.cc == base }) else {
            return warnOnce("DDJ-FLX4 CC \(base) on channel \(channel) has no Syndicate route; ignored")
        }
        let side = rule.side
        let deck = selected[side]
        let route = shifts[side] ? (rule.shiftedAddress ?? rule.address) : rule.address
        let resolvedRoute = FLX4Mapping.resolved(route, deck: deck)
        let target = routed(resolvedRoute, deck: deck)
        guard let address = target.address else { return target.effects }
        let identity = CaptureKey(control: key, address: address.lowercased())
        let position = Double(full) / 16383.0
        let owner = "cc:\(channel):\(base)"

        if analogPickup {
            if !rule.direct && !controlOwned(owner, address) {
                captured.remove(identity)
            }
            if !rule.direct && controlPending(owner, address) {
                return warnOnce("Pickup waiting at \(address): another control wrote it; waiting for Syndicate feedback")
            }
            if !rule.direct && !captured.contains(identity) {
                guard let confirmed = values[address.lowercased()] else {
                    return warnOnce("Pickup blocked at \(address): enable OSC feedback for this route")
                }
                let previousPosition = Double(previous ?? full) / 16383.0
                let sameSide = (previousPosition - confirmed) * (position - confirmed) > 0
                if sameSide && abs(position - confirmed) > 2.0 / 16383.0 {
                    return []
                }
                captured.insert(identity)
            }
        }
        let output: Double
        if rule.bipolar {
            // FLX4 tempo faders are wired with + at the bottom of the travel,
            // like rekordbox: pushing the fader up slows the deck down.
            output = (full == 8191 || full == 8192) ? 0 : 1 - position * 2
        } else {
            output = position
        }
        controlWriters[address.lowercased()] = (owner, true)
        return send(address, .float(Float(output)))
    }

    private enum RouteResolution {
        case found(address: String, route: String)
        case unavailable(String)
        case invalid(String)
    }

    private func resolve(_ route: String, deck: Int) -> RouteResolution {
        guard route.hasPrefix("/Syndicate/Deck/") else { return .found(address: route, route: route) }
        let rest = route.dropFirst("/Syndicate/Deck/".count)
        guard let slash = rest.firstIndex(of: "/"), let number = Int(rest[..<slash]), number >= 1, number <= 4 else {
            return .invalid(route)
        }
        let subroute = String(rest[rest.index(after: slash)...])
        let player = players[number - 1]
        guard let translated = player.route(subroute) else {
            return .unavailable("Deck \(number) (\(player.rawValue)): \(subroute) unavailable; check PlayerType feedback")
        }
        return .found(address: "/Syndicate/Deck/\(number)/\(translated)", route: translated)
    }

    /// Resolve a deck route and hand back the warning to emit when this deck's
    /// player type cannot serve it. Without the effect the press would be dropped
    /// silently and the surface would look dead.
    private func routed(_ route: String, deck: Int) -> (address: String?, effects: [EngineEffect]) {
        switch resolve(route, deck: deck) {
        case .found(let address, _):
            return (address, [])
        case .unavailable(let message):
            return (nil, warnOnce(message))
        case .invalid(let address):
            return (nil, warnOnce("\(address): not a deck route"))
        }
    }

    @discardableResult
    private func warnOnce(_ message: String) -> [EngineEffect] {
        lastWarning = message
        guard warned.insert(message).inserted else { return [] }
        return [.log(.warn, message)]
    }
}

extension FLX4Engine {
    // MARK: - Actions

    private func send(_ address: String, _ argument: OSCArgument) -> [EngineEffect] {
        oscSent += 1
        return [.osc(OSCMessage(address, [argument]))]
    }

    private func press(key: NoteKey, action: FLXAction, deck: Int) -> [EngineEffect] {
        let resolved = action.resolved(deck: deck)
        let target = routed(resolved.address, deck: deck)
        guard let address = target.address else { return target.effects }
        var action = resolved
        action.address = address
        let owner = "note:\(key.channel):\(key.note)"

        if action.toggle {
            guard let deckKey = slipDeckKey(of: action.address),
                  let route = action.address.split(separator: "/").last.map(String.init) else { return [] }
            let timing: SlipTiming = route == "SlipDotted" ? .dotted : route == "SlipTriplet" ? .triplet : .straight
            return slipToggle(deckKey: deckKey, timing: timing)
        }
        if let release = action.release {
            guard !held.keys.contains(key) else { return [] }
            held[key] = Hold(owner: owner, address: action.address, press: action.press,
                             release: release, timing: action.slip)
            if let timing = action.slip, let deckKey = slipDeckKey(of: action.address) {
                return slipHold(owner: owner, address: action.address, deckKey: deckKey,
                                timing: timing, press: action.press, release: release)
            }
            return hold(owner: owner, address: action.address, press: action.press, release: release)
        }
        return send(action.address, .int(action.press))
    }

    private func hold(owner: String, address: String, press: Int32, release: Int32) -> [EngineEffect] {
        guard !holds.contains(where: { $0.owner == owner }) else { return [] }
        if holds.contains(where: { $0.address.caseInsensitiveCompare(address) == .orderedSame && $0.press != press }) {
            return [.log(.error, "Conflicting simultaneous held values for \(address)")]
        }
        let already = holds.contains { $0.address.caseInsensitiveCompare(address) == .orderedSame && $0.timing == nil }
        holds.append(Hold(owner: owner, address: address, press: press, release: release, timing: nil))
        return already ? [] : send(address, .int(press))
    }

    @discardableResult
    private func sendRelease(_ hold: Hold) -> [EngineEffect] {
        guard hold.timing == nil else { return [] }
        let stillHeld = holds.contains { $0.owner != hold.owner && $0.address.caseInsensitiveCompare(hold.address) == .orderedSame }
        return stillHeld ? [] : send(hold.address, .int(hold.release))
    }

    private func releaseHold(owner: String) -> [EngineEffect] {
        guard let index = holds.firstIndex(where: { $0.owner == owner }) else { return [] }
        if holds[index].timing != nil {
            return slipRelease(index: index)
        }
        let hold = holds.remove(at: index)
        return sendRelease(hold)
    }

    private func shift(side: Int, on: Bool) -> [EngineEffect] {
        guard shifts.indices.contains(side), shifts[side] != on else { return [] }
        shifts[side] = on
        rearm(analogKeys(side: side, shiftedOnly: true))
        return send("/Syndicate/Feedback/Resend", .int(1))
    }

    private func selectDeck(side: Int) -> [EngineEffect] {
        selected[side] ^= 2
        rearm(analogKeys(side: side, shiftedOnly: false))
        var effects = modeFeedback(side)
        effects.append(contentsOf: refreshLEDs(side))
        effects.append(contentsOf: send("/Syndicate/Feedback/Resend", .int(1)))
        return effects
    }

    private func modeFeedback(_ side: Int) -> [EngineEffect] {
        let note = FLX4Mapping.bankNotes[banks[selected[side]]]
        return [.midi([0x90 + UInt8(side), note, 127])]
    }

    private func analogKeys(side: Int, shiftedOnly: Bool) -> Set<CCKey> {
        var keys: Set<CCKey> = []
        for rule in FLX4Mapping.analog where rule.side == side {
            if shiftedOnly {
                if let shifted = rule.shiftedAddress, shifted != rule.address {
                    keys.insert(CCKey(channel: rule.channel, cc: rule.cc))
                }
            } else if rule.address.contains("{deck}")
                        || rule.shiftedAddress?.contains("{deck}") == true {
                keys.insert(CCKey(channel: rule.channel, cc: rule.cc))
            }
        }
        return keys
    }

    private func rearm(_ keys: Set<CCKey>) {
        for key in keys {
            msb.removeValue(forKey: key)
            positions.removeValue(forKey: key)
        }
        captured = captured.filter { !keys.contains($0.control) }
    }

    // MARK: - Toggles, slip timing, holds

    private func toggle(address: String, now: Date) -> [EngineEffect] {
        let key = address.lowercased()
        if let pending = pendingToggles[key] {
            if now.timeIntervalSince(pending.at) >= 1 {
                pendingToggles.removeValue(forKey: key)
                values.removeValue(forKey: key)
                return send("/Syndicate/Feedback/Resend", .int(1))
                    + warnOnce("\(address): toggle blocked waiting for Syndicate confirmation; enable its subscription and press again after feedback arrives.")
            }
            return warnOnce("\(address): toggle blocked; waiting for Syndicate confirmation of the last press.")
        }
        guard let current = values[key] else {
            return warnOnce("\(address): toggle blocked; no confirmed Syndicate switch feedback. Enable its subscription.")
        }
        let next: Int32 = current >= 0.5 ? 0 : 1
        pendingToggles[key] = (Double(next), now)
        return send(address, .int(next))
    }

    private func slipDeckKey(of address: String) -> String? {
        guard let range = address.range(of: "/SlipLoop/") ?? address.range(of: "/SlipDotted") ?? address.range(of: "/SlipTriplet") else {
            return nil
        }
        return String(address[..<range.lowerBound])
    }

    private func slipSelected(_ deckKey: String) -> SlipTiming {
        slipModes[deckKey.lowercased()] ?? .straight
    }

    private func timingEffects(deckKey: String, timing: SlipTiming) -> [EngineEffect] {
        let resolved = timing == .selected ? slipSelected(deckKey) : timing
        var effects = send("\(deckKey)/SlipDotted", .int(0))
        effects.append(contentsOf: send("\(deckKey)/SlipTriplet", .int(0)))
        switch resolved {
        case .dotted: effects.append(contentsOf: send("\(deckKey)/SlipDotted", .int(1)))
        case .triplet: effects.append(contentsOf: send("\(deckKey)/SlipTriplet", .int(1)))
        default: break
        }
        return effects
    }

    private func activeSlip(deckKey: String) -> Int? {
        holds.lastIndex { hold in
            guard hold.timing != nil, let key = slipDeckKey(of: hold.address) else { return false }
            return key.caseInsensitiveCompare(deckKey) == .orderedSame
        }
    }

    private func slipSelect(deckKey: String, timing: SlipTiming) -> [EngineEffect] {
        guard timing != .selected else { return [.log(.error, "Selected is a slip policy, not a timing")] }
        slipModes[deckKey.lowercased()] = timing
        if let index = activeSlip(deckKey: deckKey), holds[index].timing == .selected {
            let active = holds[index]
            var effects = send(active.address, .int(active.release))
            effects.append(contentsOf: timingEffects(deckKey: deckKey, timing: timing))
            effects.append(contentsOf: send(active.address, .int(active.press)))
            return effects
        }
        return timingEffects(deckKey: deckKey, timing: timing)
    }

    private func slipToggle(deckKey: String, timing: SlipTiming) -> [EngineEffect] {
        let next: SlipTiming = slipSelected(deckKey) == timing ? .straight : timing
        return slipSelect(deckKey: deckKey, timing: next)
    }

    private func slipHold(owner: String, address: String, deckKey: String, timing: SlipTiming,
                          press: Int32, release: Int32) -> [EngineEffect] {
        guard !holds.contains(where: { $0.owner == owner }) else { return [] }
        let previous = activeSlip(deckKey: deckKey).map { holds[$0] }
        holds.append(Hold(owner: owner, address: address, press: press, release: release, timing: timing))
        if slipModes[deckKey.lowercased()] == nil {
            slipModes[deckKey.lowercased()] = .straight
        }
        var effects: [EngineEffect] = []
        if let previous {
            effects.append(contentsOf: send(previous.address, .int(previous.release)))
        }
        effects.append(contentsOf: timingEffects(deckKey: deckKey, timing: timing))
        effects.append(contentsOf: send(address, .int(press)))
        return effects
    }

    private func slipRelease(index: Int) -> [EngineEffect] {
        let hold = holds[index]
        guard let deckKey = slipDeckKey(of: hold.address) else {
            holds.remove(at: index)
            return []
        }
        var effects: [EngineEffect] = []
        if let active = activeSlip(deckKey: deckKey), holds[active].owner == hold.owner {
            effects.append(contentsOf: send(hold.address, .int(hold.release)))
            if let previous = holds[..<index].last(where: {
                $0.timing != nil && slipDeckKey(of: $0.address)?.caseInsensitiveCompare(deckKey) == .orderedSame
            }), let timing = previous.timing {
                effects.append(contentsOf: timingEffects(deckKey: deckKey, timing: timing))
                effects.append(contentsOf: send(previous.address, .int(previous.press)))
            } else {
                effects.append(contentsOf: timingEffects(deckKey: deckKey, timing: .selected))
            }
        }
        holds.remove(at: index)
        return effects
    }

    // MARK: - LEDs and feedback

    private func ledEffect(status: UInt8, number: UInt8, value: UInt8) -> [EngineEffect] {
        let key = "\(status):\(number)"
        guard ledsSent[key] != value else { return [] }
        ledsSent[key] = value
        return [.midi([status, number, value])]
    }

    private func refreshLEDs(_ side: Int) -> [EngineEffect] {
        let deck = selected[side]
        var effects: [EngineEffect] = []
        for rule in FLX4Mapping.leds where rule.channel == UInt8(side) {
            let address = FLX4Mapping.resolved(rule.address, deck: deck).lowercased()
            let value = values[address]
            let (status, code): (UInt8, UInt8)
            switch rule.kind {
            case .switchLED:
                status = 0x90 + UInt8(side)
                code = (value ?? 0) >= 0.5 ? rule.on : rule.off
            case .meter:
                status = 0xb0 + UInt8(side)
                let level = min(max(value ?? 0, 0), 1)
                code = UInt8((level * 127).rounded())
            }
            effects.append(contentsOf: ledEffect(status: status, number: rule.number, value: code))
        }
        return effects
    }

    private func controlOwned(_ owner: String, _ address: String) -> Bool {
        guard let writer = controlWriters[address.lowercased()] else { return true }
        return writer.owner == owner
    }

    private func controlPending(_ owner: String, _ address: String) -> Bool {
        guard let writer = controlWriters[address.lowercased()] else { return false }
        return writer.owner != owner && writer.pending
    }

    private func writer(for control: CCKey) -> String {
        "cc:\(control.channel):\(control.cc)"
    }

    /// Feed one Syndicate OSC packet. Returns LED updates for the hardware.
    public func handle(packet: OSCPacket) -> [EngineEffect] {
        var changed: [String] = []
        var effects: [EngineEffect] = []
        for message in packet.messages {
            accept(message, changed: &changed, effects: &effects)
        }
        guard !changed.isEmpty else { return effects }
        lastFeedback = Date()

        for address in changed where address.hasPrefix("/syndicate/deck/") && address.hasSuffix("/playertype") {
            let parts = address.split(separator: "/")
            guard parts.count >= 4, let deck = Int(parts[2]), deck >= 1, deck <= 4 else { continue }
            let player = PlayerType(feedback: texts[address] ?? "")
            if players[deck - 1] != player {
                players[deck - 1] = player
                let tempo = "/syndicate/deck/\(deck)/temposlider"
                captured = captured.filter { $0.address != tempo }
            }
        }
        let batch = Set(changed)
        captured = captured.filter { capture in
            guard batch.contains(capture.address) else { return true }
            return values[capture.address] != nil && controlOwned(writer(for: capture.control), capture.address)
        }
        effects.append(contentsOf: refreshLEDs(0))
        effects.append(contentsOf: refreshLEDs(1))
        return effects
    }

    /// Syndicate builds differ in the OSC namespace they publish feedback on:
    /// current builds send "/Syndicate/...", pre-rename ones "/AutoPilot/...",
    /// and the app accepts commands under either. Fold both into one key space
    /// so feedback from the running app is matched either way.
    public static func canonical(_ address: String) -> String {
        let lower = address.lowercased()
        let legacy = "/autopilot/"
        guard lower.hasPrefix(legacy) else { return lower }
        return "/syndicate/" + lower.dropFirst(legacy.count)
    }

    private func accept(_ message: OSCMessage, changed: inout [String], effects: inout [EngineEffect]) {
        let key = FLX4Engine.canonical(message.address)
        if !message.arguments.isEmpty {
            observed[key] = message.arguments
        }
        guard let scale = scales[key] else { return }
        let valid: Bool
        switch scale {
        case .text:
            if let text = message.firstString, text.count <= 128,
               !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                texts[key] = text
                valid = true
            } else {
                valid = false
            }
        default:
            // Syndicate publishes switch and meter feedback as int as well as float.
            let raw: Double?
            if let value = message.firstFloat, value.isFinite {
                raw = Double(value)
            } else if let value = message.firstInt {
                raw = Double(value)
            } else {
                raw = nil
            }
            let accepted: Double?
            if let raw, raw.isFinite {
                switch scale {
                case .bipolar: accepted = (-1.0...1.0).contains(raw) ? (raw + 1) * 0.5 : nil
                case .switchLED: accepted = (raw == 0 || raw == 1) ? raw : nil
                case .meter: accepted = raw
                default: accepted = (0.0...1.0).contains(raw) ? raw : nil
                }
            } else {
                accepted = nil
            }
            if let accepted {
                values[key] = accepted
                if let pending = pendingToggles[key], abs(pending.expected - accepted) < 0.001 {
                    pendingToggles.removeValue(forKey: key)
                }
                valid = true
            } else {
                valid = false
            }
        }

        if var writer = controlWriters[key] {
            writer.pending = false
            controlWriters[key] = writer
        }
        if valid {
            feedbackAccepted += 1
        } else {
            values.removeValue(forKey: key)
            texts.removeValue(forKey: key)
            effects.append(contentsOf: warnOnce("Invalid Syndicate feedback for \(message.address); dependent controls blocked/re-armed"))
        }
        if !changed.contains(key) { changed.append(key) }
    }

    // MARK: - Snapshot

    public func snapshot() -> SurfaceSnapshot {
        var snapshot = SurfaceSnapshot()
        snapshot.selectedDecks = selected
        snapshot.players = players
        snapshot.shifted = shifts
        snapshot.bankNames = (0..<2).map {
            FLX4Mapping.pads[banks[selected[$0]]].name(for: players[selected[$0]])
        }
        snapshot.padLabels = (0..<2).map { side in
            let deck = selected[side]
            let bank = FLX4Mapping.pads[banks[deck]]
            return (0..<8).map { pad in
                bank.action(player: players[deck], pad: pad, shifted: shifts[side]).map(FLX4Mapping.padLabel) ?? "--"
            }
        }
        snapshot.slipTiming = Dictionary(uniqueKeysWithValues: slipModes.compactMap { key, timing in
            guard let deck = Int(key.split(separator: "/").last ?? "") else { return nil }
            return (deck, timing)
        })
        snapshot.pressed = Set(pressed.map { ControlID(kind: .note, channel: $0.channel, number: $0.note) })
        snapshot.held = Set(held.keys.map { ControlID(kind: .note, channel: $0.channel, number: $0.note) })
        snapshot.pickupEnabled = analogPickup
        var pickup: [ControlID: Bool] = [:]
        if analogPickup {
            for control in positions.keys {
                let id = ControlID(kind: .cc, channel: control.channel, number: control.cc)
                pickup[id] = captured.contains { $0.control == control }
            }
        }
        snapshot.pickup = pickup
        snapshot.values = values
        return snapshot
    }
}
