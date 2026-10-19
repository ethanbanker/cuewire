import Foundation

/// AUTO/PILOT player type reported by `/AutoPilot/Deck/D/PlayerType`.
public enum PlayerType: String, CaseIterable, Sendable {
    case track, arrangement, clip, sampler, empty, unknown

    public init(feedback: String) {
        self = PlayerType(rawValue: feedback.lowercased()) ?? .unknown
    }

    public var label: String { rawValue.capitalized }

    /// Routes are only translated for players that document them; no guessed aliases.
    public func route(_ route: String) -> String? {
        switch self {
        case .track:
            if route == "ControlPagePrevious" || route == "ControlPageNext" { return nil }
            if route.hasPrefix("Sampler/") || route.hasPrefix("Clip/") { return nil }
            return route
        case .arrangement:
            if route.hasPrefix("Sampler/") || route.hasPrefix("Clip/") { return nil }
            return route
        case .clip:
            let direct = ["PlayPause", "Cue", "GridStart",
                          "Cue1", "Cue2", "Cue3", "Cue4", "Cue5", "Cue6", "Cue7", "Cue8",
                          "PitchDown", "PitchReset", "PitchUp", "PitchStep",
                          "PhaseMinus", "PhasePlus", "PhaseBend", "PhaseReset"]
            if direct.contains(route) { return "Clip/\(route)" }
            if route.hasPrefix("Clip/") { return route }
            return nil
        case .sampler:
            let direct = ["PlayPause", "PhaseBend", "PhaseReset", "Speed", "Quantize", "FaderStart"]
            if direct.contains(route) { return "Sampler/\(route)" }
            if route.hasPrefix("Sampler/") { return route }
            return nil
        case .empty, .unknown:
            return nil
        }
    }
}

public enum SlipTiming: String, Sendable {
    case straight, dotted, triplet, selected
}

/// An FLX4 action as written in the original profile: an OSC route plus press/release values.
public struct FLXAction: Sendable {
    public var address: String
    public var press: Int32
    public var release: Int32?
    /// Slip-loop pads latch timing for the duration of the hold.
    public var slip: SlipTiming?
    /// SlipDotted/SlipTriplet pads toggle the deck's latched timing instead of holding.
    public var toggle: Bool

    public init(_ address: String, press: Int32 = 1, release: Int32? = nil, slip: SlipTiming? = nil, toggle: Bool = false) {
        self.address = address
        self.press = press
        self.release = release
        self.slip = slip
        self.toggle = toggle
    }

    public func resolved(deck: Int) -> FLXAction {
        var copy = self
        copy.address = address.replacingOccurrences(of: "{deck}", with: String(deck + 1))
        return copy
    }
}

public enum ButtonBehavior: Sendable {
    case action(FLXAction)
    case toggle(address: String)
    case bank(Int)
    case shift
    case selectDeck
    case browse(address: String)
}

public struct ButtonRule: Sendable {
    public var channel: UInt8
    public var note: UInt8
    public var side: Int
    public var behavior: ButtonBehavior

    public init(channel: UInt8, note: UInt8, side: Int, behavior: ButtonBehavior) {
        self.channel = channel
        self.note = note
        self.side = side
        self.behavior = behavior
    }
}

public struct AnalogRule: Sendable {
    public var channel: UInt8
    public var cc: UInt8
    public var side: Int
    public var address: String
    public var shiftedAddress: String?
    public var bipolar: Bool
    public var direct: Bool
    /// The FLX4 filter knob is one physical control: centre is neutral, left is
    /// low-pass and right is high-pass. When true, `address` is low-pass and
    /// `shiftedAddress` is high-pass, and the engine sends a centre-split pair
    /// instead of forwarding the raw 0…1 knob position.
    public var oneKnobFilter: Bool

    public init(channel: UInt8, cc: UInt8, side: Int, address: String,
                shiftedAddress: String?, bipolar: Bool, direct: Bool,
                oneKnobFilter: Bool = false) {
        self.channel = channel
        self.cc = cc
        self.side = side
        self.address = address
        self.shiftedAddress = shiftedAddress
        self.bipolar = bipolar
        self.direct = direct
        self.oneKnobFilter = oneKnobFilter
    }
}

public enum LEDKind: Sendable {
    case switchLED
    case meter
}

public struct LEDRule: Sendable {
    public var address: String
    public var channel: UInt8
    public var kind: LEDKind
    public var number: UInt8
    public var on: UInt8
    public var off: UInt8
}

public struct PadLayout: Sendable {
    public var name: String
    public var pads: [FLXAction?]
    public var shiftedPads: [FLXAction?]?

    public init(name: String, pads: [FLXAction?], shiftedPads: [FLXAction?]? = nil) {
        self.name = name
        self.pads = pads
        self.shiftedPads = shiftedPads
    }
}

public struct PadBank: Sendable {
    public var name: String
    public var pads: [FLXAction?]
    public var shiftedPads: [FLXAction?]?
    public var forPlayer: [PlayerType: PadLayout]

    public init(name: String, pads: [FLXAction?], shiftedPads: [FLXAction?]? = nil, forPlayer: [PlayerType: PadLayout] = [:]) {
        self.name = name
        self.pads = pads
        self.shiftedPads = shiftedPads
        self.forPlayer = forPlayer
    }

    public func name(for player: PlayerType) -> String {
        forPlayer[player]?.name ?? name
    }

    public func action(player: PlayerType, pad: Int, shifted: Bool) -> FLXAction? {
        let layout = forPlayer[player]
        let pads = layout?.pads ?? self.pads
        let shiftedPads = layout?.shiftedPads ?? self.shiftedPads
        guard pad >= 0, pad < pads.count else { return nil }
        if shifted, let shiftedPads, shiftedPads.indices.contains(pad) {
            return shiftedPads[pad]
        }
        return pads[pad]
    }
}

/// The complete DDJ-FLX4 -> AUTO/PILOT binding set, ported from `profiles/flx4.json`
/// plus the FLX4 protocol quirks implemented by the original adapter.
public enum FLX4Mapping {
    public static let inputNameMatch = "DDJ-FLX4"
    public static let bankNotes: [UInt8] = [27, 30, 32, 34, 105, 107, 109, 111]
    /// FLX4 needs this vendor SysEx periodically or its controls stop reporting.
    public static let keepalive: [UInt8] = [0xf0, 0x00, 0x40, 0x05, 0x00, 0x00, 0x04, 0x05, 0x00, 0x50, 0x02, 0xf7]
    public static let padChannels: [UInt8] = [7, 8, 9, 10]

    public static let browserEncoder = (channel: UInt8(6), cc: UInt8(64),
                                        up: "/AutoPilot/Browser/Up",
                                        down: "/AutoPilot/Browser/Down")

    public static func resolved(_ route: String, deck: Int) -> String {
        route.replacingOccurrences(of: "{deck}", with: String(deck + 1))
    }

    /// Hardware pads report on two channels per side; both alias one physical pad.
    public static func physicalKey(channel: UInt8, note: UInt8) -> (UInt8, UInt8) {
        if channel <= 1 {
            switch note {
            case 0x0e: return (channel, 0x0b)
            case 0x48: return (channel, 0x0c)
            case 0x4c: return (channel, 0x10)
            case 0x4e: return (channel, 0x11)
            case 0x50: return (channel, 0x4d)
            case 0x5c, 0x60: return (channel, 0x58)
            case 0x68: return (channel, 0x54)
            case 0x69: return (channel, 0x1b)
            case 0x6b: return (channel, 0x1e)
            case 0x6d: return (channel, 0x20)
            case 0x6f: return (channel, 0x22)
            default: break
            }
        }
        if channel == 6 {
            switch note {
            case 0x68: return (6, 0x46)
            case 0x7a: return (6, 0x47)
            case 0x42: return (6, 0x41)
            default: break
            }
        }
        if channel >= 7 && channel <= 10 {
            return (7 + ((channel - 7) / 2) * 2, note & 0x0f)
        }
        return (channel, note)
    }

    public static let buttons: [ButtonRule] = {
        var rules: [ButtonRule] = []
        for channel in [UInt8(0), 1] {
            let side = Int(channel)
            rules.append(ButtonRule(channel: channel, note: 63, side: side, behavior: .shift))
            for (bank, note) in bankNotes.enumerated() {
                rules.append(ButtonRule(channel: channel, note: note, side: side, behavior: .bank(bank)))
            }
            rules.append(ButtonRule(channel: channel, note: 84, side: side,
                                    behavior: .toggle(address: "/AutoPilot/Mixer/CH{deck}/Cue")))
            let actions: [(UInt8, FLXAction)] = [
                (11, FLXAction("/AutoPilot/Deck/{deck}/PlayPause")),
                (12, FLXAction("/AutoPilot/Deck/{deck}/Cue", release: 0)),
                (72, FLXAction("/AutoPilot/Deck/{deck}/GridStart")),
                (16, FLXAction("/AutoPilot/Deck/{deck}/LoopIn")),
                (17, FLXAction("/AutoPilot/Deck/{deck}/LoopOut")),
                (77, FLXAction("/AutoPilot/Deck/{deck}/Loop")),
                (88, FLXAction("/AutoPilot/Deck/{deck}/TempoSync")),
                (92, FLXAction("/AutoPilot/Deck/{deck}/TempoMaster")),
            ]
            for (note, action) in actions {
                rules.append(ButtonRule(channel: channel, note: note, side: side, behavior: .action(action)))
            }
        }
        rules.append(ButtonRule(channel: 6, note: 104, side: 0, behavior: .selectDeck))
        rules.append(ButtonRule(channel: 6, note: 122, side: 1, behavior: .selectDeck))
        rules.append(ButtonRule(channel: 6, note: 70, side: 0,
                                behavior: .browse(address: "/AutoPilot/Browser/L{deck}")))
        rules.append(ButtonRule(channel: 6, note: 71, side: 1,
                                behavior: .browse(address: "/AutoPilot/Browser/L{deck}")))
        rules.append(ButtonRule(channel: 6, note: 65, side: 0,
                                behavior: .browse(address: "/AutoPilot/Browser/Enter")))
        rules.append(ButtonRule(channel: 6, note: 66, side: 0,
                                behavior: .browse(address: "/AutoPilot/Browser/Back")))
        return rules
    }()

    public static let analog: [AnalogRule] = [
        AnalogRule(channel: 0, cc: 0, side: 0, address: "/AutoPilot/Deck/{deck}/TempoSlider",
                   shiftedAddress: nil, bipolar: true, direct: false),
        AnalogRule(channel: 1, cc: 0, side: 1, address: "/AutoPilot/Deck/{deck}/TempoSlider",
                   shiftedAddress: nil, bipolar: true, direct: false),
        AnalogRule(channel: 0, cc: 19, side: 0, address: "/AutoPilot/Mixer/CH{deck}/Volume",
                   shiftedAddress: nil, bipolar: false, direct: false),
        AnalogRule(channel: 1, cc: 19, side: 1, address: "/AutoPilot/Mixer/CH{deck}/Volume",
                   shiftedAddress: nil, bipolar: false, direct: false),
        AnalogRule(channel: 0, cc: 4, side: 0, address: "/AutoPilot/Mixer/CH{deck}/Trim",
                   shiftedAddress: nil, bipolar: false, direct: false),
        AnalogRule(channel: 1, cc: 4, side: 1, address: "/AutoPilot/Mixer/CH{deck}/Trim",
                   shiftedAddress: nil, bipolar: false, direct: false),
        AnalogRule(channel: 0, cc: 7, side: 0, address: "/AutoPilot/Mixer/CH{deck}/EQ/High",
                   shiftedAddress: nil, bipolar: false, direct: false),
        AnalogRule(channel: 1, cc: 7, side: 1, address: "/AutoPilot/Mixer/CH{deck}/EQ/High",
                   shiftedAddress: nil, bipolar: false, direct: false),
        AnalogRule(channel: 0, cc: 11, side: 0, address: "/AutoPilot/Mixer/CH{deck}/EQ/Mid",
                   shiftedAddress: nil, bipolar: false, direct: false),
        AnalogRule(channel: 1, cc: 11, side: 1, address: "/AutoPilot/Mixer/CH{deck}/EQ/Mid",
                   shiftedAddress: nil, bipolar: false, direct: false),
        AnalogRule(channel: 0, cc: 15, side: 0, address: "/AutoPilot/Mixer/CH{deck}/EQ/Low",
                   shiftedAddress: nil, bipolar: false, direct: false),
        AnalogRule(channel: 1, cc: 15, side: 1, address: "/AutoPilot/Mixer/CH{deck}/EQ/Low",
                   shiftedAddress: nil, bipolar: false, direct: false),
        // One physical knob, like rekordbox: centre is neutral, the left half
        // drives AUTO/PILOT's low-pass (Filter1) and the right half its
        // high-pass (Filter2). Shift keeps the old direct Filter2 control.
        AnalogRule(channel: 6, cc: 23, side: 0, address: "/AutoPilot/Mixer/CH{deck}/Filter1",
                   shiftedAddress: "/AutoPilot/Mixer/CH{deck}/Filter2", bipolar: false, direct: false,
                   oneKnobFilter: true),
        AnalogRule(channel: 6, cc: 24, side: 1, address: "/AutoPilot/Mixer/CH{deck}/Filter1",
                   shiftedAddress: "/AutoPilot/Mixer/CH{deck}/Filter2", bipolar: false, direct: false,
                   oneKnobFilter: true),
        // Master level, headphone level and headphone cue/master mix live in the
        // header and are shared, so they carry no {deck}. Only the mix knob is
        // driven direct: AUTO/PILOT publishes no feedback for Header/CueMix, so a
        // pickup gate could never open.
        AnalogRule(channel: 6, cc: 8, side: 0, address: "/AutoPilot/Header/MasterVolume",
                   shiftedAddress: nil, bipolar: false, direct: false),
        AnalogRule(channel: 6, cc: 13, side: 0, address: "/AutoPilot/Header/CueVolume",
                   shiftedAddress: nil, bipolar: false, direct: false),
        AnalogRule(channel: 6, cc: 12, side: 0, address: "/AutoPilot/Header/CueMix",
                   shiftedAddress: nil, bipolar: false, direct: true),
    ]

    public static let leds: [LEDRule] = {
        var rules: [LEDRule] = []
        for channel in [UInt8(0), 1] {
            rules.append(LEDRule(address: "/AutoPilot/Deck/{deck}/Playing", channel: channel,
                                 kind: .switchLED, number: 11, on: 127, off: 0))
            rules.append(LEDRule(address: "/AutoPilot/Deck/{deck}/Sync", channel: channel,
                                 kind: .switchLED, number: 88, on: 127, off: 0))
            rules.append(LEDRule(address: "/AutoPilot/Deck/{deck}/Loop", channel: channel,
                                 kind: .switchLED, number: 77, on: 127, off: 0))
            rules.append(LEDRule(address: "/AutoPilot/Mixer/CH{deck}/Cue", channel: channel,
                                 kind: .switchLED, number: 84, on: 127, off: 0))
            rules.append(LEDRule(address: "/AutoPilot/Mixer/CH{deck}/Meter", channel: channel,
                                 kind: .meter, number: 2, on: 127, off: 0))
        }
        return rules
    }()
}

extension FLX4Mapping {
    /// Pad banks in hardware order (Bank 0-7 = the eight pad-mode buttons).
    public static let pads: [PadBank] = {
        func action(_ route: String, _ press: Int32 = 1, release: Int32? = nil,
                    slip: SlipTiming? = nil, toggle: Bool = false) -> FLXAction? {
            FLXAction("/AutoPilot/Deck/{deck}/\(route)", press: press, release: release, slip: slip, toggle: toggle)
        }
        func bank(_ name: String, _ pads: [FLXAction?], shifted: [FLXAction?]? = nil,
                  forPlayer: [PlayerType: PadLayout] = [:]) -> PadBank {
            PadBank(name: name, pads: pads, shiftedPads: shifted, forPlayer: forPlayer)
        }

        let hotCues = bank("Hot cues", (1...8).map { action("Cue\($0)") },
                           shifted: (0..<8).map { _ in nil },
                           forPlayer: [.arrangement: PadLayout(
                               name: "Markers / pages",
                               pads: [action("Cue1"), action("Cue2"), action("Cue3"), action("Cue4"), action("Cue5"),
                                      action("GridStart"), action("ControlPagePrevious"), action("ControlPageNext")],
                               shiftedPads: (0..<8).map { _ in nil })])

        let slipLoops = bank("Slip loops", [
            action("SlipLoop/ThirtySecond", release: 0, slip: .selected),
            action("SlipLoop/Sixteenth", release: 0, slip: .selected),
            action("SlipLoop/Eighth", release: 0, slip: .selected),
            action("SlipLoop/Quarter", release: 0, slip: .selected),
            action("SlipLoop/Half", release: 0, slip: .selected),
            nil,
            action("SlipDotted", toggle: true),
            action("SlipTriplet", toggle: true),
        ])

        let beatJumps = bank("Beat jumps", [
            action("BeatSkip", -1), action("BeatSkip", 1),
            action("BeatSkip", -2), action("BeatSkip", 2),
            action("BeatSkip", -4), action("BeatSkip", 4),
            action("BeatSkip", -8), action("BeatSkip", 8),
        ], shifted: [
            action("BeatSkip", -16), action("BeatSkip", 16),
            action("BeatSkip", -32), action("BeatSkip", 32),
            action("BeatSkip", -64), action("BeatSkip", 64),
            action("BeatSkip", -128), action("BeatSkip", 128),
        ])

        let samplerLanes = bank("Sampler lanes", (0...7).map { action("Sampler/Lane", Int32($0)) })

        let pitch = bank("Pitch / formant", [
            action("PitchStep", -12), action("PitchStep", -1),
            action("PitchStep", 1), action("PitchStep", 12),
            action("PitchReset", 1), action("FormantDown", 1),
            action("FormantReset", 1), action("FormantUp", 1),
        ])

        let loopTools = bank("Loop tools", [
            action("LoopMoveBeat", -1), action("LoopMoveBeat", 1),
            action("LoopMoveBar", -1), action("LoopMoveBar", 1),
            action("LoopMoveBar", -4), action("LoopMoveBar", 4),
            action("LoopIn", 1), action("LoopOut", 1),
        ])

        let deckTools = bank("Deck tools", [
            action("SpeedHalf", release: 0), action("SpeedDouble", release: 0),
            action("Reverse", release: 0), action("GridStart", 1),
            action("PhaseMinus", release: 0), action("PhasePlus", release: 0),
            action("PhaseReset", 1), action("Speed", 1),
        ], forPlayer: [.sampler: PadLayout(
            name: "Steps 1-8 (Shift clears)",
            pads: (1...8).map { action("Sampler/Step\($0)/Enabled", 1) },
            shiftedPads: (1...8).map { action("Sampler/Step\($0)/Enabled", 0) })])

        let navigation = bank("Navigation / locks", [
            action("WaveformZoomOut", 1), action("WaveformZoomIn", 1),
            action("ControlPagePrevious", 1), action("ControlPageNext", 1),
            action("CueSlip", 1), action("CueSlip", 0),
            action("PitchPreserve", 1), action("PitchPreserve", 0),
        ], forPlayer: [.sampler: PadLayout(
            name: "Steps 9-16 (Shift clears)",
            pads: (9...16).map { action("Sampler/Step\($0)/Enabled", 1) },
            shiftedPads: (9...16).map { action("Sampler/Step\($0)/Enabled", 0) })])

        return [hotCues, slipLoops, beatJumps, samplerLanes, pitch, loopTools, deckTools, navigation]
    }()

    /// Short pad captions for the on-screen surface.
    public static func padLabel(_ action: FLXAction) -> String {
        let route = action.address.split(separator: "/").last.map(String.init) ?? action.address
        switch route {
        case "BeatSkip", "PitchStep", "LoopMoveBeat", "LoopMoveBar":
            return action.press > 0 ? "+\(action.press)" : "\(action.press)"
        case "ControlPagePrevious": return "PAGE <"
        case "ControlPageNext": return "PAGE >"
        case "SlipDotted": return "DOT"
        case "SlipTriplet": return "TRIP"
        case "ThirtySecond": return "1/32"
        case "Sixteenth": return "1/16"
        case "Eighth": return "1/8"
        case "Quarter": return "1/4"
        case "Half": return "1/2"
        case "One": return "1"
        case "Two": return "2"
        case "Four": return "4"
        case "Lane": return "LANE \(action.press + 1)"
        case "Enabled":
            let parts = action.address.split(separator: "/")
            if parts.count >= 2, let step = parts[parts.count - 2].dropFirst(4).description as String? {
                return "STEP \(step)"
            }
            return "STEP"
        case "PitchReset": return "PITCH 0"
        case "FormantDown": return "FORM v"
        case "FormantUp": return "FORM ^"
        case "FormantReset": return "FORM 0"
        case "LoopIn": return "LOOP IN"
        case "LoopOut": return "LOOP OUT"
        case "SpeedHalf": return "1/2x"
        case "SpeedDouble": return "2x"
        case "Speed": return "1x"
        case "Reverse": return "REV"
        case "PhaseMinus": return "PHASE -"
        case "PhasePlus": return "PHASE +"
        case "PhaseReset": return "PHASE 0"
        case "WaveformZoomOut": return "ZOOM -"
        case "WaveformZoomIn": return "ZOOM +"
        case "CueSlip": return "SLIP"
        case "PitchPreserve": return "PITCH P"
        default:
            if route.hasPrefix("Cue"), Int(route.dropFirst(3)) != nil { return "CUE \(route.dropFirst(3))" }
            return route
        }
    }
}
