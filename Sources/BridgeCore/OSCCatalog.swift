import Foundation

public enum RouteKind: String, Codable, CaseIterable, Sendable {
    case trigger
    case switchValue
    case continuous
    case bipolar
    case meter
    case text

    public var label: String {
        switch self {
        case .trigger: return "command"
        case .switchValue: return "switch"
        case .continuous: return "0…1"
        case .bipolar: return "-1…+1"
        case .meter: return "meter"
        case .text: return "text"
        }
    }

    public var suggestedMode: MappingMode {
        switch self {
        case .trigger: return .trigger
        case .switchValue: return .toggle
        case .continuous: return .absolute
        case .bipolar: return .bipolar
        case .meter, .text: return .absolute
        }
    }
}

public struct OSCRoute: Identifiable, Hashable, Sendable {
    /// May contain `{deck}`, which the mapping editor fills from its deck picker.
    public var address: String
    public var label: String
    public var group: String
    public var kind: RouteKind
    public var discovered: Bool

    public init(address: String, label: String, group: String, kind: RouteKind, discovered: Bool = false) {
        self.address = address
        self.label = label
        self.group = group
        self.kind = kind
        self.discovered = discovered
    }

    public var id: String { address }

    public var display: String { "\(address)  —  \(label)  [\(kind.label)]" }
}

/// Syndicate's OSC surface. Command routes are curated from the bridge's
/// verified mapping; feedback routes are pulled from the running app's own
/// `feedbackSubscriptions`, so the picker follows Syndicate versions instead of
/// freezing an old API dump into the app.
public enum SyndicateCatalog {
    public static let builtIn: [OSCRoute] = {
        var routes: [OSCRoute] = []
        func add(_ address: String, _ label: String, _ group: String, _ kind: RouteKind) {
            routes.append(OSCRoute(address: address, label: label, group: group, kind: kind))
        }

        // Header / shared mixer
        add("/Syndicate/Header/MasterVolume", "Master volume", "Header", .continuous)
        add("/Syndicate/Header/CueVolume", "Headphone volume", "Header", .continuous)
        add("/Syndicate/Header/CueMix", "Headphone mix", "Header", .continuous)
        add("/Syndicate/Header/BPM", "Master BPM", "Header", .continuous)
        add("/Syndicate/Header/Metronome", "Metronome", "Header", .switchValue)
        add("/Syndicate/Header/Clock", "Clock", "Header", .text)

        // Browser
        add("/Syndicate/Browser/Up", "Browser up", "Browser", .trigger)
        add("/Syndicate/Browser/Down", "Browser down", "Browser", .trigger)
        add("/Syndicate/Browser/Enter", "Browser enter", "Browser", .trigger)
        add("/Syndicate/Browser/Back", "Browser back", "Browser", .trigger)
        for deck in 1...4 {
            add("/Syndicate/Browser/L\(deck)", "Load deck \(deck)", "Browser", .trigger)
        }

        // Deck transport and tools
        let deckRoutes: [(String, String, RouteKind)] = [
            ("PlayPause", "Play / pause", .trigger),
            ("Cue", "Cue", .trigger),
            ("TempoSync", "Tempo sync", .trigger),
            ("TempoMaster", "Tempo master", .trigger),
            ("GridStart", "Set grid", .trigger),
            ("LoopIn", "Loop in", .trigger),
            ("LoopOut", "Loop out", .trigger),
            ("Loop", "Loop toggle", .switchValue),
            ("BeatSkip", "Beat jump", .trigger),
            ("PitchStep", "Pitch step", .trigger),
            ("PitchReset", "Pitch reset", .trigger),
            ("PitchDown", "Pitch down", .trigger),
            ("PitchUp", "Pitch up", .trigger),
            ("FormantUp", "Formant up", .trigger),
            ("FormantDown", "Formant down", .trigger),
            ("FormantReset", "Formant reset", .trigger),
            ("PhaseMinus", "Phase -", .trigger),
            ("PhasePlus", "Phase +", .trigger),
            ("PhaseBend", "Phase bend", .trigger),
            ("PhaseReset", "Phase reset", .trigger),
            ("SpeedHalf", "Half speed", .trigger),
            ("SpeedDouble", "Double speed", .trigger),
            ("Speed", "Reset speed", .trigger),
            ("Reverse", "Reverse", .trigger),
            ("WaveformZoomIn", "Waveform zoom in", .trigger),
            ("WaveformZoomOut", "Waveform zoom out", .trigger),
            ("ControlPagePrevious", "Control page previous", .trigger),
            ("ControlPageNext", "Control page next", .trigger),
            ("CueSlip", "Cue slip", .trigger),
            ("PitchPreserve", "Pitch preserve", .switchValue),
            ("TempoSlider", "Tempo fader", .bipolar),
            ("Pitch", "Pitch", .bipolar),
            ("PhaseOffset", "Phase offset", .bipolar),
            ("SlipDotted", "Slip dotted", .switchValue),
            ("SlipTriplet", "Slip triplet", .switchValue),
            ("SlipLoop/ThirtySecond", "Slip loop 1/32", .trigger),
            ("SlipLoop/Sixteenth", "Slip loop 1/16", .trigger),
            ("SlipLoop/Eighth", "Slip loop 1/8", .trigger),
            ("SlipLoop/Quarter", "Slip loop 1/4", .trigger),
            ("SlipLoop/Half", "Slip loop 1/2", .trigger),
            ("SlipLoop/One", "Slip loop 1", .trigger),
            ("SlipLoop/Two", "Slip loop 2", .trigger),
            ("SlipLoop/Four", "Slip loop 4", .trigger),
        ]
        for (route, label, kind) in deckRoutes {
            add("/Syndicate/Deck/{deck}/\(route)", label, "Deck · transport", kind)
        }
        for cue in 1...8 {
            add("/Syndicate/Deck/{deck}/Cue\(cue)", "Hot cue \(cue)", "Deck · cues", .trigger)
        }
        for (route, label) in [("LoopMoveBeat", "Move loop by beat"),
                               ("LoopMoveBar", "Move loop by bar")] {
            add("/Syndicate/Deck/{deck}/\(route)", label, "Deck · loops", .trigger)
        }
        add("/Syndicate/Deck/{deck}/Sampler/Lane", "Sampler lane", "Deck · sampler", .trigger)
        for step in 1...16 {
            add("/Syndicate/Deck/{deck}/Sampler/Step\(step)/Enabled", "Sampler step \(step)", "Deck · sampler", .switchValue)
        }
        for (route, label) in [("Sampler/PlayPause", "Sampler play / pause"),
                               ("Sampler/PhaseBend", "Sampler phase bend"),
                               ("Sampler/PhaseReset", "Sampler phase reset"),
                               ("Sampler/Speed", "Sampler speed"),
                               ("Sampler/Quantize", "Sampler quantize"),
                               ("Sampler/FaderStart", "Sampler fader start")] {
            add("/Syndicate/Deck/{deck}/\(route)", label, "Deck · sampler", .trigger)
        }
        for (route, label) in [("Clip/PlayPause", "Clip play / pause"),
                               ("Clip/Cue", "Clip cue"),
                               ("Clip/GridStart", "Clip grid"),
                               ("Clip/PitchDown", "Clip pitch down"),
                               ("Clip/PitchUp", "Clip pitch up"),
                               ("Clip/PitchReset", "Clip pitch reset")] {
            add("/Syndicate/Deck/{deck}/\(route)", label, "Deck · clip", .trigger)
        }

        // Mixer channels
        for (route, label, kind) in [
            ("Volume", "Channel volume", RouteKind.continuous),
            ("Trim", "Trim", .continuous),
            ("EQ/Low", "EQ low", .continuous),
            ("EQ/Mid", "EQ mid", .continuous),
            ("EQ/High", "EQ high", .continuous),
            // One nonlinear filter since Syndicate 0.2.0: Filter1 is CUTOFF
            // (0…1, centre open), Filter2 is RES, Filter3 is WIDTH. All three
            // are plain 0…1 values, not a -1…+1 bipolar pair.
            ("Filter1", "Filter cutoff", .continuous),
            ("Filter2", "Filter resonance", .continuous),
            ("Filter3", "Filter width", .continuous),
            ("Cue", "Headphone cue", .switchValue),
            ("Mute", "Mute", .switchValue),
            ("Solo", "Solo", .switchValue),
            ("Meter", "Level meter", .meter),
        ] {
            add("/Syndicate/Mixer/CH{deck}/\(route)", label, "Mixer", kind)
        }

        // Deck feedback that is useful as a target too.
        for (route, label, kind) in [
            ("Playing", "Playing state", RouteKind.switchValue),
            ("PlayPending", "Play pending", .switchValue),
            ("Loaded", "Track loaded", .switchValue),
            ("Sync", "Sync state", .switchValue),
            ("BPM", "Deck BPM", .continuous),
            ("Position", "Playhead position", .continuous),
            ("Progress", "Track progress", .continuous),
            ("LoopStart", "Loop start", .continuous),
            ("LoopEnd", "Loop end", .continuous),
            ("PlayerType", "Player type", .text),
            ("TrackInfo", "Track info", .text),
            ("Cues", "Cue list", .text),
            ("LoopInfo", "Loop info", .text),
            ("TempoSliderEnabled", "Tempo fader enabled", .switchValue),
        ] {
            add("/Syndicate/Deck/{deck}/\(route)", label, "Deck · feedback", kind)
        }

        return routes
    }()

    /// Turn a concrete published address into a `{deck}` template.
    public static func template(_ address: String) -> String {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return value }
        if !value.hasPrefix("/") { value = "/" + value }
        let lower = value.lowercased()
        if lower.hasPrefix("/autopilot/") {
            value = "/Syndicate/" + value.dropFirst("/AutoPilot/".count)
        } else if lower.hasPrefix("/syndicate/") {
            value = "/Syndicate/" + value.dropFirst("/Syndicate/".count)
        }
        var parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "" else { return value }
        var index = 1
        while index + 1 < parts.count {
            if parts[index].caseInsensitiveCompare("Deck") == .orderedSame,
               let number = Int(parts[index + 1]), (1...4).contains(number) {
                parts[index + 1] = "{deck}"
            } else if parts[index].caseInsensitiveCompare("Mixer") == .orderedSame,
                      parts[index + 1].uppercased().hasPrefix("CH"),
                      let number = Int(parts[index + 1].dropFirst(2)), (1...4).contains(number) {
                parts[index + 1] = "CH{deck}"
            }
            index += 1
        }
        return parts.joined(separator: "/")
    }

    public static func inferKind(_ address: String) -> RouteKind {
        let lower = address.lowercased()
        let tail = lower.split(separator: "/").last.map(String.init) ?? lower
        if tail.contains("meter") { return .meter }
        if ["playertype", "trackinfo", "cues", "loopinfo", "transport", "lanetitle",
            "midioutdevice", "midichannel", "route", "clock", "time"].contains(tail) {
            return .text
        }
        if tail == "temposlider" || tail == "pitch" || tail == "phaseoffset" {
            return .bipolar
        }
        if tail.contains("volume") || tail.contains("trim") || tail.contains("filter")
            || tail.contains("position") || tail.contains("progress") || tail.contains("bpm")
            || tail.contains("swing") || tail.contains("attack") || tail.contains("hold")
            || tail.contains("release") || tail.contains("speed") {
            return .continuous
        }
        if ["playing", "playpending", "loaded", "sync", "loop", "metronome", "mute", "solo",
            "cue", "filter1enabled", "filter2enabled", "temposliderenabled", "faderstart",
            "midiout", "velocitymode", "pitchpreserve", "slipdotted", "sliptriplet"].contains(tail) {
            return .switchValue
        }
        if tail.hasSuffix("enabled") { return .switchValue }
        return .trigger
    }

    public static func route(for address: String, kind: RouteKind? = nil) -> OSCRoute {
        let template = self.template(address)
        if let match = builtIn.first(where: { $0.address.caseInsensitiveCompare(template) == .orderedSame }) {
            return match
        }
        let parts = template.split(separator: "/").map(String.init)
        let group: String
        if let index = parts.firstIndex(where: { $0.caseInsensitiveCompare("Deck") == .orderedSame }),
           index + 2 < parts.count {
            group = "Deck · " + parts[index + 2]
        } else if parts.count >= 2 {
            group = parts[1]
        } else {
            group = "Custom"
        }
        let label = parts.suffix(2).joined(separator: " · ")
        return OSCRoute(address: template, label: label, group: group,
                        kind: kind ?? inferKind(template), discovered: false)
    }

    public static func all(settings: SyndicateSettings? = SyndicateSettings.detect(),
                           observed: [String] = []) -> [OSCRoute] {
        var routes = builtIn
        var seen = Set(routes.map { $0.address.lowercased() })
        var discovered: [OSCRoute] = []
        let paths = (settings?.feedbackPaths ?? []) + observed
        for path in paths {
            let template = self.template(path)
            guard template.hasPrefix("/"), !seen.contains(template.lowercased()) else { continue }
            seen.insert(template.lowercased())
            let parts = template.split(separator: "/").map(String.init)
            let group: String
            if let index = parts.firstIndex(where: { $0.caseInsensitiveCompare("Deck") == .orderedSame }),
               index + 2 < parts.count {
                group = "Deck · " + parts[index + 2]
            } else {
                group = parts.count >= 2 ? parts[1] : "Custom"
            }
            let label = parts.suffix(2).joined(separator: " · ")
            discovered.append(OSCRoute(address: template, label: label, group: group,
                                       kind: inferKind(template), discovered: true))
        }
        routes.append(contentsOf: discovered.sorted { $0.address < $1.address })
        return routes
    }
}
