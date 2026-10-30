import BridgeCore
import Darwin
import Foundation

// Verification entry point. Xcode's XCTest framework is not part of the Command
// Line Tools install, so the checks run as a standalone executable: `swift run BridgeChecks`.
// Exit status is non-zero when any check fails.

var failures = 0
var passes = 0

func check(_ condition: Bool, _ message: String, line: UInt = #line) {
    if condition {
        passes += 1
    } else {
        failures += 1
        print("FAIL line \(line): \(message)")
    }
}

func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", line: UInt = #line) {
    check(actual == expected, "\(message) expected \(expected), got \(actual)", line: line)
}

func engine(player: String = "track") -> FLX4Engine {
    let engine = FLX4Engine()
    for deck in 1...4 {
        _ = engine.handle(packet: .message(OSCMessage("/Syndicate/Deck/\(deck)/PlayerType", [.string(player)])))
    }
    return engine
}

func osc(_ effects: [EngineEffect]) -> [(String, OSCArgument)] {
    effects.compactMap {
        if case .osc(let message) = $0, let first = message.arguments.first { return (message.address, first) }
        return nil
    }
}

func oscTo(_ effects: [EngineEffect]) -> [(String, OSCArgument, UUID)] {
    effects.compactMap {
        if case .oscTo(let message, let id) = $0, let first = message.arguments.first {
            return (message.address, first, id)
        }
        return nil
    }
}

func midi(_ effects: [EngineEffect]) -> [[UInt8]] {
    effects.compactMap { if case .midi(let bytes) = $0 { return bytes } else { return nil } }
}

func warnings(_ effects: [EngineEffect]) -> [String] {
    effects.compactMap { if case .log(.warn, let text) = $0 { return text } else { return nil } }
}

func learned(_ effects: [EngineEffect]) -> LearnedControl? {
    effects.compactMap { if case .learned(let control) = $0 { return control } else { return nil } }.first
}

func feedback(_ engine: FLX4Engine, _ address: String, _ value: Float) -> [EngineEffect] {
    engine.handle(packet: .message(OSCMessage(address, [.float(value)])))
}

// MARK: - OSC codec

do {
    let message = OSCMessage("/Syndicate/Deck/1/Sync", [.int(1)])
    equal(try OSCDecoder.decode(OSCEncoder.encode(message)), .message(message), "OSC int round trip")

    let float = OSCMessage("/Syndicate/Mixer/CH2/Volume", [.float(0.42)])
    equal(try OSCDecoder.decode(OSCEncoder.encode(float)), .message(float), "OSC float round trip")

    // Syndicate sends /Syndicate/ColorPalette as ,[iiii][iiii]… — arrays carry no
    // payload of their own, so these must decode rather than reject the packet.
    func padded(_ bytes: [UInt8]) -> [UInt8] {
        let size = ((bytes.count + 1 + 3) / 4) * 4
        return bytes + [UInt8](repeating: 0, count: size - bytes.count)
    }
    var palette: [UInt8] = []
    palette += padded(Array("/Syndicate/ColorPalette".utf8))
    palette += padded(Array(",[iiii][iiii]".utf8))
    for value in 1...2 {
        for channel in 0..<4 {
            let raw = UInt32(value * 100 + channel)
            palette += [UInt8((raw >> 24) & 0xff), UInt8((raw >> 16) & 0xff),
                        UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)]
        }
    }
    let decodedPalette = try? OSCDecoder.decode(Data(palette))
    equal(decodedPalette?.messages.first?.address, "/Syndicate/ColorPalette", "Syndicate array feedback decodes")
    equal(decodedPalette?.messages.first?.arguments.count, 8, "Syndicate array feedback keeps its elements")

    let text = OSCMessage("/Syndicate/Deck/1/PlayerType", [.string("arrangement")])
    equal(try OSCDecoder.decode(OSCEncoder.encode(text)), .message(text), "OSC string round trip")

    let bundle = OSCPacket.bundle([
        .message(OSCMessage("/Syndicate/Deck/1/Playing", [.float(1)])),
        .bundle([.message(OSCMessage("/Syndicate/Mixer/CH1/Cue", [.int(0)]))]),
    ])
    let decoded = try OSCDecoder.decode(OSCEncoder.encode(bundle))
    equal(decoded.messages.map(\.address), ["/Syndicate/Deck/1/Playing", "/Syndicate/Mixer/CH1/Cue"],
          "nested bundle addresses")

    let padded = OSCEncoder.encode(OSCMessage("/a", [.string("abcde")]))
    equal(padded.count % 4, 0, "OSC strings are four-byte padded")
    equal(try OSCDecoder.decode(padded), .message(OSCMessage("/a", [.string("abcde")])), "padded string round trip")

    do {
        _ = try OSCDecoder.decode(Data([0x2f, 0x61]))
        check(false, "malformed OSC must throw")
    } catch {
        passes += 1
    }
} catch {
    failures += 1
    print("FAIL OSC codec threw: \(error)")
}

// MARK: - Mapping

do {
    equal(FLX4Mapping.physicalKey(channel: 0, note: 0x68).1, 0x54, "FLX4 CUE alias canonicalises to 84")
    equal(FLX4Mapping.physicalKey(channel: 8, note: 0x12).0, 7, "shifted left pads share channel 7")
    equal(FLX4Mapping.physicalKey(channel: 10, note: 0x13).0, 9, "right pads canonicalise to channel 9")
    equal(FLX4Mapping.pads.count, 8, "eight pad banks")
    equal(FLX4Mapping.pads[0].name(for: .arrangement), "Markers / pages", "arrangement pads use marker layout")
    equal(FLX4Mapping.pads[6].name(for: .sampler), "Steps 1-8 (Shift clears)", "sampler steps layout")
    equal(FLX4Mapping.padLabel(FLX4Mapping.pads[2].pads[1]!), "+1", "beat jump label")
    equal(FLX4Mapping.padLabel(FLX4Mapping.pads[1].pads[6]!), "DOT", "slip dotted label")
    equal(FLX4Mapping.padLabel(FLX4Mapping.pads[6].forPlayer[.sampler]!.pads[0]!), "STEP 1", "sampler step label")
}

// MARK: - Engine

do {
    check(osc(FLX4Engine().handle(midi: [0x90, 11, 127])).isEmpty, "deck actions wait for PlayerType")

    let ready = engine()
    let play = osc(ready.handle(midi: [0x90, 11, 127]))
    equal(play.first?.0, "/Syndicate/Deck/1/PlayPause", "PLAY route")
    equal(play.first?.1, .int(1), "PLAY value")
}
do {
    let engine = engine()
    equal(osc(engine.handle(midi: [0x90, 12, 127])).first?.1, .int(1), "CUE press")
    equal(osc(engine.handle(midi: [0x80, 12, 0])).first?.1, .int(0), "CUE release")
}
do {
    let engine = engine()
    _ = engine.handle(midi: [0x90, 63, 127])
    let effects = engine.handle(midi: [0x96, 104, 127])
    equal(engine.snapshot().selectedDecks, [2, 1], "Shift+LOAD selects deck 3 on the left")
    check(midi(effects).contains([0x90, 27, 127]), "bank mask follows the newly selected deck")
    check(osc(effects).contains { $0.0 == "/Syndicate/Feedback/Resend" }, "deck select requests a feedback resend")
}
do {
    let engine = engine()
    _ = engine.handle(midi: [0x90, 32, 127])
    equal(engine.snapshot().bankNames[0], "Beat jumps", "bank switch name")
    equal(engine.snapshot().padLabels[0].first, "-1", "bank switch pad label")
    _ = engine.handle(midi: [0x90, 32, 0])
    let sent = osc(engine.handle(midi: [0x97, 0, 100]))
    equal(sent.first?.0, "/Syndicate/Deck/1/BeatSkip", "beat jump route")
    equal(sent.first?.1, .int(-1), "beat jump value")
}
do {
    let engine = engine()
    equal(osc(engine.handle(midi: [0x97, 2, 100])).first?.0, "/Syndicate/Deck/1/Cue3", "hot cue pad")
    check(osc(engine.handle(midi: [0x98, 2, 100])).isEmpty, "unassigned shifted hot-cue pad")
}
do {
    let engine = engine(player: "arrangement")
    equal(engine.snapshot().bankNames[0], "Markers / pages", "arrangement bank name")
    equal(osc(engine.handle(midi: [0x97, 5, 100])).first?.0, "/Syndicate/Deck/1/GridStart",
          "arrangement pad 6 is GridStart")
}
do {
    let engine = engine(player: "clip")
    check(osc(engine.handle(midi: [0x90, 16, 127])).isEmpty, "clip player blocks LoopIn")
    equal(osc(engine.handle(midi: [0x90, 11, 127])).first?.0, "/Syndicate/Deck/1/Clip/PlayPause",
          "clip player translates PlayPause")
}
do {
    let engine = engine()
    _ = feedback(engine, "/Syndicate/Deck/1/TempoSlider", 0.0)
    _ = engine.handle(midi: [0xb0, 0, 120])
    check(osc(engine.handle(midi: [0xb0, 32, 0])).isEmpty, "pickup waits for the control to cross")
    _ = engine.handle(midi: [0xb0, 0, 60])
    let sent = osc(engine.handle(midi: [0xb0, 32, 0]))
    equal(sent.first?.0, "/Syndicate/Deck/1/TempoSlider", "pickup sends after crossing")
    if case .float(let value)? = sent.first?.1 {
        check(value > 0, "FLX4 tempo below centre is positive (pushing down speeds up)")
    } else {
        check(false, "tempo must be sent as a float")
    }
}
do {
    let engine = engine()
    engine.analogPickup = false
    // Raw 14-bit 0 is the bottom of the fader and 16383 the top; the FLX4 has
    // + at the bottom and − at the top, so the top must be negative.
    let top = osc(engine.handle(midi: [0xb0, 0, 0x7f, 0xb0, 32, 0x7f]))
    if case .float(let value)? = top.first?.1 {
        check(value < -0.99, "top of the FLX4 tempo fader is negative")
    } else {
        check(false, "tempo must be sent as a float")
    }
    let bottom = osc(engine.handle(midi: [0xb0, 0, 0, 0xb0, 32, 0]))
    if case .float(let value)? = bottom.first?.1 {
        check(value > 0.99, "bottom of the FLX4 tempo fader is positive")
    } else {
        check(false, "tempo must be sent as a float")
    }
}
do {
    let engine = engine()
    _ = engine.handle(midi: [0xb0, 0, 100])
    let effects = engine.handle(midi: [0xb0, 32, 0])
    check(osc(effects).isEmpty, "pickup without feedback sends nothing")
    check(warnings(effects).contains { $0.contains("Pickup blocked") }, "pickup without feedback warns")
}
do {
    let engine = engine()
    _ = feedback(engine, "/Syndicate/Deck/1/TempoSlider", 0.0)
    _ = engine.handle(midi: [0xb0, 0, 64])
    equal(osc(engine.handle(midi: [0xb0, 32, 0])).first?.1, .float(0), "tempo center is exactly zero")
}
do {
    // Syndicate's filter is one nonlinear unit: Filter1 is cutoff, which reads as
    // bipolar (left low-pass, centre open, right high-pass) but is a plain 0…1
    // value. The centre-detent knob is therefore forwarded unchanged, one
    // message per move, instead of being split across two parameters.
    let engine = engine()
    engine.analogPickup = false
    _ = feedback(engine, "/Syndicate/Mixer/CH1/Filter1", 0.5)
    _ = engine.handle(midi: [0xb6, 0x17, 0x00])
    let sent = osc(engine.handle(midi: [0xb6, 0x37, 0x00]))
    equal(sent.count, 1, "the filter knob is one parameter, not a pair")
    equal(sent.first?.0, "/Syndicate/Mixer/CH1/Filter1", "the filter knob drives cutoff")
    if case .float(let value)? = sent.first?.1 {
        check(abs(value) < 0.001, "the left end is full low-pass")
    } else {
        check(false, "the filter knob must be sent as a float")
    }
    check(engine.snapshot().pickupEnabled == false, "snapshot reports absolute mode")
    check(engine.snapshot().pickup.isEmpty, "absolute mode has no pickup states")
}
do {
    let engine = engine()
    engine.analogPickup = false
    let effects = engine.handle(midi: [0xb6, 0x17, 0x7f, 0xb6, 0x37, 0x7f])
    let sent = osc(effects)
    check(sent.allSatisfy { $0.0 == "/Syndicate/Mixer/CH1/Filter1" },
          "the whole travel stays on one filter parameter")
    if case .float(let value)? = sent.last?.1 {
        check(abs(value - 1) < 0.001, "the right end is full high-pass")
    } else {
        check(false, "the filter knob must be sent as a float")
    }
    check(warnings(effects).isEmpty, "absolute mode never warns about pickup")
}
do {
    let engine = engine()
    engine.analogPickup = false
    _ = engine.handle(midi: [0xb6, 0x17, 0x40]) // centre: 8192 / 16383
    let centre = osc(engine.handle(midi: [0xb6, 0x37, 0x00]))
    equal(centre.count, 1, "centre sends one cutoff value")
    if case .float(let value)? = centre.first?.1 {
        check(abs(value - 0.5) < 0.001, "centre is half travel, which is the open filter")
    } else {
        check(false, "the filter knob must be a float")
    }
    _ = engine.handle(midi: [0xb6, 0x17, 0x70]) // 14336 / 16383 = 0.875
    let right = osc(engine.handle(midi: [0xb6, 0x37, 0x00]))
    if case .float(let value)? = right.first?.1 {
        check(abs(value - 0.875) < 0.001, "right of centre is proportional travel, not a scaled split")
    } else {
        check(false, "the filter knob must be a float")
    }
}
do {
    let engine = engine()
    _ = feedback(engine, "/Syndicate/Deck/1/TempoSlider", 0.0)
    _ = engine.handle(midi: [0xb0, 0, 120])
    _ = engine.handle(midi: [0xb0, 32, 0])
    _ = engine.handle(midi: [0xb0, 0, 60])
    _ = engine.handle(midi: [0xb0, 32, 0])
    engine.analogPickup = false
    check(engine.snapshot().pickup.isEmpty, "absolute mode hides pickup state")
    engine.analogPickup = true
    check(engine.snapshot().pickup[ControlID(kind: .cc, channel: 0, number: 0)] == false,
          "re-enabling pickup re-arms captured controls")
}

// MARK: - Real DDJ-FLX4 packets

do {
    let engine = engine()
    _ = feedback(engine, "/Syndicate/Mixer/CH1/Volume", 0.5)
    _ = engine.handle(midi: [0xb0, 0x13, 0x20])
    check(osc(engine.handle(midi: [0xb0, 0x33, 0x00])).isEmpty, "fader below the confirmed value waits")
    let packed = osc(engine.handle(midi: [0xb0, 0x13, 0x60, 0xb0, 0x33, 0x00]))
    equal(packed.first?.0, "/Syndicate/Mixer/CH1/Volume", "packed fader packet reaches OSC")
    if case .float(let value)? = packed.first?.1 {
        check(abs(value - 0.75) < 0.001, "packed fader value is the 14-bit position")
    } else {
        check(false, "the channel fader must be sent as a float")
    }
    let captured = osc(engine.handle(midi: [0xb0, 0x13, 0x7e, 0xb0, 0x33, 0x73]))
    if case .float(let value)? = captured.first?.1 {
        check(value > 0.98, "captured fader packet keeps its high position")
    } else {
        check(false, "captured fader packet must be sent")
    }
}
do {
    let engine = engine()
    _ = feedback(engine, "/Syndicate/Mixer/CH1/Volume", 0.5)
    _ = engine.handle(midi: [0xb0, 0x13, 0x20, 0x33, 0x00])
    equal(osc(engine.handle(midi: [0xb0, 0x13, 0x60, 0x33, 0x00])).first?.0,
          "/Syndicate/Mixer/CH1/Volume", "running status keeps the fader stream alive")
}
do {
    let engine = engine()
    _ = feedback(engine, "/Syndicate/Mixer/CH1/Trim", 0.5)
    _ = engine.handle(midi: [0xb0, 0x04, 0x20, 0xb0, 0x24, 0x00])
    equal(osc(engine.handle(midi: [0xb0, 0x04, 0x61, 0xb0, 0x24, 0x3e])).first?.0,
          "/Syndicate/Mixer/CH1/Trim", "packed trim packet reaches OSC")
}
do {
    let engine = engine()
    _ = feedback(engine, "/Syndicate/Mixer/CH1/EQ/High", 0.5)
    _ = engine.handle(midi: [0xb0, 0x07, 0x20, 0xb0, 0x27, 0x00])
    equal(osc(engine.handle(midi: [0xb0, 0x07, 0x60, 0xb0, 0x27, 0x00])).first?.0,
          "/Syndicate/Mixer/CH1/EQ/High", "packed EQ packet reaches OSC")
}
do {
    let engine = engine()
    _ = feedback(engine, "/Syndicate/Header/MasterVolume", 0.5)
    _ = engine.handle(midi: [0xb6, 0x08, 0x20, 0xb6, 0x28, 0x00])
    equal(osc(engine.handle(midi: [0xb6, 0x08, 0x47, 0xb6, 0x28, 0x17])).first?.0,
          "/Syndicate/Header/MasterVolume", "packed master level packet reaches OSC")
}
do {
    let engine = engine()
    _ = feedback(engine, "/Syndicate/Header/CueVolume", 0.4)
    _ = engine.handle(midi: [0xb6, 0x0d, 0x20, 0xb6, 0x2d, 0x00])
    equal(osc(engine.handle(midi: [0xb6, 0x0d, 0x39, 0xb6, 0x2d, 0x5a])).first?.0,
          "/Syndicate/Header/CueVolume", "packed headphone level packet reaches OSC")
}
do {
    let engine = engine()
    let mix = osc(engine.handle(midi: [0xb6, 0x0c, 0x40, 0xb6, 0x2c, 0x00]))
    equal(mix.first?.0, "/Syndicate/Header/CueMix", "headphone mix needs no feedback")
    if case .float(let value)? = mix.first?.1 {
        check(abs(value - 0.5) < 0.001, "headphone mix value is the 14-bit position")
    } else {
        check(false, "the headphone mix must be sent as a float")
    }
}
do {
    // Syndicate has no OSC address for the Beat FX depth knob or the jog wheel,
    // so those must say so rather than look like a dead control.
    let engine = engine()
    let unmapped = engine.handle(midi: [0xb4, 0x02, 0x40, 0xb4, 0x22, 0x00])
    check(osc(unmapped).isEmpty, "unmapped analog control sends nothing")
    check(warnings(unmapped).contains { $0.contains("CC 2 on channel 4") }, "unmapped analog control warns")
}
do {
    let engine = engine()
    _ = engine.start()
    check(osc(engine.handle(midi: FLX4Mapping.keepalive)).isEmpty, "keepalive SysEx is ignored")
    let after = engine.handle(midi: [0xf0, 0x7e, 0x00, 0x06, 0x01, 0xf7, 0x90, 0x0b, 0x7f])
    equal(osc(after).first?.0, "/Syndicate/Deck/1/PlayPause", "a message after SysEx still arrives")
    check(osc(engine.handle(midi: [0x36, 0x00])).isEmpty, "stray data bytes are ignored")
}
do {
    let engine = engine()
    _ = feedback(engine, "/Syndicate/Mixer/CH1/Filter2", 0.3)
    _ = engine.handle(midi: [0x90, 63, 127])
    _ = engine.handle(midi: [0xb6, 23, 51]) // approach from above the confirmed 0.3
    _ = engine.handle(midi: [0xb6, 55, 0])
    _ = engine.handle(midi: [0xb6, 23, 32]) // cross the confirmed value
    equal(osc(engine.handle(midi: [0xb6, 55, 0])).first?.0, "/Syndicate/Mixer/CH1/Filter2",
          "Shift+filter targets Filter2")
}
do {
    let engine = engine()
    equal(osc(engine.handle(midi: [0xb6, 64, 1])).first?.0, "/Syndicate/Browser/Down", "encoder clockwise")
    equal(osc(engine.handle(midi: [0xb6, 64, 127])).first?.0, "/Syndicate/Browser/Up", "encoder anticlockwise")
    check(osc(engine.handle(midi: [0xb6, 64, 64])).isEmpty, "encoder neutral")
}
do {
    let engine = engine()
    check(osc(engine.handle(midi: [0x90, 84, 127])).isEmpty, "cue toggle requires feedback")
    _ = engine.handle(midi: [0x80, 84, 0])
    _ = feedback(engine, "/Syndicate/Mixer/CH1/Cue", 0)
    equal(osc(engine.handle(midi: [0x90, 84, 127])).first?.1, .int(1), "cue toggle on")
    _ = engine.handle(midi: [0x80, 84, 0])
    _ = feedback(engine, "/Syndicate/Mixer/CH1/Cue", 1)
    equal(osc(engine.handle(midi: [0x90, 84, 127])).first?.1, .int(0), "cue toggle off")
}
do {
    let engine = engine()
    _ = engine.start()
    check(midi(feedback(engine, "/Syndicate/Deck/1/Playing", 1)).contains([0x90, 11, 127]),
          "Playing feedback drives the PLAY LED")
    check(midi(feedback(engine, "/Syndicate/Mixer/CH1/Meter", 0.5))
            .contains { $0[0] == 0xb0 && $0[1] == 2 && $0[2] > 50 }, "meter feedback drives CC 2")
    let invalid = feedback(engine, "/Syndicate/Deck/1/Playing", 2)
    check(engine.snapshot().values["/syndicate/deck/1/playing"] == nil,
          "invalid switch feedback clears the confirmed value")
    check(!warnings(invalid).isEmpty, "invalid feedback warns")
}
do {
    let engine = engine()
    _ = engine.handle(midi: [0x90, 30, 127])
    _ = engine.handle(midi: [0x90, 30, 0])
    let pressed = osc(engine.handle(midi: [0x97, 0, 100]))
    equal(pressed.map(\.0), [
        "/Syndicate/Deck/1/SlipDotted",
        "/Syndicate/Deck/1/SlipTriplet",
        "/Syndicate/Deck/1/SlipLoop/ThirtySecond",
    ], "slip hold applies timing then the loop")
    equal(pressed.last?.1, .int(1), "slip loop press")
    equal(osc(engine.handle(midi: [0x87, 0, 0])).first?.1, .int(0), "slip loop release")
}
do {
    let engine = engine()
    _ = engine.handle(midi: [0x90, 30, 127])
    _ = engine.handle(midi: [0x90, 30, 0])
    let latched = osc(engine.handle(midi: [0x97, 6, 100]))
    equal(latched.filter { $0.1 == .int(1) }.first?.0, "/Syndicate/Deck/1/SlipDotted", "slip dotted latch")
    equal(engine.snapshot().slipTiming[1], .dotted, "latched timing appears in the snapshot")
}
do {
    let engine = engine()
    let effects = engine.handle(midi: [0x96, 122, 127])
    equal(engine.snapshot().selectedDecks, [0, 3], "right deck selector toggles 2 <-> 4")
    check(osc(effects).contains { $0.0 == "/Syndicate/Feedback/Resend" }, "deck select resends feedback")
    check(midi(effects).contains([0x91, 27, 127]), "right side bank mask")
}
do {
    let engine = FLX4Engine()
    let start = Date()
    let first = engine.tick(now: start)
    equal(midi(first).count, 1, "first keepalive")
    equal(midi(first).first, FLX4Mapping.keepalive, "keepalive bytes")
    check(engine.tick(now: start.addingTimeInterval(0.1)).isEmpty, "keepalive is rate limited")
    equal(midi(engine.tick(now: start.addingTimeInterval(0.25))).count, 1, "keepalive repeats")
}

// MARK: - Startup and Syndicate detection

do {
    let engine = FLX4Engine()
    let effects = engine.start()
    check(osc(effects).contains { $0.0 == "/Syndicate/Feedback/Resend" }, "start asks Syndicate to resend feedback")
    check(effects.contains { if case .osc = $0 { return true } else { return false } }, "start emits OSC immediately")
    check(midi(effects).contains([0x90, 27, 127]), "start restores the pad-mode LED")
}
do {
    check(MIDITransport.isFLX4("DDJ-FLX4"), "exact FLX4 endpoint name matches")
    check(MIDITransport.isFLX4("Pioneer DDJ-FLX4 MIDI"), "decorated FLX4 endpoint name matches")
    check(MIDITransport.isFLX4("ddj flx4"), "name matching ignores case and punctuation")
    check(!MIDITransport.isFLX4("MPK mini 3"), "unrelated endpoint does not match")
}
do {
    func settingsFile(paths: [String]) -> String {
        let path = NSTemporaryDirectory() + "flxbridge-settings-\(UUID().uuidString).json"
        let subscriptions = try! JSONSerialization.data(withJSONObject: ["paths": paths])
        let root: [String: Any] = [
            "osc": [
                "enabled": true,
                "listenPort": 8001,
                "feedbackPort": 8000,
                "feedbackHost": "127.0.0.1",
                "feedbackSubscriptions": String(data: subscriptions, encoding: .utf8)!,
            ],
        ]
        try! JSONSerialization.data(withJSONObject: root).write(to: URL(fileURLWithPath: path))
        return path
    }
    let bridgePath = settingsFile(paths: ["/Syndicate/Deck/1/Playing", "/Syndicate/Mixer/CH1/Cue"])
    let detected = SyndicateSettings.detect(path: bridgePath)
    equal(detected?.listenPort, 8001, "detected Syndicate OSC listen port")
    equal(detected?.feedbackPort, 8000, "detected Syndicate feedback port")
    equal(detected?.feedbackHost, "127.0.0.1", "detected Syndicate feedback host")
    equal(detected?.hasBridgeSubscriptions, true, "Syndicate subscriptions count as bridge routes")
    equal(detected?.namespace, "Syndicate", "detected the Syndicate namespace")
    equal(detected?.addressRoot, "/Syndicate", "detected the Syndicate address root")
    equal(detected?.feedbackPaths.count, 2, "feedback paths are exposed to the catalog")
    try? FileManager.default.removeItem(atPath: bridgePath)

    // A pre-rename build still advertises /AutoPilot; its ports and root must
    // be readable so commands can be retargeted onto it.
    let legacyPath = settingsFile(paths: ["/AutoPilot/Deck/1/Playing", "/AutoPilot/Mixer/CH1/Cue"])
    let legacy = SyndicateSettings.detect(path: legacyPath)
    equal(legacy?.hasBridgeSubscriptions, true, "legacy AutoPilot subscriptions count as bridge routes")
    equal(legacy?.namespace, "AutoPilot", "detected the pre-rename namespace")
    equal(legacy?.addressRoot, "/AutoPilot", "a pre-rename build keeps its own root")
    equal(SyndicateSettings.detect(in: ["/nonexistent/Syndicate.settings", legacyPath])?.namespace,
          "AutoPilot", "the first readable settings file is used")
    try? FileManager.default.removeItem(atPath: legacyPath)

    // A custom root can have more than one segment; Feedback/Resend has to be
    // addressed under all of it.
    let customPath = settingsFile(paths: ["/Stage/Left/Deck/1/BPM", "/Stage/Left/Header/BPM"])
    equal(SyndicateSettings.detect(path: customPath)?.addressRoot, "/Stage/Left",
          "a multi-segment root is kept whole")
    try? FileManager.default.removeItem(atPath: customPath)

    let foreignPath = settingsFile(paths: ["/Other/Thing"])
    let foreign = SyndicateSettings.detect(path: foreignPath)
    equal(foreign?.hasBridgeSubscriptions, false, "foreign subscriptions are reported missing")
    try? FileManager.default.removeItem(atPath: foreignPath)

    check(SyndicateSettings.detect(path: "/nonexistent/Syndicate.settings") == nil, "missing settings are reported")
}

do {
    // The pod strip is painted from Syndicate's own hot-cue swatches, which live
    // in `general` rather than under `osc`. Only the slots the app has written
    // are taken; a missing slot falls back to the factory palette so pixel n is
    // always hot cue n.
    equal(PodStrip.normalised("FFE7463D"), "e7463d", "AARRGGBB loses its alpha")
    equal(PodStrip.normalised("#F28C32"), "f28c32", "a leading hash is optional")
    equal(PodStrip.normalised(" ffd85a "), "ffd85a", "plain rrggbb is trimmed")
    check(PodStrip.normalised("yellow") == nil, "a colour name is not a swatch")
    check(PodStrip.normalised("12345") == nil, "five digits is not a swatch")

    let path = NSTemporaryDirectory() + "flxbridge-cues-\(UUID().uuidString).json"
    let root: [String: Any] = [
        "osc": ["enabled": true, "listenPort": 9090, "feedbackPort": 9096],
        "general": ["cueColor1": "FF102030", "cueColor8": "FFaabbcc"],
    ]
    try! JSONSerialization.data(withJSONObject: root).write(to: URL(fileURLWithPath: path))
    let settings = SyndicateSettings.detect(path: path)
    equal(settings?.cueColours.count, 8, "the palette always has eight slots")
    equal(settings?.cueColours.first, "FF102030", "hot cue 1 colour is read")
    equal(settings?.cueColours[7], "FFaabbcc", "hot cue 8 colour is read")
    equal(settings?.cueColours[3], "", "an unwritten slot is empty, not shifted")

    let palette = PodStrip.palette(from: settings)
    equal(palette.count, 8, "one colour per pixel")
    equal(palette.first, "102030", "pixel 1 takes hot cue 1")
    equal(palette[7], "aabbcc", "pixel 8 takes hot cue 8")
    equal(palette[3], PodStrip.fallbackColours[3], "an unwritten slot uses the factory palette")
    equal(PodStrip.palette(from: nil), PodStrip.fallbackColours, "no settings still paints")
    try? FileManager.default.removeItem(atPath: path)

    let frames = PodStrip.messages(for: palette)
    equal(frames.count, 8, "one frame per pixel")
    equal(frames.first?.address, "/Nexus/Light/led/1", "pixel 1 is addressed alone")
    equal(frames.last?.address, "/Nexus/Light/led/8", "pixel 8 is addressed alone")
    equal(frames.first?.arguments, [.float(1), .string("#102030")],
          "the firmware gets a level then a hex colour")
}

// MARK: - Namespace and feedback types

do {
    // Current Syndicate builds publish feedback under /Syndicate and send switches
    // as ints. Both must land on the same routes the bridge registered.
    let engine = FLX4Engine()
    _ = engine.handle(packet: .message(OSCMessage("/Syndicate/Deck/1/PlayerType", [.string("track")])))
    let play = osc(engine.handle(midi: [0x90, 11, 127]))
    equal(play.first?.0, "/Syndicate/Deck/1/PlayPause", "Syndicate PlayerType unlocks deck routes")

    _ = engine.handle(packet: .message(OSCMessage("/Syndicate/Mixer/CH1/Cue", [.int(1)])))
    let cue = osc(engine.handle(midi: [0x90, 84, 127]))
    equal(cue.first?.0, "/Syndicate/Mixer/CH1/Cue", "mixer cue toggles with Syndicate feedback")
    equal(cue.first?.1, .int(0), "on-state int feedback toggles the switch off")

    let switchLED = midi(engine.handle(packet: .message(OSCMessage("/Syndicate/Deck/1/Sync", [.int(1)]))))
    check(switchLED.contains([0x90, 88, 127]), "int switch feedback lights the Sync LED")

    let meter = midi(engine.handle(packet: .message(OSCMessage("/Syndicate/Mixer/CH1/Meter", [.int(127)]))))
    check(meter.contains([0xb0, 2, 127]), "int meter feedback drives the level meter")

    let deck = engine.snapshot().players[0]
    equal(deck, .track, "Syndicate PlayerType is applied to the deck")

    // An empty deck cannot serve PlayPause; the press must report that instead of
    // disappearing without trace.
    let empty = FLX4Engine()
    _ = empty.handle(packet: .message(OSCMessage("/Syndicate/Deck/1/PlayerType", [.string("empty")])))
    let emptyPress = empty.handle(midi: [0x90, 11, 127])
    check(osc(emptyPress).isEmpty, "empty deck sends no deck route")
    check(warnings(emptyPress).contains { $0.contains("PlayPause unavailable") }, "empty deck press reports the reason")
    equal(FLX4Engine.canonical("/AutoPilot/Deck/1/Playing"), "/syndicate/deck/1/playing",
          "pre-rename feedback folds onto the Syndicate namespace")
    equal(FLX4Engine.canonical("/Syndicate/Deck/1/Playing"), "/syndicate/deck/1/playing",
          "Syndicate namespace is unchanged")
}

// MARK: - Serial OSC framing and parsing

do {
    // The firmware defaults to 921600 and Cuewire has to offer that rate, or a
    // freshly flashed board speaks past the host.
    check(SerialTransport.baudRates.contains(SerialTransport.defaultBaud),
          "the default serial baud is selectable")
    check(SerialTransport.baudRates.contains(460_800) && SerialTransport.baudRates.contains(921_600),
          "high link rates are offered")
}

do {
    let message = OSCMessage("/Syndicate/Deck/1/PlayPause", [.int(1)])
    let frame = OSCSerialCodec.slip(OSCEncoder.encode(message))
    var framer = OSCSerialFramer(framing: .slip)
    let first = framer.feed(Array(frame.prefix(7)))
    check(first.isEmpty, "SLIP waits for the end delimiter")
    let rest = framer.feed(Array(frame.dropFirst(7)))
    equal(rest.first?.messages.first?.address, "/Syndicate/Deck/1/PlayPause", "SLIP frame decodes")
    equal(rest.first?.messages.first?.firstInt, 1, "SLIP argument survives")
}

do {
    // 0xC0 and 0xDB inside a payload must be escaped and restored.
    let message = OSCMessage("/esp/blob", [.blob([0xc0, 0xdb, 0xc0])])
    let frame = OSCSerialCodec.slip(OSCEncoder.encode(message))
    var framer = OSCSerialFramer(framing: .slip)
    let packet = framer.feed(Array(frame)).first
    equal(packet?.messages.first?.address, "/esp/blob", "SLIP escapes payload bytes")
    if case .blob(let bytes)? = packet?.messages.first?.arguments.first {
        equal(bytes, [0xc0, 0xdb, 0xc0], "SLIP restores escaped bytes")
    } else {
        check(false, "blob argument missing after SLIP")
    }
}

do {
    let parsed = OSCSerialCodec.parseText("/Deck/1/PlayPause i:1")
    equal(parsed?.address, "/Deck/1/PlayPause", "text address")
    equal(parsed?.firstInt, 1, "text tagged int")
    equal(OSCSerialCodec.parseText("/Mixer/CH1/Volume f:0.5")?.firstFloat, 0.5, "text tagged float")
    equal(OSCSerialCodec.parseText("/esp/name s:hello world")?.firstString, "hello", "text args split on spaces")
    equal(OSCSerialCodec.parseText("# comment"), nil, "text comments ignored")
    equal(OSCSerialCodec.parseText("bogus"), nil, "text non-address ignored")

    var autoText = OSCSerialFramer(framing: .auto)
    let packets = autoText.feed(Array("/Deck/1/PlayPause i:1\n".utf8))
    equal(autoText.mode, .text, "auto detects newline text")
    equal(packets.first?.messages.first?.address, "/Deck/1/PlayPause", "auto text decodes")

    let slipFrame = OSCSerialCodec.slip(OSCEncoder.encode(OSCMessage("/Deck/1/Cue", [.int(0)])))
    var autoSlip = OSCSerialFramer(framing: .auto)
    _ = autoSlip.feed(Array(slipFrame.prefix(4)))
    let decoded = autoSlip.feed(Array(slipFrame.dropFirst(4)))
    equal(autoSlip.mode, .slip, "auto detects SLIP")
    equal(decoded.first?.messages.first?.address, "/Deck/1/Cue", "auto SLIP decodes")
}

do {
    // A binary SLIP payload that happens to contain 0x0A must not be mistaken
    // for a text line before the 0xC0 delimiter arrives.
    var payload = OSCEncoder.encode(OSCMessage("/x", [.float(0)]))
    payload.append(0x0a)
    let slip = OSCSerialCodec.slip(payload)
    var framer = OSCSerialFramer(framing: .auto)
    let packets = framer.feed(Array(slip))
    equal(framer.mode, .slip, "auto prefers SLIP over a binary 0x0A")
    equal(packets.first?.messages.first?.address, "/x", "binary auto frame decodes")
}

// MARK: - Catalog and hub routing

do {
    equal(SyndicateCatalog.template("/Syndicate/Deck/2/Playing"),
          "/Syndicate/Deck/{deck}/Playing", "deck feedback becomes a template")
    equal(SyndicateCatalog.template("/Syndicate/Mixer/CH3/Volume"),
          "/Syndicate/Mixer/CH{deck}/Volume", "mixer channel becomes a template")
    equal(SyndicateCatalog.template("/AutoPilot/Deck/2/Playing"),
          "/Syndicate/Deck/{deck}/Playing", "a pre-rename address becomes a Syndicate template")
    equal(SyndicateCatalog.route(for: "/Syndicate/Header/MasterVolume").kind, .continuous,
          "catalog knows a continuous header route")
    equal(SyndicateCatalog.route(for: "/Syndicate/Deck/1/PlayPause").kind, .trigger,
          "catalog knows a trigger route")
    check(SyndicateCatalog.all(settings: nil).count > 80, "built-in catalog is populated")
    let builtInAddresses = SyndicateCatalog.builtIn.map { $0.address }
    check(Set(builtInAddresses).count == builtInAddresses.count, "built-in catalog has unique addresses")

    let endpoint = OSCEndpoint(label: "Resolume", host: "127.0.0.1", port: 7001,
                               prefix: "/Resolume")
    equal(HubRouter.endpoint(for: "/Resolume/Layer1/Opacity", endpoints: [endpoint])?.label,
          "Resolume", "prefix routes to an extra destination")
    equal(HubRouter.endpoint(for: "/Syndicate/Deck/1/PlayPause", endpoints: [endpoint])?.label,
          nil, "unmatched route falls back to Syndicate")
    let nested = OSCEndpoint(label: "Layer", host: "127.0.0.1", port: 7002,
                             prefix: "/Resolume/Layer")
    equal(HubRouter.endpoint(for: "/Resolume/Layer/1", endpoints: [endpoint, nested])?.label,
          "Layer", "longest prefix wins")
    equal(HubRouter.endpoint(for: "/Resolume/X", endpoints: [
        OSCEndpoint(label: "Off", host: "127.0.0.1", port: 7003, prefix: "/Resolume", enabled: false),
    ])?.label, nil, "disabled destinations are skipped")
    equal(HubRouter.commandAddress("/Deck/1/PlayPause"), "/Syndicate/Deck/1/PlayPause", "short deck address expands")
    equal(HubRouter.commandAddress("/Mixer/CH1/Volume"), "/Syndicate/Mixer/CH1/Volume", "short mixer address expands")
    equal(HubRouter.commandAddress("/Syndicate/Deck/1/Playing"), "/Syndicate/Deck/1/Playing", "the Syndicate root is kept")
    equal(HubRouter.commandAddress("/AutoPilot/Deck/1/Playing"), "/Syndicate/Deck/1/Playing",
          "a mapping saved as AutoPilot folds onto Syndicate")

    // A build that publishes /Syndicate feedback also listens there, and a
    // pre-rename one still listens under /AutoPilot; the outbound command root
    // has to follow the detected namespace.
    equal(HubRouter.retarget("/Syndicate/Deck/1/PlayPause", root: "/Syndicate"),
          "/Syndicate/Deck/1/PlayPause", "commands follow the detected namespace")
    equal(HubRouter.retarget("/Syndicate/Header/BPM", root: "/Syndicate/"),
          "/Syndicate/Header/BPM", "a trailing slash does not double up")
    equal(HubRouter.retarget("/Syndicate/Deck/1/PlayPause", root: "/AutoPilot"),
          "/AutoPilot/Deck/1/PlayPause", "a pre-rename build gets its own root")
    equal(HubRouter.retarget("/AutoPilot/Deck/1/PlayPause", root: "/Syndicate"),
          "/Syndicate/Deck/1/PlayPause", "a legacy address follows the current root")
    equal(HubRouter.retarget("/Syndicate/Deck/1/PlayPause", root: "/Syndicate"),
          "/Syndicate/Deck/1/PlayPause", "the default root is unchanged")
    equal(HubRouter.retarget("/Syndicate/Deck/1/PlayPause", root: nil),
          "/Syndicate/Deck/1/PlayPause", "no detected app leaves the address alone")
    equal(HubRouter.retarget("/Resolume/Layer1/Opacity", root: "/Syndicate"),
          "/Resolume/Layer1/Opacity", "extra destinations keep their own prefix")
    equal(HubRouter.retarget("/Syndicate/Deck/1/PlayPause", root: "/Stage/Left"),
          "/Stage/Left/Deck/1/PlayPause", "a multi-segment root is kept whole")
    equal(HubRouter.retarget("/AutoPilot/Deck/1/PlayPause", root: "/Stage/Left"),
          "/Stage/Left/Deck/1/PlayPause", "a legacy address follows a custom root")
}

// MARK: - Mapping mode defaults

do {
    // A fader saved as Trigger sends one 1 and then nothing, which looks like a
    // dead mapping. Choosing the route must replace the editor's default mode.
    equal(MappingModeResolver.resolvedMode(for: "/Syndicate/Header/MasterVolume", selected: .trigger),
          .absolute, "a continuous route never keeps the leftover Trigger")
    equal(MappingModeResolver.resolvedMode(for: "/Syndicate/Deck/1/TempoSlider", selected: .trigger),
          .bipolar, "a bipolar route saves as Bipolar")
    equal(MappingModeResolver.resolvedMode(for: "/Syndicate/Deck/1/PlayPause", selected: .trigger),
          .trigger, "a trigger route keeps Trigger")
    equal(MappingModeResolver.resolvedMode(for: "/MyApp/Volume", selected: .trigger),
          .absolute, "a typed continuous route also upgrades")
    equal(MappingModeResolver.resolvedMode(for: "/Syndicate/Header/MasterVolume", selected: .absolute),
          .absolute, "an explicit mode is respected")
}

// MARK: - Mapping store

do {
    let path = NSTemporaryDirectory() + "flxbridge-mappings-\(UUID().uuidString).json"
    let store = MappingStore(path: path)
    let endpoint = OSCEndpoint(label: "TouchDesigner", host: "127.0.0.1", port: 7100,
                               prefix: "/TD")
    store.addEndpoint(endpoint)
    let mapping = ControlMapping(name: "Play", source: .midiNote, channel: 0, number: 11,
                                 address: "/Syndicate/Deck/{deck}/PlayPause",
                                 mode: .trigger, deck: 2, endpointID: endpoint.id)
    store.add(mapping)
    check(store.save() == nil, "mapping store saves")
    let reloaded = MappingStore(path: path)
    equal(reloaded.mappings.count, 1, "mapping survives a reload")
    equal(reloaded.mappings.first?.resolvedAddress(), "/Syndicate/Deck/2/PlayPause", "deck substitution survives")
    equal(reloaded.endpoints.first?.label, "TouchDesigner", "endpoint survives a reload")
    equal(reloaded.mappings.first?.endpointID, endpoint.id, "mapping keeps its destination")

    reloaded.removeEndpoint(id: endpoint.id)
    equal(reloaded.mappings.first?.endpointID, nil, "removing an endpoint clears mappings that used it")
    reloaded.add(ControlMapping(source: .midiNote, channel: 0, number: 11,
                                address: "/Syndicate/Deck/1/Cue", mode: .trigger))
    equal(reloaded.mappings.count, 1, "a mapping with the same control replaces the old one")
    equal(reloaded.mappings.first?.address, "/Syndicate/Deck/1/Cue", "replacement address")

    // Mutations persist without an explicit save, so the editor cannot lose a
    // mapping when the app quits straight after a Learn.
    reloaded.add(ControlMapping(source: .midiCC, channel: 0, number: 21,
                                address: "/Syndicate/Header/CueVolume", mode: .absolute))
    let autoSaved = MappingStore(path: path)
    equal(autoSaved.mappings.count, 2, "mapping mutations auto-save")

    try? FileManager.default.removeItem(atPath: path)
}

do {
    // Mappings saved before the rebrand still name the old root. Loading them
    // must move both targets onto /Syndicate so the editor and the wire agree.
    let path = NSTemporaryDirectory() + "flxbridge-legacy-mappings-\(UUID().uuidString).json"
    let legacy = MappingStore(path: path)
    legacy.add(ControlMapping(source: .midiCC, channel: 0, number: 21,
                              address: "/AutoPilot/Deck/{deck}/BeatSkip",
                              reverseAddress: "/AutoPilot/Deck/{deck}/PitchDown",
                              mode: .relative))
    let migrated = MappingStore(path: path)
    equal(migrated.mappings.first?.address, "/Syndicate/Deck/{deck}/BeatSkip",
          "a pre-rename mapping is migrated on load")
    equal(migrated.mappings.first?.reverseAddress, "/Syndicate/Deck/{deck}/PitchDown",
          "the reverse route is migrated too")
    try? FileManager.default.removeItem(atPath: path)
}

do {
    // A pot publishes the position it is at, so Relative throws it away: the
    // delta is the truncated position, zero everywhere below full scale, and a
    // whole turn sends one message at its top. The editor inherits the last
    // capture's mode, so a pot learned after an encoder is saved that way, and
    // storing it must be repaired rather than left to look like a dead knob.
    let path = NSTemporaryDirectory() + "flxbridge-knob-mode-\(UUID().uuidString).json"
    let store = MappingStore(path: path)
    store.add(ControlMapping(source: .serial, control: "/Nexus/Control/knob/2",
                             address: "/Syndicate/Mixer/CH{deck}/Volume",
                             mode: .relative, deck: 2))
    equal(store.mappings.first?.mode, .absolute, "a position source is never saved as Relative")
    equal(MappingStore(path: path).mappings.first?.mode, .absolute,
          "the repair survives a reload")

    let pot = FLX4Engine()
    pot.userMappings = MappingStore(path: path).mappings
    let sweep = (0...4).map { step in
        osc(pot.handle(serial: OSCMessage("/Nexus/Control/knob/2", [.float(Float(step) / 4)])))
    }
    equal(sweep.map(\.count), [1, 1, 1, 1, 1], "every position of a pot reaches the target")
    equal(sweep.first?.first?.1, .float(0), "the bottom of a turn sends 0")
    equal(sweep.last?.first?.1, .float(1), "the top of a turn sends 1")
    equal(sweep[2].first?.0, "/Syndicate/Mixer/CH2/Volume", "a pot reaches its deck's volume")
    try? FileManager.default.removeItem(atPath: path)
}

do {
    let valid = OSCEndpoint(label: "Gear", host: "192.168.1.20", port: 9000, prefix: "/Gear")
    check(valid.isValid, "IPv4 endpoint is valid")
    check(!OSCEndpoint(label: "Bad", host: "localhost", port: 9000).isValid, "hostname endpoint is rejected")
    check(!OSCEndpoint(label: "Bad", host: "10.0.0.1", port: 0).isValid, "zero port is rejected")
}

// MARK: - User mappings and learn

do {
    let engine = FLX4Engine()
    engine.beginLearn(.midi)
    let effects = engine.handle(midi: [0x90, 11, 127])
    let captured = learned(effects)
    equal(captured?.source, .midiNote, "learn captures a note")
    equal(captured?.channel, 0, "learn captures the channel")
    equal(captured?.number, 11, "learn captures the note number")
    check(osc(effects).isEmpty, "learn consumes the gesture")
    engine.userMappings = [captured!.draft(address: "/Syndicate/Deck/1/Cue", mode: .trigger)]
    engine.cancelLearn()
    let output = osc(engine.handle(midi: [0x90, 11, 127]))
    equal(output.first?.0, "/Syndicate/Deck/1/Cue", "user mapping overrides the stock PLAY route")
}

do {
    let engine = FLX4Engine()
    engine.beginLearn(.midi)
    let captured = learned(engine.handle(midi: [0xb0, 0x13, 0x40]))
    equal(captured?.source, .midiCC, "learn captures a CC fader")
    equal(captured?.number, 19, "FLX4 14-bit learn records the MSB control, not its LSB")
}

do {
    // Any controller can be learned and mapped. Its notes/CCs must not inherit
    // the FLX4 preset unless an FLX4 is actually connected.
    let generic = FLX4Engine()
    generic.flx4PresetEnabled = false
    let loaded = OSCMessage("/Syndicate/Deck/1/PlayerType", [.string("track")])
    _ = generic.handle(packet: .message(loaded))
    check(osc(generic.handle(midi: [0x90, 11, 127])).isEmpty,
          "without the FLX4 preset a stock PLAY note is inert")
    check(osc(generic.handle(midi: [0xb0, 0x13, 0x40, 0xb0, 0x33, 0x00])).isEmpty,
          "without the FLX4 preset a stock channel fader is inert")

    generic.userMappings = [ControlMapping(source: .midiNote, channel: 0, number: 20,
                                           address: "/Syndicate/Deck/1/PlayPause", mode: .trigger)]
    equal(osc(generic.handle(midi: [0x90, 20, 127])).first?.0,
          "/Syndicate/Deck/1/PlayPause", "a learned mapping works on a generic controller")

    generic.beginLearn(.midi)
    let captured = learned(generic.handle(midi: [0xb2, 0x15, 0x40]))
    equal(captured?.number, 21, "learn captures a generic controller CC")
    generic.cancelLearn()
    check(osc(generic.handle(midi: [0x80, 11, 0])).isEmpty,
          "releasing an inert stock press stays silent")

    let flx4 = FLX4Engine()
    _ = flx4.handle(packet: .message(loaded))
    equal(osc(flx4.handle(midi: [0x90, 11, 127])).first?.0,
          "/Syndicate/Deck/1/PlayPause", "the preset is on by default for an FLX4")
}

do {
    let engine = FLX4Engine()
    engine.userMappings = [ControlMapping(source: .midiNote, channel: 0, number: 20,
                                          address: "/Syndicate/Deck/1/Cue", mode: .momentary)]
    equal(osc(engine.handle(midi: [0x90, 20, 127])).first?.1, .int(1), "momentary press")
    equal(osc(engine.handle(midi: [0x80, 20, 0])).first?.1, .int(0), "momentary release")
}

do {
    // Tapping a learned 14-bit fader must keep sending on every move, not just
    // the first one: the editor used to save these as Trigger, but even an
    // Absolute mapping needs its LSB pairing to survive repeated sweeps.
    let engine = FLX4Engine()
    engine.userMappings = [ControlMapping(source: .midiCC, channel: 0, number: 0,
                                          address: "/Syndicate/Header/MasterVolume",
                                          mode: .absolute, minimum: 0, maximum: 1)]
    let first = osc(engine.handle(midi: [0xb0, 0x00, 0x00, 0xb0, 0x20, 0x00]))
    let second = osc(engine.handle(midi: [0xb0, 0x00, 0x20, 0xb0, 0x20, 0x00]))
    let third = osc(engine.handle(midi: [0xb0, 0x00, 0x40, 0xb0, 0x20, 0x00]))
    equal(first.first?.0, "/Syndicate/Header/MasterVolume", "learned tempo fader sends its first move")
    equal(second.first?.0, "/Syndicate/Header/MasterVolume", "learned tempo fader sends its second move")
    if case .float(let value)? = second.first?.1 {
        check(abs(value - 0.25) < 0.001, "learned tempo fader tracks the second position")
    } else {
        check(false, "learned tempo fader must send a float")
    }
    if case .float(let value)? = third.first?.1 {
        check(abs(value - 0.5) < 0.001, "learned tempo fader tracks the third position")
    } else {
        check(false, "learned tempo fader must keep sending")
    }
}

do {
    let engine = FLX4Engine()
    engine.userMappings = [ControlMapping(source: .midiCC, channel: 0, number: 19,
                                          address: "/Syndicate/Mixer/CH1/Volume",
                                          mode: .absolute, minimum: 0, maximum: 1)]
    check(osc(engine.handle(midi: [0xb0, 0x13, 0x60])).isEmpty, "14-bit learned fader waits for its LSB")
    let output = osc(engine.handle(midi: [0xb0, 0x33, 0x00]))
    equal(output.first?.0, "/Syndicate/Mixer/CH1/Volume", "learned fader sends its route")
    if case .float(let value)? = output.first?.1 {
        check(abs(value - 0.75) < 0.001, "learned fader keeps 14-bit precision")
    } else {
        check(false, "learned fader must send a float")
    }
}

do {
    let engine = FLX4Engine()
    engine.userMappings = [ControlMapping(source: .midiCC, channel: 4, number: 2,
                                          address: "/Syndicate/Header/MasterVolume",
                                          mode: .absolute, minimum: 0, maximum: 1)]
    let output = osc(engine.handle(midi: [0xb4, 0x02, 0x40]))
    equal(output.first?.0, "/Syndicate/Header/MasterVolume", "7-bit learned CC sends immediately")
}

do {
    let engine = FLX4Engine()
    engine.userMappings = [ControlMapping(source: .midiCC, channel: 4, number: 2,
                                          address: "/Syndicate/Mixer/CH1/Filter1",
                                          mode: .bipolar, minimum: -1, maximum: 1)]
    let low = osc(engine.handle(midi: [0xb4, 0x02, 0x00]))
    let center = osc(engine.handle(midi: [0xb4, 0x02, 0x40]))
    let high = osc(engine.handle(midi: [0xb4, 0x02, 0x7f]))
    if case .float(let value)? = low.first?.1 { check(abs(value + 1) < 0.001, "7-bit bipolar low is -1") }
    if case .float(let value)? = center.first?.1 { check(abs(value) < 0.02, "7-bit bipolar center is 0") }
    if case .float(let value)? = high.first?.1 { check(abs(value - 1) < 0.001, "7-bit bipolar high is +1") }
}

do {
    let engine = FLX4Engine()
    engine.userMappings = [ControlMapping(source: .midiNote, channel: 0, number: 30,
                                          address: "/Syndicate/Header/Metronome", mode: .toggle)]
    _ = engine.handle(packet: .message(OSCMessage("/Syndicate/Header/Metronome", [.int(0)])))
    equal(osc(engine.handle(midi: [0x90, 30, 127])).first?.1, .int(1), "learned toggle reads feedback")
    _ = engine.handle(midi: [0x80, 30, 0])
    _ = engine.handle(packet: .message(OSCMessage("/Syndicate/Header/Metronome", [.int(1)])))
    equal(osc(engine.handle(midi: [0x90, 30, 127])).first?.1, .int(0), "learned toggle flips from feedback")
}

do {
    let engine = FLX4Engine()
    let endpointID = UUID()
    engine.userMappings = [ControlMapping(source: .midiNote, channel: 0, number: 11,
                                          address: "/Syndicate/Deck/1/PlayPause",
                                          mode: .trigger, endpointID: endpointID)]
    let output = oscTo(engine.handle(midi: [0x90, 11, 127]))
    equal(output.first?.0, "/Syndicate/Deck/1/PlayPause", "mapping can target an extra destination")
    equal(output.first?.2, endpointID, "mapping carries its endpoint id")
}

do {
    let engine = FLX4Engine()
    engine.userMappings = [ControlMapping(source: .serial, control: "/esp/knob1",
                                          address: "/Syndicate/Mixer/CH1/Trim",
                                          mode: .absolute, minimum: 0, maximum: 1)]
    check(engine.mapping(forSerial: "/esp/knob1") != nil, "serial mapping is indexed")
    let output = osc(engine.handle(serial: OSCMessage("/esp/knob1", [.float(0.25)])))
    equal(output.first?.0, "/Syndicate/Mixer/CH1/Trim", "serial control reaches its route")
    if case .float(let value)? = output.first?.1 {
        check(abs(value - 0.25) < 0.001, "serial absolute value")
    } else {
        check(false, "serial absolute mapping must send a float")
    }
    check(engine.handle(serial: OSCMessage("/esp/other", [.float(1)])).isEmpty, "unmapped serial message passes through")
}

do {
    let engine = FLX4Engine()
    engine.beginLearn(.serial)
    let captured = learned(engine.handle(serial: OSCMessage("/esp/button/play", [.int(1)])))
    equal(captured?.source, .serial, "serial learn captures the control address")
    equal(captured?.control, "/esp/button/play", "serial learn keeps the address")
}

do {
    // The Nexus 4 encoder sends one signed detent per message. Relative mode has
    // to forward that delta as an int, so a mapped route moves with the knob.
    let turn = LearnedControl(source: .serial, control: "/Nexus/Encoder/1",
                              label: "Serial /Nexus/Encoder/1")
    check(turn.isRelativeSource, "an encoder turn is a relative source")
    check(!LearnedControl(source: .serial, control: "/Nexus/Encoder/1/Push", label: "push")
        .isRelativeSource, "the encoder switch is not a relative source")
    check(!LearnedControl(source: .serial, control: "/Nexus/Fader/1", label: "fader")
        .isRelativeSource, "a fader is not a relative source")

    let engine = FLX4Engine()
    engine.userMappings = [ControlMapping(source: .serial, control: "/Nexus/Encoder/1",
                                          address: "/Syndicate/Deck/{deck}/BeatSkip",
                                          mode: .relative, deck: 2)]
    let forward = osc(engine.handle(serial: OSCMessage("/Nexus/Encoder/1", [.int(1)])))
    equal(forward.first?.0, "/Syndicate/Deck/2/BeatSkip", "encoder turn reaches its route")
    equal(forward.first?.1, .int(1), "encoder turn forwards the signed delta")
    let back = osc(engine.handle(serial: OSCMessage("/Nexus/Encoder/1", [.int(-1)])))
    equal(back.first?.1, .int(-1), "anticlockwise turn forwards a negative delta")
    check(engine.handle(serial: OSCMessage("/Nexus/Encoder/1", [.int(0)])).isEmpty,
          "a zero-delta encoder message is ignored")

    // A browser wheel is two routes, not one parameter: one trigger per detent
    // to the route for that direction, which is what the FLX4 encoder does.
    engine.userMappings = [ControlMapping(source: .serial, control: "/Nexus/Encoder/1",
                                          address: "/Syndicate/Browser/Up",
                                          reverseAddress: "/Syndicate/Browser/Down",
                                          mode: .relative)]
    let scrollUp = osc(engine.handle(serial: OSCMessage("/Nexus/Encoder/1", [.int(1)])))
    equal(scrollUp.count, 1, "one detent sends one browser step")
    equal(scrollUp.first?.0, "/Syndicate/Browser/Up", "clockwise scrolls up")
    equal(scrollUp.first?.1, .int(1), "a browser step is a trigger")
    let scrollDown = osc(engine.handle(serial: OSCMessage("/Nexus/Encoder/1", [.int(-1)])))
    equal(scrollDown.first?.0, "/Syndicate/Browser/Down", "anticlockwise scrolls down")
    let fastSpin = osc(engine.handle(serial: OSCMessage("/Nexus/Encoder/1", [.int(3)])))
    equal(fastSpin.count, 3, "a fast spin repeats the step")
    check(fastSpin.allSatisfy { $0.0 == "/Syndicate/Browser/Up" }, "every step goes the same way")

    let decked = [ControlMapping(source: .serial, control: "/Nexus/Encoder/1",
                                 address: "/Syndicate/Deck/{deck}/PitchUp",
                                 reverseAddress: "/Syndicate/Deck/{deck}/PitchDown",
                                 mode: .relative, deck: 3)]
    engine.userMappings = decked
    equal(osc(engine.handle(serial: OSCMessage("/Nexus/Encoder/1", [.int(-1)]))).first?.0,
          "/Syndicate/Deck/3/PitchDown", "the reverse route resolves the deck placeholder")

    let encoded = try! JSONEncoder().encode(decked)
    let decoded = try! JSONDecoder().decode([ControlMapping].self, from: encoded)
    equal(decoded.first?.reverseAddress, "/Syndicate/Deck/{deck}/PitchDown",
          "a reverse route survives saving")

    let push = LearnedControl(source: .serial, control: "/Nexus/Encoder/1/Push",
                              label: "Serial /Nexus/Encoder/1/Push")
    engine.userMappings = [ControlMapping(source: .serial, control: push.control,
                                          address: "/Syndicate/Deck/1/PlayPause",
                                          mode: .momentary)]
    let down = osc(engine.handle(serial: OSCMessage("/Nexus/Encoder/1/Push", [.int(1)])))
    equal(down.first?.0, "/Syndicate/Deck/1/PlayPause", "encoder press reaches its route")
    equal(down.first?.1, .int(1), "encoder press sends 1")
    let up = osc(engine.handle(serial: OSCMessage("/Nexus/Encoder/1/Push", [.int(0)])))
    equal(up.first?.1, .int(0), "encoder release sends 0")

    // The switch sends 1 then 0. A command fires once per click, so the release
    // must be swallowed: two Browser/Enter triggers stepped two menu levels.
    engine.userMappings = [ControlMapping(source: .serial, control: "/Nexus/Encoder/1/Push",
                                          address: "/Syndicate/Browser/Enter",
                                          mode: .trigger)]
    equal(osc(engine.handle(serial: OSCMessage("/Nexus/Encoder/1/Push", [.int(1)]))).count, 1,
          "one click of the encoder switch fires one command")
    check(osc(engine.handle(serial: OSCMessage("/Nexus/Encoder/1/Push", [.int(0)]))).isEmpty,
          "the switch release does not fire the command again")
    equal(osc(engine.handle(serial: OSCMessage("/Nexus/Encoder/1/Push", [.float(0.4)]))).count, 1,
          "a partial value is not mistaken for a release")

    engine.userMappings = [ControlMapping(source: .serial, control: "/Nexus/Encoder/1/Push",
                                          address: "/Syndicate/Deck/1/Reverse",
                                          mode: .toggle)]
    _ = engine.handle(packet: .message(OSCMessage("/Syndicate/Deck/1/Reverse", [.int(0)])))
    equal(osc(engine.handle(serial: OSCMessage("/Nexus/Encoder/1/Push", [.int(1)]))).first?.1,
          .int(1), "the switch toggles on press")
    check(osc(engine.handle(serial: OSCMessage("/Nexus/Encoder/1/Push", [.int(0)]))).isEmpty,
          "the switch release does not toggle again")

    // A signed-delta source saved as a press mode loses one direction, so a
    // loaded mapping is repaired to Relative.
    let turnPath = NSTemporaryDirectory() + "flxbridge-relative-\\(UUID().uuidString).json"
    let turnStore = MappingStore(path: turnPath)
    turnStore.add(ControlMapping(source: .serial, control: "/Nexus/Encoder/1",
                                 address: "/Syndicate/Browser/Down", mode: .momentary))
    let repaired = MappingStore(path: turnPath)
    equal(repaired.mappings.first?.mode, .relative,
          "an encoder turn saved as Momentary loads as Relative")
    try? FileManager.default.removeItem(atPath: turnPath)
}

do {
    // Serial input is classified before it reaches the mapping engine: link
    // housekeeping is consumed, the encoder is mappable-only, everything else
    // is ordinary controller input.
    equal(SerialInputRouter.kind(for: "/Nexus/Pong"), .housekeeping, "pong is housekeeping")
    equal(SerialInputRouter.kind(for: "/Nexus/Track/2"), .housekeeping, "track echo is housekeeping")
    equal(SerialInputRouter.kind(for: "/Nexus/NeedTrack/3"), .housekeeping, "metadata request is housekeeping")
    equal(SerialInputRouter.kind(for: "/Nexus/Encoder/1"), .mappable, "encoder turn is mappable input")
    equal(SerialInputRouter.kind(for: "/Nexus/Encoder/1/Push"), .mappable, "encoder press is mappable input")
    equal(SerialInputRouter.kind(for: "/Deck/1/PlayPause"), .control, "a button stays controller input")
    equal(SerialInputRouter.kind(for: "/Nexus/Other"), .control, "unlisted routes still pass through")

    // Pre-rename firmware still speaks /Aether; it is classified the same way.
    equal(SerialInputRouter.kind(for: "/Aether/Pong"), .housekeeping, "a legacy pong is housekeeping")
    equal(SerialInputRouter.kind(for: "/Aether/Encoder/1"), .mappable, "a legacy encoder turn is mappable")
}

do {
    // The rename from /Aether to /Nexus is handled at the boundary so no other
    // code has to know both names exist.
    equal(NexusAddress.canonical("/Aether/Encoder/1"), "/Nexus/Encoder/1",
          "the legacy prefix is folded onto /Nexus")
    equal(NexusAddress.canonical("/Aether"), "/Nexus", "the bare legacy prefix is folded too")
    equal(NexusAddress.canonical("/Nexus/Encoder/1"), "/Nexus/Encoder/1",
          "the current prefix is left alone")
    equal(NexusAddress.canonical("/Syndicate/Deck/1/PlayPause"),
          "/Syndicate/Deck/1/PlayPause", "another namespace is untouched")
    equal(NexusAddress.ping, "/Nexus/Ping", "the board is pinged on its own namespace")
}

do {
    // A mapping learned against the old namespace keeps working after the
    // rename: the store rewrites the control address as it loads.
    let path = NSTemporaryDirectory() + "cuewire-rename-\(UUID().uuidString).json"
    let store = MappingStore(path: path)
    store.add(ControlMapping(source: .serial, control: "/Aether/Encoder/1",
                             address: "/Syndicate/Browser/Up", mode: .relative))
    let reloaded = MappingStore(path: path)
    equal(reloaded.mappings.first?.control, "/Nexus/Encoder/1",
          "a mapping learned on /Aether loads on /Nexus")
    try? FileManager.default.removeItem(atPath: path)
}

do {
    let engine = FLX4Engine()
    engine.beginLearn(.osc)
    check(learned(engine.handle(serial: OSCMessage("/esp/x", [.int(1)]))) == nil,
          "OSC-only learn ignores serial input")
    let captured = learned(engine.handle(osc: OSCMessage("/touch/play", [.int(1)])))
    equal(captured?.source, .osc, "UDP OSC learn captures its source")
    equal(captured?.control, "/touch/play", "UDP OSC learn keeps the address")
}

do {
    let engine = FLX4Engine()
    engine.userMappings = [ControlMapping(source: .osc, control: "/touch/knob",
                                          address: "/Syndicate/Mixer/CH2/Volume",
                                          mode: .absolute, minimum: 0, maximum: 1)]
    let output = osc(engine.handle(osc: OSCMessage("/touch/knob", [.float(0.75)])))
    equal(output.first?.0, "/Syndicate/Mixer/CH2/Volume", "UDP OSC mapping reaches its route")
    if case .float(let value)? = output.first?.1 {
        check(abs(value - 0.75) < 0.001, "UDP OSC mapping value")
    } else {
        check(false, "UDP OSC mapping must send a float")
    }
}

// MARK: - Serial transport loopback (pseudo-terminal, no hardware)

do {
    let master = posix_openpt(O_RDWR | O_NOCTTY | O_NONBLOCK)
    var started = false
    if master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) {
        let path = String(cString: name)
        let transport = SerialTransport()
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        transport.onFrame = { packet, _ in
            box.message = packet.messages.first
            semaphore.signal()
        }
        do {
            try transport.start(path: path, baud: 115_200, framing: .slip)
            started = true
            let payload = [UInt8](OSCSerialCodec.slip(OSCEncoder.encode(
                OSCMessage("/esp/knob1", [.float(0.25)]))))
            _ = write(master, payload, payload.count)
            let result = semaphore.wait(timeout: .now() + 2)
            check(result == .success, "serial transport reads a SLIP frame from a PTY")
            equal(box.message?.address, "/esp/knob1", "serial transport address")
            if case .float(let value)? = box.message?.arguments.first {
                check(abs(value - 0.25) < 0.001, "serial transport float value")
            } else {
                check(false, "serial transport must deliver the float argument")
            }

            // The reverse direction is how LEDs/feedback reach the controller.
            transport.send(OSCMessage("/esp/led", [.int(1)]))
            var buffer = [UInt8](repeating: 0, count: 256)
            var readCount = 0
            for _ in 0..<10 where readCount <= 0 {
                usleep(20_000)
                readCount = read(master, &buffer, buffer.count)
            }
            check(readCount > 0, "serial transport writes back to the controller")
            if readCount > 0 {
                // The master sees the raw SLIP frame, so decode through the framer.
                var framer = OSCSerialFramer(framing: .slip)
                let decoded = framer.feed(Array(buffer[0..<readCount]))
                equal(decoded.first?.messages.first?.address, "/esp/led", "serial transport SLIP-encodes feedback")
            }
            transport.stop()
        } catch {
            check(false, "serial transport failed to start: \(error.localizedDescription)")
        }
        if started { close(master) }
    } else {
        print("SKIP serial PTY loopback: could not allocate a pseudo-terminal")
        if master >= 0 { close(master) }
    }
}

// MARK: - Latency

do {
    let monitor = LatencyMonitor()
    monitor.record(milliseconds: 1, source: .midi)
    monitor.record(milliseconds: 3, source: .midi)
    monitor.record(milliseconds: 2, source: .midi)
    let stats = monitor.stats(.midi)
    equal(stats.count, 3, "latency sample count")
    equal(stats.p50, 2, "latency p50")
    equal(stats.p95, 3, "latency p95")
    equal(stats.maximum, 3, "latency maximum")
    equal(monitor.stats(.serial).count, 0, "separate sources have separate stats")

    let sent = Date(timeIntervalSince1970: 100)
    monitor.expectFeedback(address: "/Syndicate/Deck/1/PlayPause", at: sent)
    let roundTrip = monitor.recordFeedback(address: "/Syndicate/Deck/1/PlayPause",
                                           at: sent.addingTimeInterval(0.010))
    check(roundTrip != nil && abs(roundTrip! - 10) < 0.001, "feedback round trip uses the canonical namespace")
    check(monitor.recordFeedback(address: "/Syndicate/Deck/1/PlayPause",
                                 at: sent.addingTimeInterval(0.02)) == nil, "a probe is consumed once")
    monitor.expectFeedback(address: "/Syndicate/Deck/1/Cue", at: sent)
    check(monitor.recordFeedback(address: "/Syndicate/Deck/1/Cue",
                                 at: sent.addingTimeInterval(2)) == nil, "stale probes expire")
    equal(monitor.roundTrip.count, 1, "round-trip stats collect")

    // The serial ping has its own series, so it cannot be confused with the
    // Syndicate feedback probe above.
    monitor.recordLinkRoundTrip(milliseconds: 2)
    monitor.recordLinkRoundTrip(milliseconds: 4)
    monitor.recordLinkRoundTrip(milliseconds: 6)
    equal(monitor.linkRoundTrip.count, 3, "serial ping samples collect")
    equal(monitor.linkRoundTrip.p50, 4, "serial ping p50")
    equal(monitor.recentLinkRoundTrips(limit: 2), [4, 6], "the trace keeps the newest samples")
    check(monitor.recentLinkRoundTrips(limit: 0).isEmpty, "a zero-length trace is empty")
    monitor.recordLinkRoundTrip(milliseconds: -1)
    monitor.recordLinkRoundTrip(milliseconds: .nan)
    equal(monitor.linkRoundTrip.count, 3, "invalid ping samples are ignored")

    equal(monitor.recent(.midi, limit: 2), [3, 2], "input traces are oldest first")
    check(monitor.recent(.osc, limit: 8).isEmpty, "an unused path has no trace")
}

// MARK: - UDP loopback

final class Box: @unchecked Sendable {
    var message: OSCMessage?
    var error: String?
}

do {
    let receiver = OSCTransport()
    let sender = OSCTransport()
    let box = Box()
    let semaphore = DispatchSemaphore(value: 0)
    var bound = true
    do {
        try receiver.start(destination: "127.0.0.1", port: 19197, bindPort: 19196)
        try sender.start(destination: "127.0.0.1", port: 19196, bindPort: 19197)
    } catch {
        bound = false
        print("SKIP UDP loopback: \(error.localizedDescription)")
    }
    if bound {
        receiver.onPacket = { packet in
            if case .message(let message) = packet { box.message = message }
            semaphore.signal()
        }
        receiver.onError = { box.error = $0 }
        sender.send(OSCMessage("/Syndicate/Deck/1/Sync", [.int(1)]))
        let result = semaphore.wait(timeout: .now() + 2)
        check(result == .success, "UDP loopback delivered a packet")
        equal(box.message?.address, "/Syndicate/Deck/1/Sync", "UDP loopback address")
        equal(box.message?.firstInt, 1, "UDP loopback value")
        receiver.stop()
        sender.stop()
    }
}

// MARK: - UDP wildcard bind

/// The Mac's LAN address, so a check can prove the control port accepts packets
/// that do not arrive over loopback.
func localIPv4Address() -> String? {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return nil }
    defer { freeifaddrs(head) }
    for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(interface.pointee.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
              let address = interface.pointee.ifa_addr,
              address.pointee.sa_family == UInt8(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                          &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        return String(cString: host)
    }
    return nil
}

do {
    if let host = localIPv4Address() {
        let receiver = OSCTransport()
        let sender = OSCTransport()
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        var bound = true
        do {
            try receiver.start(destination: "127.0.0.1", port: 19199,
                               bindPort: 19198, bindHost: "0.0.0.0")
            try sender.start(destination: host, port: 19198, bindPort: 19199)
        } catch {
            bound = false
            print("SKIP UDP wildcard bind: \(error.localizedDescription)")
        }
        if bound {
            receiver.onPacket = { packet in
                if case .message(let message) = packet { box.message = message }
                semaphore.signal()
            }
            // Sent to the interface address, not 127.0.0.1: a loopback-only
            // bind would drop this, which is what a controller on the LAN hits.
            sender.send(OSCMessage("/touch/play", [.int(1)]))
            let result = semaphore.wait(timeout: .now() + 2)
            check(result == .success, "wildcard OSC bind accepts a packet from the LAN address")
            equal(box.message?.address, "/touch/play", "wildcard OSC bind keeps the address")
            receiver.stop()
            sender.stop()
        }
    } else {
        print("SKIP UDP wildcard bind: no non-loopback IPv4 interface")
    }
}

// MARK: - Serial feedback mirroring

do {
    var mirror = SerialFeedbackMirror()
    let playing = OSCPacket.message(OSCMessage("/Syndicate/Deck/2/Playing", [.int(1)]))
    let mirrored = mirror.messages(for: playing)
    equal(mirrored.count, 1, "deck play state mirrors without any mapping")
    equal(mirrored.first?.address, "/Syndicate/Deck/2/Playing", "deck play state uses the command namespace")
    equal(mirrored.first?.firstInt, 1, "deck play state keeps its value")

    let start = Date()
    equal(mirror.messages(for: playing, at: start).count, 0, "repeated deck play state is dropped")
    equal(mirror.messages(for: playing, at: start.addingTimeInterval(0.4)).count, 0,
          "repeat inside the refresh window is dropped")
    equal(mirror.messages(for: playing, at: start.addingTimeInterval(1.5)).count, 1,
          "unchanged deck play state is refreshed so a rebooted controller catches up")

    let stopped = mirror.messages(for: .message(OSCMessage("/Syndicate/Deck/2/Playing", [.int(0)])), at: start)
    equal(stopped.count, 1, "changed deck play state is mirrored")
    equal(stopped.first?.firstInt, 0, "changed deck play state keeps its value")

    mirror.reset()
    equal(mirror.messages(for: playing).count, 1, "reset forces the next state out")

    let meter = OSCPacket.message(OSCMessage("/Syndicate/Mixer/CH1/Meter", [.float(0.5)]))
    equal(mirror.messages(for: meter).count, 0, "mixer feedback is not mirrored")

    // Track metadata reaches the board, but only when it changes.
    let track = OSCPacket.message(OSCMessage("/Syndicate/Deck/2/TrackInfo", [
        .string("EsDeeKid, Timothee Chalamet - 4raws (Whethan Remix)"), .string("EsDeeKid"),
        .string("-"), .float(129), .float(134.17), .int(72), .int(287), .string("track"),
    ]))
    let trackOut = mirror.messages(for: track, at: start)
    equal(trackOut.count, 1, "track info is mirrored")
    equal(trackOut.first?.address, "/Syndicate/Deck/2/TrackInfo", "track info keeps its address")
    equal(trackOut.first?.arguments.count, 8, "every track info field is forwarded")
    equal(mirror.messages(for: track, at: start.addingTimeInterval(0.2)).count, 0,
          "unchanged track info is dropped")

    // Playhead feedback is rate limited rather than deduped.
    let progress = OSCPacket.message(OSCMessage("/Syndicate/Deck/2/Progress", [.float(0.25)]))
    equal(mirror.messages(for: progress, at: start).count, 1, "progress is mirrored")
    equal(mirror.messages(for: progress, at: start.addingTimeInterval(0.02)).count, 0,
          "progress inside the window is throttled")
    let later = mirror.messages(for: .message(OSCMessage("/Syndicate/Deck/2/Progress", [.float(0.26)])),
                                at: start.addingTimeInterval(0.15))
    equal(later.count, 1, "progress past the window is forwarded")
    equal(later.first?.firstFloat, 0.26, "progress keeps its value")

    mirror.setOwned([FLX4Engine.canonical("/Syndicate/Deck/3/PlayPause")])
    let mapped = mirror.messages(for: .message(OSCMessage("/Syndicate/Deck/3/PlayPause", [.int(1)])))
    equal(mapped.count, 1, "owned mapping feedback still mirrors")
    equal(mapped.first?.address, "/Syndicate/Deck/3/PlayPause", "owned mapping keeps its address")
    equal(mirror.messages(for: .message(OSCMessage("/Syndicate/Deck/4/PlayPause", [.int(1)]))).count, 0,
          "feedback for an unmapped deck stays off the wire")

    let bundle = OSCPacket.bundle([
        .message(OSCMessage("/Syndicate/Deck/1/Playing", [.int(1)])),
        .message(OSCMessage("/Syndicate/Deck/1/Bpm", [.float(120)])),
    ])
    let fromBundle = mirror.messages(for: bundle)
    equal(fromBundle.count, 2, "bundles are filtered message by message")
    equal(fromBundle.map(\.address), ["/Syndicate/Deck/1/Playing", "/Syndicate/Deck/1/Bpm"],
          "a bundle keeps both deck routes")

    // A board that reboots gets the change-only metadata replayed, without the
    // playhead (which would be stale).
    let replay = mirror.snapshot().map(\.address)
    check(replay.contains("/Syndicate/Deck/2/TrackInfo"), "snapshot replays track info")
    check(replay.contains("/Syndicate/Deck/1/Playing"), "snapshot replays play state")
    check(!replay.contains("/Syndicate/Deck/2/Progress"), "snapshot skips the playhead")
    check(replay == replay.sorted(), "snapshot order is stable")
}

// MARK: - Derived play state

do {
    let start = Date()
    var tracker = DeckPlaybackTracker(timeout: 0.6)
    check(tracker.states(at: start).isEmpty, "an untouched tracker reports nothing")

    let progress = OSCPacket.message(OSCMessage("/Syndicate/Deck/2/Progress", [.float(0.1)]))
    tracker.observe(progress, at: start)
    equal(tracker.states(at: start)[2], true, "a moving position reads as playing")
    equal(tracker.states(at: start.addingTimeInterval(0.3))[2], true, "play state holds inside the timeout")
    equal(tracker.states(at: start.addingTimeInterval(1.0))[2], false, "a stalled position reads as paused")
    equal(tracker.states(at: start.addingTimeInterval(1.0))[1], nil, "a deck that never reported stays unknown")

    let later = start.addingTimeInterval(1.0)
    tracker.observe(.message(OSCMessage("/Syndicate/Deck/3/Position", [.float(12)])), at: later)
    equal(tracker.states(at: later)[3], true, "position counts as well as progress")
    equal(tracker.states(at: later)[2], false, "one deck moving does not make another play")

    check(DeckPlaybackTracker.deck(in: "/Syndicate/Deck/4/Progress") == 4, "deck number is parsed")
    check(DeckPlaybackTracker.deck(in: "/Syndicate/Mixer/CH1/Meter") == nil, "non-deck paths have no deck")
    check(DeckPlaybackTracker.deck(in: "/Syndicate/Deck/9/Progress") == nil, "out-of-range decks are ignored")
    check(DeckPlaybackTracker.isPosition("/Syndicate/Deck/1/Progress"), "progress is a position")
    check(!DeckPlaybackTracker.isPosition("/Syndicate/Deck/1/Playing"), "playing is not a position")

    tracker.reset()
    check(tracker.states(at: start).isEmpty, "reset forgets every deck")

    // End to end: derived state becomes the message the panels expect, once.
    var mirror = SerialFeedbackMirror()
    var derive = DeckPlaybackTracker()
    derive.observe(progress, at: start)
    let states = derive.states(at: start)
    let packet = OSCPacket.bundle(states.keys.sorted().map { deck in
        .message(OSCMessage("/Syndicate/Deck/\(deck)/Playing", [.int(states[deck] == true ? 1 : 0)]))
    })
    let out = mirror.messages(for: packet, at: start)
    equal(out.count, 1, "derived play state reaches the serial mirror")
    equal(out.first?.address, "/Syndicate/Deck/2/Playing", "derived play state uses the deck address")
    equal(out.first?.firstInt, 1, "derived play state carries playing")
    equal(mirror.messages(for: packet, at: start.addingTimeInterval(0.3)).count, 0,
          "derived play state is not repeated inside the refresh window")
}

// MARK: - Serial port recovery

do {
    let saved = "/dev/cu.usbserial-A5069RR4"
    let renamed = "/dev/cu.usbmodem11301"

    equal(SerialTransport.resolve(configured: saved, available: [saved]), saved,
          "a saved port is reused while it is present")
    equal(SerialTransport.resolve(configured: saved, available: [renamed]), renamed,
          "a missing saved port falls back to the one that appeared")
    equal(SerialTransport.resolve(configured: "", available: [saved]), saved,
          "auto-detect picks the only port")
    equal(SerialTransport.resolve(configured: "", available: []), nil,
          "no ports means nothing to open")
    equal(SerialTransport.resolve(configured: saved, available: [
        "/dev/cu.Bluetooth-Incoming-Port", renamed,
    ]), renamed, "auto-detect prefers a USB controller over a stray port")
    equal(SerialTransport.resolve(configured: saved, available: [
        "/dev/cu.Bluetooth-Incoming-Port",
    ]), nil, "a stale saved port never opens an unrelated device")
}

// MARK: - Dead descriptor detection

do {
    let path = NSTemporaryDirectory() + "cuewire-stale-check-\(UUID().uuidString)"
    FileManager.default.createFile(atPath: path, contents: Data())
    let identity = SerialTransport.deviceIdentity(path)
    check(identity != nil, "a device node has an identity")
    check(!SerialTransport.isStale(path: path, identity: identity),
          "an intact device is not stale")
    try? FileManager.default.removeItem(atPath: path)
    check(SerialTransport.isStale(path: path, identity: identity),
          "a vanished device reads stale")
    check(SerialTransport.isStale(path: nil, identity: identity), "no path is stale")
    check(SerialTransport.isStale(path: path, identity: nil), "no captured identity is stale")

    // A replaced device (different inode) must be reopened rather than reused.
    FileManager.default.createFile(atPath: path, contents: Data())
    let replaced = SerialTransport.deviceIdentity(path)
    check(replaced != nil, "the replacement node has an identity")
    let wrong = (replaced ?? 0) == 0 ? UInt64(1) : UInt64(0)
    check(SerialTransport.isStale(path: path, identity: wrong),
          "a different device identity reads stale (first=\(String(describing: identity)) now=\(String(describing: replaced)))")
    try? FileManager.default.removeItem(atPath: path)
}

// MARK: - Cached deck metadata

do {
    var cache = DeckMetadataCache()
    let track = OSCMessage("/Syndicate/Deck/2/TrackInfo", [
        .string("Artist - Track (Extended Mix)"), .string("Artist"), .string("11A"),
        .float(128.0), .float(301.5), .int(0), .int(0), .string("track"),
    ])

    equal(DeckMetadataCache.deckNumber(in: "/Syndicate/Deck/2/TrackInfo"), 2,
          "deck number parses from a mirrored address")
    equal(DeckMetadataCache.deckNumber(in: "/Syndicate/Deck/4/Loaded"), 4,
          "deck number parses from a Syndicate address")
    equal(DeckMetadataCache.deckNumber(in: "/Syndicate/Mixer/CH1/Volume"), nil,
          "a mixer address has no deck")

    check(cache.record(trackInfo: track), "track info is cached")
    check(!cache.record(trackInfo: track), "an identical track info is not recorded twice")
    equal(cache.decks[2]?.title, "Artist - Track (Extended Mix)", "the title is kept")
    equal(cache.decks[2]?.artist, "Artist", "the artist is kept")
    equal(cache.decks[2]?.bpm, 128.0, "the BPM is kept")
    equal(cache.decks[2]?.duration, 301.5, "the duration is kept")
    equal(cache.decks[2]?.key, "11A", "the musical key is kept")

    // `-` is Syndicate for "no key"; it must not reach the card as a key.
    var dashKey = DeckMetadataCache()
    _ = dashKey.record(trackInfo: OSCMessage("/Syndicate/Deck/1/TrackInfo", [
        .string("A"), .string("B"), .string("-"), .float(120), .float(200),
    ]))
    equal(dashKey.decks[1]?.key, "", "a dash key is stored empty")

    // Syndicate sends an empty TrackInfo for an empty deck. Caching it makes
    // the board mark the card loaded with no title and ask for it forever.
    check(dashKey.record(trackInfo: OSCMessage("/Syndicate/Deck/1/TrackInfo", [
        .string(""), .string(""), .string("-"), .float(0), .float(0),
    ])), "an empty track info clears the deck")
    equal(dashKey.decks[1], nil, "an empty deck is not kept")
    equal(dashKey.message(for: 1), nil, "an empty deck has nothing to replay")

    let replay = cache.messages()
    equal(replay.count, 1, "one cached deck replays one message")
    equal(replay.first?.address, "/Syndicate/Deck/2/TrackInfo", "replay uses the deck address")
    equal(replay.first?.arguments.count, 8, "replay keeps the TrackInfo shape")
    if case .string(let key) = replay.first?.arguments[2] {
        equal(key, "11A", "replay keeps the musical key")
    } else {
        check(false, "replay must send the key as a string")
    }

    let restored = DeckMetadataCache.decode((try? cache.encoded()) ?? Data())
    equal(restored, cache, "metadata survives a relaunch")

    equal(cache.message(for: 2)?.address, "/Syndicate/Deck/2/TrackInfo",
          "one deck can be replayed on request")
    equal(cache.message(for: 3), nil, "a deck with no metadata has nothing to replay")

    check(cache.clear(deck: 2), "an unloaded deck is forgotten")
    check(cache.messages().isEmpty, "a forgotten deck is not replayed")

    // The live tempo is separate from the track tempo and is replayed too.
    var live = DeckMetadataCache()
    _ = live.record(trackInfo: track)  // 128 BPM file tempo
    equal(live.decks[2]?.currentBpm, 128.0, "a new track starts at its own tempo")
    check(live.liveBpmMessage(for: 2) == nil, "no live tempo is sent when it matches the file")
    check(live.recordLiveBpm(deck: 2, bpm: 125.5), "a live tempo is recorded")
    equal(live.liveBpmMessage(for: 2)?.address, "/Syndicate/Deck/2/BPM",
          "the live tempo replays on its own route")
    if let sent = live.liveBpmMessage(for: 2)?.firstFloat {
        check(abs(sent - 125.5) < 0.01, "the live tempo value survives")
    } else {
        check(false, "the live tempo must carry its value")
    }

    // The session tempo is cached so a reconnect starts at the right number.
    check(live.recordMasterTempo(128.5), "the session tempo is cached")
    check(!live.recordMasterTempo(128.5), "an unchanged session tempo is not rewritten")
    equal(live.masterTempoMessage()?.address, "/Syndicate/Header/BPM",
          "the session tempo replays on the header route")

    // Loading a different track drops the old live tempo.
    _ = live.record(trackInfo: OSCMessage("/Syndicate/Deck/2/TrackInfo", [
        .string("Other Track"), .string("Artist"), .string("-"),
        .float(140.0), .float(200.0), .int(0), .int(0), .string("track"),
    ]))
    equal(live.decks[2]?.currentBpm, 140.0, "a new track resets the live tempo")

    // SYNC is change-only upstream, so it is cached and replayed too.
    check(live.recordSync(deck: 2, synced: true), "deck sync is cached")
    equal(live.syncMessage(for: 2)?.address, "/Syndicate/Deck/2/Sync",
          "deck sync replays on its own route")
    equal(live.syncMessage(for: 2)?.firstInt, 1, "deck sync keeps its value")
    check(!live.recordSync(deck: 2, synced: true), "an unchanged sync flag is not rewritten")
    equal(live.decks[2]?.currentBpm, 128.5, "a synced deck takes the header tempo exactly")
    check(live.recordMasterTempo(130.0), "a moved session tempo is cached")
    equal(live.decks[2]?.currentBpm, 130.0, "a synced deck follows the header tempo")

    // A relaunch restores synced=true with the file's tempo. The first header
    // frame must repair that even though the header value did not change.
    var stale = DeckMetadataCache(
        decks: [1: DeckMetadata(title: "T", artist: "A", bpm: 132, currentBpm: 132,
                                synced: true, duration: 200)],
        masterTempo: 129)
    check(stale.recordMasterTempo(129), "a stale synced deck is repaired")
    equal(stale.decks[1]?.currentBpm, 129.0, "the repair uses the header tempo")
    var staleSync = DeckMetadataCache(
        decks: [1: DeckMetadata(title: "T", artist: "A", bpm: 132, currentBpm: 132,
                                synced: true, duration: 200)],
        masterTempo: 129)
    check(staleSync.recordSync(deck: 1, synced: true), "a stale sync replay is repaired")
    equal(staleSync.decks[1]?.currentBpm, 129.0, "the repaired sync keeps the header tempo")

    // Loading another track on a synced deck must not show the file's BPM while
    // the playhead is stopped: the deck is still pulled to the session tempo.
    _ = live.record(trackInfo: OSCMessage("/Syndicate/Deck/2/TrackInfo", [
        .string("Third Track"), .string("Artist"), .string("-"),
        .float(136.0), .float(200.0), .int(0), .int(0), .string("track"),
    ]))
    equal(live.decks[2]?.currentBpm, 130.0,
          "a new track on a synced deck takes the session tempo")

    // A long title must survive the round trip unchanged.
    var longCache = DeckMetadataCache()
    let longTitle = String(repeating: "A", count: 120)
    _ = longCache.record(trackInfo: OSCMessage("/Syndicate/Deck/1/TrackInfo", [
        .string(longTitle), .string("Artist"), .string("-"), .float(120), .float(200),
    ]))
    equal(longCache.decks[1]?.title, longTitle, "a 120-character title is kept whole")
}

// MARK: - Tempo and master feedback

do {
    var mirror = SerialFeedbackMirror()
    let t0 = Date(timeIntervalSince1970: 2_000)

    let header = OSCPacket.message(OSCMessage("/Syndicate/Header/BPM", [.float(128.5)]))
    let headerOut = mirror.messages(for: header, at: t0)
    equal(headerOut.count, 1, "the session tempo reaches the board")
    equal(headerOut.first?.address, "/Syndicate/Header/BPM",
          "the session tempo uses the header route")
    equal(mirror.messages(for: header, at: t0.addingTimeInterval(0.05)).count, 0,
          "the session tempo is throttled like the playhead")
    equal(mirror.messages(for: header, at: t0.addingTimeInterval(0.2)).count, 1,
          "the session tempo resumes after the throttle")

    // The master clock is an int beat within the bar, published once per beat.
    // The board's dots follow it instead of counting from a playhead.
    let clockOne = OSCPacket.message(OSCMessage("/Syndicate/Header/Clock", [.int(1)]))
    let firstClock = mirror.messages(for: clockOne, at: t0.addingTimeInterval(2))
    equal(firstClock.first?.address, "/Syndicate/Header/Clock", "the master clock reaches the board")
    equal(firstClock.first?.firstInt, 1, "the clock keeps its beat number")
    equal(mirror.messages(for: clockOne, at: t0.addingTimeInterval(2.05)).count, 0,
          "a repeated beat inside the refresh window is dropped")
    let clockTwo = OSCPacket.message(OSCMessage("/Syndicate/Header/Clock", [.int(2)]))
    equal(mirror.messages(for: clockTwo, at: t0.addingTimeInterval(2.1)).first?.firstInt, 2,
          "the next beat is not throttled")
    equal(mirror.messages(for: OSCPacket.message(OSCMessage("/Syndicate/Header/Clock", [.int(3)])),
                          at: t0.addingTimeInterval(2.2)).first?.address,
          "/Syndicate/Header/Clock", "clock beats keep the header route")

    let sync = OSCPacket.message(OSCMessage("/Syndicate/Deck/2/Sync", [.int(1)]))
    let syncOut = mirror.messages(for: sync, at: t0.addingTimeInterval(1))
    equal(syncOut.first?.address, "/Syndicate/Deck/2/Sync", "deck sync reaches the board")
    equal(syncOut.first?.firstInt, 1, "deck sync keeps its value")

    // The documented current tempo is mirrored verbatim: no derivation, no
    // smoothing, so 132.0 reaches the card as 132.0.
    let live = OSCPacket.message(OSCMessage("/Syndicate/Deck/3/BPM", [.float(132.0)]))
    let liveOut = mirror.messages(for: live, at: t0.addingTimeInterval(1.1))
    equal(liveOut.first?.address, "/Syndicate/Deck/3/BPM", "deck BPM reaches the board")
    equal(liveOut.first?.firstFloat, 132.0, "deck BPM keeps its exact value")

    // TempoSliderEnabled distinguishes the master from a follower at the same
    // tempo. It has to be mirrored (and replayed) for the board to use it.
    let slider = OSCPacket.message(OSCMessage("/Syndicate/Deck/3/TempoSliderEnabled", [.int(1)]))
    let sliderOut = mirror.messages(for: slider, at: t0.addingTimeInterval(1.2))
    equal(sliderOut.first?.address, "/Syndicate/Deck/3/TempoSliderEnabled",
          "tempo slider availability reaches the board")
    equal(sliderOut.first?.firstInt, 1, "tempo slider availability keeps its value")
    check(mirror.snapshot().contains { $0.address == "/Syndicate/Deck/3/TempoSliderEnabled" },
          "tempo slider availability is replayed after a board reboot")
}

// MARK: - Live tempo from position

do {
    let t0 = Date(timeIntervalSince1970: 3_000)

    // Feed `seconds` of motion at a constant ratio and return the latest fit.
    func fed(_ tracker: inout DeckTempoTracker, rate: Double, seconds: Double,
             from start: Date, position: Double, jitter: Bool = false) -> (Double?, Double, Date) {
        var last: Double?
        var p = position
        var t = start
        let steps = Int(seconds / 0.01)
        for step in 1...steps {
            p += 0.01 * rate
            // Deterministic ±1 ms arrival wobble, which is what the serial link
            // and the OSC socket actually add.
            let wobble = jitter ? Double((step % 5) - 2) * 0.0005 : 0
            t = start.addingTimeInterval(Double(step) * 0.01 + wobble)
            last = tracker.observe(deck: 1, position: p, at: t)
        }
        return (last, p, t)
    }

    var normal = DeckTempoTracker()
    let normalRate = fed(&normal, rate: 1.0, seconds: 2.0, from: t0, position: 10).0
    check(normalRate.map { abs($0 - 1.0) < 0.002 } ?? false, "a deck at 0% pitch reads 1.0x")

    var fast = DeckTempoTracker()
    let fastRate = fed(&fast, rate: 1.2, seconds: 2.0, from: t0, position: 10).0
    check(fastRate.map { abs($0 - 1.2) < 0.005 } ?? false, "a pitched deck reads its pitch ratio")
    check(abs(120.0 * (fastRate ?? 0) - 144.0) < 1.0, "track tempo times the ratio is the live tempo")

    // A stationary deck measures 0.9996 from float positions; the card must read
    // its exact tempo (132.0), not 132.1.
    var still = DeckTempoTracker()
    let stillRate = fed(&still, rate: 0.9996, seconds: 3.0, from: t0, position: 10).0
    check(stillRate == 1.0, "a stationary deck snaps to exactly 1.0x")

    // Arrival jitter must not sway the number a tenth of a BPM.
    var jittered = DeckTempoTracker()
    let jitteredRate = fed(&jittered, rate: 1.0, seconds: 3.0, from: t0, position: 10, jitter: true).0
    check(jitteredRate.map { abs($0 - 1.0) < 0.0025 } ?? false,
          "a 1 ms arrival wobble stays inside 0.25 BPM")

    // A fader move must settle in about a second, not three.
    var step = DeckTempoTracker()
    let first = fed(&step, rate: 1.0, seconds: 2.0, from: t0, position: 10)
    let settled = fed(&step, rate: 1.04, seconds: 1.2, from: first.2, position: first.1)
    check(settled.0.map { $0 > 1.025 } ?? false, "a 4% fader move is followed within 1.2s")

    // A seek backwards must not be read as a tempo.
    let held = fast.rate(for: 1)
    _ = fast.observe(deck: 1, position: 2.0, at: t0.addingTimeInterval(10))
    equal(fast.rate(for: 1), held, "a backwards jump keeps the last tempo")

    // A single sample is not enough to measure anything.
    var fresh = DeckTempoTracker()
    check(fresh.observe(deck: 2, position: 10.0, at: t0) == nil, "one sample has no tempo")
    _ = fresh.observe(deck: 2, position: 10.1, at: t0.addingTimeInterval(0.05))
    check(fresh.rate(for: 2) == nil, "a too-short span has no tempo")

    fresh.forget(deck: 2)
    check(fresh.rate(for: 2) == nil, "forgetting a deck clears its tempo")
}

// MARK: - Displaying a measured tempo

do {
    // Native tempo plus measurement bias must read the host's whole BPM, not
    // 129.1. This is the bounce the card used to show.
    equal(LiveTempoDisplay.value(trackBpm: 129, rate: 1.0004), 129.0,
          "a hair above native tempo snaps to the whole BPM")
    equal(LiveTempoDisplay.value(trackBpm: 129, rate: 0.9996), 129.0,
          "a hair below native tempo snaps to the whole BPM")
    // Noise around the native tempo used to read 129.1 on a 129 BPM track.
    equal(LiveTempoDisplay.value(trackBpm: 129, rate: 1.0015), 129.0,
          "a tenth of measurement error still reads the host's whole BPM")
    equal(LiveTempoDisplay.value(trackBpm: 129, rate: 1.0021), 129.0,
          "two tenths above native is still the whole BPM")
    // A real move keeps its tenth.
    equal(LiveTempoDisplay.value(trackBpm: 129, rate: 1.004), 129.5,
          "a fader move beyond the snap keeps a decimal")
    equal(LiveTempoDisplay.value(trackBpm: 128, rate: 1.25), 160.0, "a 25% move is exact")

    // A value sitting on a boundary must not replace the number on screen.
    check(!LiveTempoDisplay.shouldReplace(previous: 129.0, raw: 129.2),
          "a fifth inside the deadband is held")
    check(LiveTempoDisplay.shouldReplace(previous: 129.0, raw: 129.4),
          "a clear move replaces the number")
    check(LiveTempoDisplay.shouldReplace(previous: nil, raw: 129.0),
          "the first reading is always shown")
}

// MARK: - Serial link heartbeat

do {
    let t0 = Date(timeIntervalSince1970: 1_000)
    var beat = SerialHeartbeat()
    beat.opened(at: t0)

    check(beat.pingDue(at: t0), "a fresh link pings immediately")
    check(!beat.pingDue(at: t0.addingTimeInterval(0.5)), "pings are not spammed")
    check(beat.pingDue(at: t0.addingTimeInterval(2.1)), "pings resume after the interval")

    // A board that answers is never reopened, however long it is run.
    var healthy = beat
    var time = t0
    var restarts = 0
    for _ in 0..<60 {
        time = time.addingTimeInterval(2)
        _ = healthy.recordPong(at: time)
        if healthy.shouldRestart(at: time) { restarts += 1 }
    }
    equal(restarts, 0, "an answering link is left alone")

    // A silent one is reopened, but not in a tight loop.
    var dead = beat
    dead.opened(at: t0)
    check(!dead.shouldRestart(at: t0.addingTimeInterval(5)), "5s of silence is still tolerated")
    check(dead.shouldRestart(at: t0.addingTimeInterval(6.5)), "6s of silence reopens the port")
    check(!dead.shouldRestart(at: t0.addingTimeInterval(7)), "the reopen is rate limited")
    check(dead.shouldRestart(at: t0.addingTimeInterval(13)), "a still-silent link retries later")
    equal(dead.restarts, 2, "each reopen is counted")

    var silentPing = beat
    silentPing.opened(at: t0)
    _ = silentPing.pingDue(at: t0)
    check(!silentPing.shouldRestart(at: t0.addingTimeInterval(4)), "pinging keeps the link alive briefly")

    // Pong gaps tell the host the board rebooted, so change-only state is replayed.
    var resync = SerialHeartbeat()
    resync.opened(at: t0)
    equal(resync.recordPong(at: t0.addingTimeInterval(1)), .linked, "the first pong links the port")
    equal(resync.recordPong(at: t0.addingTimeInterval(3)), .steady, "a steady pong does nothing")
    equal(resync.recordPong(at: t0.addingTimeInterval(9)), .resynced, "a gap in pongs resyncs")
    check(abs(resync.silence(at: t0.addingTimeInterval(11)) - 2) < 0.001, "silence is measured from the last pong")
}

print("\(passes) checks passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
