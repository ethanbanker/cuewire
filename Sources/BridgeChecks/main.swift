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
        _ = engine.handle(packet: .message(OSCMessage("/AutoPilot/Deck/\(deck)/PlayerType", [.string(player)])))
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
    let message = OSCMessage("/AutoPilot/Deck/1/Sync", [.int(1)])
    equal(try OSCDecoder.decode(OSCEncoder.encode(message)), .message(message), "OSC int round trip")

    let float = OSCMessage("/AutoPilot/Mixer/CH2/Volume", [.float(0.42)])
    equal(try OSCDecoder.decode(OSCEncoder.encode(float)), .message(float), "OSC float round trip")

    // AUTO/PILOT sends /Syndicate/ColorPalette as ,[iiii][iiii]… — arrays carry no
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
    equal(decodedPalette?.messages.first?.address, "/Syndicate/ColorPalette", "AP array feedback decodes")
    equal(decodedPalette?.messages.first?.arguments.count, 8, "AP array feedback keeps its elements")

    let text = OSCMessage("/AutoPilot/Deck/1/PlayerType", [.string("arrangement")])
    equal(try OSCDecoder.decode(OSCEncoder.encode(text)), .message(text), "OSC string round trip")

    let bundle = OSCPacket.bundle([
        .message(OSCMessage("/AutoPilot/Deck/1/Playing", [.float(1)])),
        .bundle([.message(OSCMessage("/AutoPilot/Mixer/CH1/Cue", [.int(0)]))]),
    ])
    let decoded = try OSCDecoder.decode(OSCEncoder.encode(bundle))
    equal(decoded.messages.map(\.address), ["/AutoPilot/Deck/1/Playing", "/AutoPilot/Mixer/CH1/Cue"],
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
    equal(play.first?.0, "/AutoPilot/Deck/1/PlayPause", "PLAY route")
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
    check(osc(effects).contains { $0.0 == "/AutoPilot/Feedback/Resend" }, "deck select requests a feedback resend")
}
do {
    let engine = engine()
    _ = engine.handle(midi: [0x90, 32, 127])
    equal(engine.snapshot().bankNames[0], "Beat jumps", "bank switch name")
    equal(engine.snapshot().padLabels[0].first, "-1", "bank switch pad label")
    _ = engine.handle(midi: [0x90, 32, 0])
    let sent = osc(engine.handle(midi: [0x97, 0, 100]))
    equal(sent.first?.0, "/AutoPilot/Deck/1/BeatSkip", "beat jump route")
    equal(sent.first?.1, .int(-1), "beat jump value")
}
do {
    let engine = engine()
    equal(osc(engine.handle(midi: [0x97, 2, 100])).first?.0, "/AutoPilot/Deck/1/Cue3", "hot cue pad")
    check(osc(engine.handle(midi: [0x98, 2, 100])).isEmpty, "unassigned shifted hot-cue pad")
}
do {
    let engine = engine(player: "arrangement")
    equal(engine.snapshot().bankNames[0], "Markers / pages", "arrangement bank name")
    equal(osc(engine.handle(midi: [0x97, 5, 100])).first?.0, "/AutoPilot/Deck/1/GridStart",
          "arrangement pad 6 is GridStart")
}
do {
    let engine = engine(player: "clip")
    check(osc(engine.handle(midi: [0x90, 16, 127])).isEmpty, "clip player blocks LoopIn")
    equal(osc(engine.handle(midi: [0x90, 11, 127])).first?.0, "/AutoPilot/Deck/1/Clip/PlayPause",
          "clip player translates PlayPause")
}
do {
    let engine = engine()
    _ = feedback(engine, "/AutoPilot/Deck/1/TempoSlider", 0.0)
    _ = engine.handle(midi: [0xb0, 0, 120])
    check(osc(engine.handle(midi: [0xb0, 32, 0])).isEmpty, "pickup waits for the control to cross")
    _ = engine.handle(midi: [0xb0, 0, 60])
    let sent = osc(engine.handle(midi: [0xb0, 32, 0]))
    equal(sent.first?.0, "/AutoPilot/Deck/1/TempoSlider", "pickup sends after crossing")
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
    _ = feedback(engine, "/AutoPilot/Deck/1/TempoSlider", 0.0)
    _ = engine.handle(midi: [0xb0, 0, 64])
    equal(osc(engine.handle(midi: [0xb0, 32, 0])).first?.1, .float(0), "tempo center is exactly zero")
}
do {
    let engine = engine()
    engine.analogPickup = false
    _ = feedback(engine, "/AutoPilot/Mixer/CH1/Filter1", 0.5)
    _ = engine.handle(midi: [0xb6, 0x17, 0x00])
    let sent = osc(engine.handle(midi: [0xb6, 0x37, 0x00]))
    equal(sent.first?.0, "/AutoPilot/Mixer/CH1/Filter1", "left half of the filter knob sends Filter1")
    if case .float(let value)? = sent.first?.1 {
        check(abs(value - 1) < 0.001, "filter knob at the left end is full low-pass")
    } else {
        check(false, "the filter knob must be sent as a float")
    }
    equal(sent.last?.0, "/AutoPilot/Mixer/CH1/Filter2", "the idle high-pass is reset too")
    if case .float(let value)? = sent.last?.1 {
        check(abs(value) < 0.001, "the idle high-pass is neutral")
    } else {
        check(false, "the filter knob must send both halves")
    }
    check(engine.snapshot().pickupEnabled == false, "snapshot reports absolute mode")
    check(engine.snapshot().pickup.isEmpty, "absolute mode has no pickup states")
}
do {
    let engine = engine()
    engine.analogPickup = false
    let effects = engine.handle(midi: [0xb6, 0x17, 0x7f, 0xb6, 0x37, 0x7f])
    let sent = osc(effects)
    check(sent.count == 2, "absolute mode sends both filter halves with no feedback")
    equal(sent.first?.0, "/AutoPilot/Mixer/CH1/Filter1", "right half releases the low-pass")
    equal(sent.last?.0, "/AutoPilot/Mixer/CH1/Filter2", "right half raises the high-pass")
    if case .float(let low)? = sent.first?.1, case .float(let high)? = sent.last?.1 {
        check(abs(low) < 0.001, "the low-pass is neutral on the right")
        check(abs(high - 1) < 0.001, "the right end is full high-pass")
    } else {
        check(false, "the filter knob must send both halves")
    }
    check(warnings(effects).isEmpty, "absolute mode never warns about pickup")
}
do {
    let engine = engine()
    engine.analogPickup = false
    _ = engine.handle(midi: [0xb6, 0x17, 0x40]) // centre: 8192 / 16383
    let centre = osc(engine.handle(midi: [0xb6, 0x37, 0x00]))
    check(centre.count == 2, "centre sends both filter halves")
    for message in centre {
        if case .float(let value) = message.1 {
            check(abs(value) < 0.001, "centre is neutral on both filters")
        } else {
            check(false, "the filter knob must be a float")
        }
    }
    _ = engine.handle(midi: [0xb6, 0x17, 0x70]) // 14336 / 16383 = 0.875
    let right = osc(engine.handle(midi: [0xb6, 0x37, 0x00]))
    if case .float(let low)? = right.first?.1, case .float(let high)? = right.last?.1 {
        check(abs(low) < 0.001, "right of centre leaves the low-pass neutral")
        check(abs(high - 0.75) < 0.001, "right of centre scales the high-pass")
    } else {
        check(false, "the filter knob must send both halves")
    }
}
do {
    let engine = engine()
    _ = feedback(engine, "/AutoPilot/Deck/1/TempoSlider", 0.0)
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
    _ = feedback(engine, "/AutoPilot/Mixer/CH1/Volume", 0.5)
    _ = engine.handle(midi: [0xb0, 0x13, 0x20])
    check(osc(engine.handle(midi: [0xb0, 0x33, 0x00])).isEmpty, "fader below the confirmed value waits")
    let packed = osc(engine.handle(midi: [0xb0, 0x13, 0x60, 0xb0, 0x33, 0x00]))
    equal(packed.first?.0, "/AutoPilot/Mixer/CH1/Volume", "packed fader packet reaches OSC")
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
    _ = feedback(engine, "/AutoPilot/Mixer/CH1/Volume", 0.5)
    _ = engine.handle(midi: [0xb0, 0x13, 0x20, 0x33, 0x00])
    equal(osc(engine.handle(midi: [0xb0, 0x13, 0x60, 0x33, 0x00])).first?.0,
          "/AutoPilot/Mixer/CH1/Volume", "running status keeps the fader stream alive")
}
do {
    let engine = engine()
    _ = feedback(engine, "/AutoPilot/Mixer/CH1/Trim", 0.5)
    _ = engine.handle(midi: [0xb0, 0x04, 0x20, 0xb0, 0x24, 0x00])
    equal(osc(engine.handle(midi: [0xb0, 0x04, 0x61, 0xb0, 0x24, 0x3e])).first?.0,
          "/AutoPilot/Mixer/CH1/Trim", "packed trim packet reaches OSC")
}
do {
    let engine = engine()
    _ = feedback(engine, "/AutoPilot/Mixer/CH1/EQ/High", 0.5)
    _ = engine.handle(midi: [0xb0, 0x07, 0x20, 0xb0, 0x27, 0x00])
    equal(osc(engine.handle(midi: [0xb0, 0x07, 0x60, 0xb0, 0x27, 0x00])).first?.0,
          "/AutoPilot/Mixer/CH1/EQ/High", "packed EQ packet reaches OSC")
}
do {
    let engine = engine()
    _ = feedback(engine, "/AutoPilot/Header/MasterVolume", 0.5)
    _ = engine.handle(midi: [0xb6, 0x08, 0x20, 0xb6, 0x28, 0x00])
    equal(osc(engine.handle(midi: [0xb6, 0x08, 0x47, 0xb6, 0x28, 0x17])).first?.0,
          "/AutoPilot/Header/MasterVolume", "packed master level packet reaches OSC")
}
do {
    let engine = engine()
    _ = feedback(engine, "/AutoPilot/Header/CueVolume", 0.4)
    _ = engine.handle(midi: [0xb6, 0x0d, 0x20, 0xb6, 0x2d, 0x00])
    equal(osc(engine.handle(midi: [0xb6, 0x0d, 0x39, 0xb6, 0x2d, 0x5a])).first?.0,
          "/AutoPilot/Header/CueVolume", "packed headphone level packet reaches OSC")
}
do {
    let engine = engine()
    let mix = osc(engine.handle(midi: [0xb6, 0x0c, 0x40, 0xb6, 0x2c, 0x00]))
    equal(mix.first?.0, "/AutoPilot/Header/CueMix", "headphone mix needs no feedback")
    if case .float(let value)? = mix.first?.1 {
        check(abs(value - 0.5) < 0.001, "headphone mix value is the 14-bit position")
    } else {
        check(false, "the headphone mix must be sent as a float")
    }
}
do {
    // AUTO/PILOT has no OSC address for the Beat FX depth knob or the jog wheel,
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
    equal(osc(after).first?.0, "/AutoPilot/Deck/1/PlayPause", "a message after SysEx still arrives")
    check(osc(engine.handle(midi: [0x36, 0x00])).isEmpty, "stray data bytes are ignored")
}
do {
    let engine = engine()
    _ = feedback(engine, "/AutoPilot/Mixer/CH1/Filter2", 0.3)
    _ = engine.handle(midi: [0x90, 63, 127])
    _ = engine.handle(midi: [0xb6, 23, 51]) // approach from above the confirmed 0.3
    _ = engine.handle(midi: [0xb6, 55, 0])
    _ = engine.handle(midi: [0xb6, 23, 32]) // cross the confirmed value
    equal(osc(engine.handle(midi: [0xb6, 55, 0])).first?.0, "/AutoPilot/Mixer/CH1/Filter2",
          "Shift+filter targets Filter2")
}
do {
    let engine = engine()
    equal(osc(engine.handle(midi: [0xb6, 64, 1])).first?.0, "/AutoPilot/Browser/Down", "encoder clockwise")
    equal(osc(engine.handle(midi: [0xb6, 64, 127])).first?.0, "/AutoPilot/Browser/Up", "encoder anticlockwise")
    check(osc(engine.handle(midi: [0xb6, 64, 64])).isEmpty, "encoder neutral")
}
do {
    let engine = engine()
    check(osc(engine.handle(midi: [0x90, 84, 127])).isEmpty, "cue toggle requires feedback")
    _ = engine.handle(midi: [0x80, 84, 0])
    _ = feedback(engine, "/AutoPilot/Mixer/CH1/Cue", 0)
    equal(osc(engine.handle(midi: [0x90, 84, 127])).first?.1, .int(1), "cue toggle on")
    _ = engine.handle(midi: [0x80, 84, 0])
    _ = feedback(engine, "/AutoPilot/Mixer/CH1/Cue", 1)
    equal(osc(engine.handle(midi: [0x90, 84, 127])).first?.1, .int(0), "cue toggle off")
}
do {
    let engine = engine()
    _ = engine.start()
    check(midi(feedback(engine, "/AutoPilot/Deck/1/Playing", 1)).contains([0x90, 11, 127]),
          "Playing feedback drives the PLAY LED")
    check(midi(feedback(engine, "/AutoPilot/Mixer/CH1/Meter", 0.5))
            .contains { $0[0] == 0xb0 && $0[1] == 2 && $0[2] > 50 }, "meter feedback drives CC 2")
    let invalid = feedback(engine, "/AutoPilot/Deck/1/Playing", 2)
    check(engine.snapshot().values["/autopilot/deck/1/playing"] == nil,
          "invalid switch feedback clears the confirmed value")
    check(!warnings(invalid).isEmpty, "invalid feedback warns")
}
do {
    let engine = engine()
    _ = engine.handle(midi: [0x90, 30, 127])
    _ = engine.handle(midi: [0x90, 30, 0])
    let pressed = osc(engine.handle(midi: [0x97, 0, 100]))
    equal(pressed.map(\.0), [
        "/AutoPilot/Deck/1/SlipDotted",
        "/AutoPilot/Deck/1/SlipTriplet",
        "/AutoPilot/Deck/1/SlipLoop/ThirtySecond",
    ], "slip hold applies timing then the loop")
    equal(pressed.last?.1, .int(1), "slip loop press")
    equal(osc(engine.handle(midi: [0x87, 0, 0])).first?.1, .int(0), "slip loop release")
}
do {
    let engine = engine()
    _ = engine.handle(midi: [0x90, 30, 127])
    _ = engine.handle(midi: [0x90, 30, 0])
    let latched = osc(engine.handle(midi: [0x97, 6, 100]))
    equal(latched.filter { $0.1 == .int(1) }.first?.0, "/AutoPilot/Deck/1/SlipDotted", "slip dotted latch")
    equal(engine.snapshot().slipTiming[1], .dotted, "latched timing appears in the snapshot")
}
do {
    let engine = engine()
    let effects = engine.handle(midi: [0x96, 122, 127])
    equal(engine.snapshot().selectedDecks, [0, 3], "right deck selector toggles 2 <-> 4")
    check(osc(effects).contains { $0.0 == "/AutoPilot/Feedback/Resend" }, "deck select resends feedback")
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

// MARK: - Startup and AUTO/PILOT detection

do {
    let engine = FLX4Engine()
    let effects = engine.start()
    check(osc(effects).contains { $0.0 == "/AutoPilot/Feedback/Resend" }, "start asks AP to resend feedback")
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
    let bridgePath = settingsFile(paths: ["/AutoPilot/Deck/1/Playing", "/AutoPilot/Mixer/CH1/Cue"])
    let detected = AutoPilotSettings.detect(path: bridgePath)
    equal(detected?.listenPort, 8001, "detected AP OSC listen port")
    equal(detected?.feedbackPort, 8000, "detected AP feedback port")
    equal(detected?.feedbackHost, "127.0.0.1", "detected AP feedback host")
    equal(detected?.hasBridgeSubscriptions, true, "AutoPilot subscriptions count as bridge routes")
    equal(detected?.namespace, "AutoPilot", "detected the AutoPilot namespace")
    equal(detected?.feedbackPaths.count, 2, "feedback paths are exposed to the catalog")
    try? FileManager.default.removeItem(atPath: bridgePath)

    let syndicatePath = settingsFile(paths: ["/Syndicate/Deck/1/Playing", "/Syndicate/Mixer/CH1/Cue"])
    let syndicate = AutoPilotSettings.detect(path: syndicatePath)
    equal(syndicate?.hasBridgeSubscriptions, true, "Syndicate subscriptions count as bridge routes")
    equal(syndicate?.namespace, "Syndicate", "detected the Syndicate namespace")
    try? FileManager.default.removeItem(atPath: syndicatePath)

    let foreignPath = settingsFile(paths: ["/Other/Thing"])
    let foreign = AutoPilotSettings.detect(path: foreignPath)
    equal(foreign?.hasBridgeSubscriptions, false, "foreign subscriptions are reported missing")
    try? FileManager.default.removeItem(atPath: foreignPath)

    check(AutoPilotSettings.detect(path: "/nonexistent/AutoPilot.settings") == nil, "missing settings are reported")
}

// MARK: - Namespace and feedback types

do {
    // Current AUTO/PILOT builds publish feedback under /Syndicate and send switches
    // as ints. Both must land on the same routes the bridge registered.
    let engine = FLX4Engine()
    _ = engine.handle(packet: .message(OSCMessage("/Syndicate/Deck/1/PlayerType", [.string("track")])))
    let play = osc(engine.handle(midi: [0x90, 11, 127]))
    equal(play.first?.0, "/AutoPilot/Deck/1/PlayPause", "Syndicate PlayerType unlocks deck routes")

    _ = engine.handle(packet: .message(OSCMessage("/Syndicate/Mixer/CH1/Cue", [.int(1)])))
    let cue = osc(engine.handle(midi: [0x90, 84, 127]))
    equal(cue.first?.0, "/AutoPilot/Mixer/CH1/Cue", "mixer cue toggles with Syndicate feedback")
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
    equal(FLX4Engine.canonical("/Syndicate/Deck/1/Playing"), "/autopilot/deck/1/playing", "Syndicate namespace folds onto AutoPilot")
    equal(FLX4Engine.canonical("/AutoPilot/Deck/1/Playing"), "/autopilot/deck/1/playing", "AutoPilot namespace is unchanged")
}

// MARK: - Serial OSC framing and parsing

do {
    let message = OSCMessage("/AutoPilot/Deck/1/PlayPause", [.int(1)])
    let frame = OSCSerialCodec.slip(OSCEncoder.encode(message))
    var framer = OSCSerialFramer(framing: .slip)
    let first = framer.feed(Array(frame.prefix(7)))
    check(first.isEmpty, "SLIP waits for the end delimiter")
    let rest = framer.feed(Array(frame.dropFirst(7)))
    equal(rest.first?.messages.first?.address, "/AutoPilot/Deck/1/PlayPause", "SLIP frame decodes")
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
    equal(AutoPilotCatalog.template("/Syndicate/Deck/2/Playing"),
          "/AutoPilot/Deck/{deck}/Playing", "deck feedback becomes a template")
    equal(AutoPilotCatalog.template("/Syndicate/Mixer/CH3/Volume"),
          "/AutoPilot/Mixer/CH{deck}/Volume", "mixer channel becomes a template")
    equal(AutoPilotCatalog.route(for: "/AutoPilot/Header/MasterVolume").kind, .continuous,
          "catalog knows a continuous header route")
    equal(AutoPilotCatalog.route(for: "/AutoPilot/Deck/1/PlayPause").kind, .trigger,
          "catalog knows a trigger route")
    check(AutoPilotCatalog.all(settings: nil).count > 80, "built-in catalog is populated")
    let builtInAddresses = AutoPilotCatalog.builtIn.map { $0.address }
    check(Set(builtInAddresses).count == builtInAddresses.count, "built-in catalog has unique addresses")

    let endpoint = OSCEndpoint(label: "Resolume", host: "127.0.0.1", port: 7001,
                               prefix: "/Resolume")
    equal(HubRouter.endpoint(for: "/Resolume/Layer1/Opacity", endpoints: [endpoint])?.label,
          "Resolume", "prefix routes to an extra destination")
    equal(HubRouter.endpoint(for: "/AutoPilot/Deck/1/PlayPause", endpoints: [endpoint])?.label,
          nil, "unmatched route falls back to AUTO/PILOT")
    let nested = OSCEndpoint(label: "Layer", host: "127.0.0.1", port: 7002,
                             prefix: "/Resolume/Layer")
    equal(HubRouter.endpoint(for: "/Resolume/Layer/1", endpoints: [endpoint, nested])?.label,
          "Layer", "longest prefix wins")
    equal(HubRouter.endpoint(for: "/Resolume/X", endpoints: [
        OSCEndpoint(label: "Off", host: "127.0.0.1", port: 7003, prefix: "/Resolume", enabled: false),
    ])?.label, nil, "disabled destinations are skipped")
    equal(HubRouter.commandAddress("/Deck/1/PlayPause"), "/AutoPilot/Deck/1/PlayPause", "short deck address expands")
    equal(HubRouter.commandAddress("/Mixer/CH1/Volume"), "/AutoPilot/Mixer/CH1/Volume", "short mixer address expands")
    equal(HubRouter.commandAddress("/Syndicate/Deck/1/Playing"), "/AutoPilot/Deck/1/Playing", "Syndicate folds to AutoPilot")
}

// MARK: - Mapping mode defaults

do {
    // A fader saved as Trigger sends one 1 and then nothing, which looks like a
    // dead mapping. Choosing the route must replace the editor's default mode.
    equal(MappingModeResolver.resolvedMode(for: "/AutoPilot/Header/MasterVolume", selected: .trigger),
          .absolute, "a continuous route never keeps the leftover Trigger")
    equal(MappingModeResolver.resolvedMode(for: "/AutoPilot/Deck/1/TempoSlider", selected: .trigger),
          .bipolar, "a bipolar route saves as Bipolar")
    equal(MappingModeResolver.resolvedMode(for: "/AutoPilot/Deck/1/PlayPause", selected: .trigger),
          .trigger, "a trigger route keeps Trigger")
    equal(MappingModeResolver.resolvedMode(for: "/MyApp/Volume", selected: .trigger),
          .absolute, "a typed continuous route also upgrades")
    equal(MappingModeResolver.resolvedMode(for: "/AutoPilot/Header/MasterVolume", selected: .absolute),
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
                                 address: "/AutoPilot/Deck/{deck}/PlayPause",
                                 mode: .trigger, deck: 2, endpointID: endpoint.id)
    store.add(mapping)
    check(store.save() == nil, "mapping store saves")
    let reloaded = MappingStore(path: path)
    equal(reloaded.mappings.count, 1, "mapping survives a reload")
    equal(reloaded.mappings.first?.resolvedAddress(), "/AutoPilot/Deck/2/PlayPause", "deck substitution survives")
    equal(reloaded.endpoints.first?.label, "TouchDesigner", "endpoint survives a reload")
    equal(reloaded.mappings.first?.endpointID, endpoint.id, "mapping keeps its destination")

    reloaded.removeEndpoint(id: endpoint.id)
    equal(reloaded.mappings.first?.endpointID, nil, "removing an endpoint clears mappings that used it")
    reloaded.add(ControlMapping(source: .midiNote, channel: 0, number: 11,
                                address: "/AutoPilot/Deck/1/Cue", mode: .trigger))
    equal(reloaded.mappings.count, 1, "a mapping with the same control replaces the old one")
    equal(reloaded.mappings.first?.address, "/AutoPilot/Deck/1/Cue", "replacement address")

    // Mutations persist without an explicit save, so the editor cannot lose a
    // mapping when the app quits straight after a Learn.
    reloaded.add(ControlMapping(source: .midiCC, channel: 0, number: 21,
                                address: "/AutoPilot/Header/CueVolume", mode: .absolute))
    let autoSaved = MappingStore(path: path)
    equal(autoSaved.mappings.count, 2, "mapping mutations auto-save")

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
    engine.userMappings = [captured!.draft(address: "/AutoPilot/Deck/1/Cue", mode: .trigger)]
    engine.cancelLearn()
    let output = osc(engine.handle(midi: [0x90, 11, 127]))
    equal(output.first?.0, "/AutoPilot/Deck/1/Cue", "user mapping overrides the stock PLAY route")
}

do {
    let engine = FLX4Engine()
    engine.beginLearn(.midi)
    let captured = learned(engine.handle(midi: [0xb0, 0x13, 0x40]))
    equal(captured?.source, .midiCC, "learn captures a CC fader")
    equal(captured?.number, 19, "FLX4 14-bit learn records the MSB control, not its LSB")
}

do {
    let engine = FLX4Engine()
    engine.userMappings = [ControlMapping(source: .midiNote, channel: 0, number: 20,
                                          address: "/AutoPilot/Deck/1/Cue", mode: .momentary)]
    equal(osc(engine.handle(midi: [0x90, 20, 127])).first?.1, .int(1), "momentary press")
    equal(osc(engine.handle(midi: [0x80, 20, 0])).first?.1, .int(0), "momentary release")
}

do {
    // Tapping a learned 14-bit fader must keep sending on every move, not just
    // the first one: the editor used to save these as Trigger, but even an
    // Absolute mapping needs its LSB pairing to survive repeated sweeps.
    let engine = FLX4Engine()
    engine.userMappings = [ControlMapping(source: .midiCC, channel: 0, number: 0,
                                          address: "/AutoPilot/Header/MasterVolume",
                                          mode: .absolute, minimum: 0, maximum: 1)]
    let first = osc(engine.handle(midi: [0xb0, 0x00, 0x00, 0xb0, 0x20, 0x00]))
    let second = osc(engine.handle(midi: [0xb0, 0x00, 0x20, 0xb0, 0x20, 0x00]))
    let third = osc(engine.handle(midi: [0xb0, 0x00, 0x40, 0xb0, 0x20, 0x00]))
    equal(first.first?.0, "/AutoPilot/Header/MasterVolume", "learned tempo fader sends its first move")
    equal(second.first?.0, "/AutoPilot/Header/MasterVolume", "learned tempo fader sends its second move")
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
                                          address: "/AutoPilot/Mixer/CH1/Volume",
                                          mode: .absolute, minimum: 0, maximum: 1)]
    check(osc(engine.handle(midi: [0xb0, 0x13, 0x60])).isEmpty, "14-bit learned fader waits for its LSB")
    let output = osc(engine.handle(midi: [0xb0, 0x33, 0x00]))
    equal(output.first?.0, "/AutoPilot/Mixer/CH1/Volume", "learned fader sends its route")
    if case .float(let value)? = output.first?.1 {
        check(abs(value - 0.75) < 0.001, "learned fader keeps 14-bit precision")
    } else {
        check(false, "learned fader must send a float")
    }
}

do {
    let engine = FLX4Engine()
    engine.userMappings = [ControlMapping(source: .midiCC, channel: 4, number: 2,
                                          address: "/AutoPilot/Header/MasterVolume",
                                          mode: .absolute, minimum: 0, maximum: 1)]
    let output = osc(engine.handle(midi: [0xb4, 0x02, 0x40]))
    equal(output.first?.0, "/AutoPilot/Header/MasterVolume", "7-bit learned CC sends immediately")
}

do {
    let engine = FLX4Engine()
    engine.userMappings = [ControlMapping(source: .midiCC, channel: 4, number: 2,
                                          address: "/AutoPilot/Mixer/CH1/Filter1",
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
                                          address: "/AutoPilot/Header/Metronome", mode: .toggle)]
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
                                          address: "/AutoPilot/Deck/1/PlayPause",
                                          mode: .trigger, endpointID: endpointID)]
    let output = oscTo(engine.handle(midi: [0x90, 11, 127]))
    equal(output.first?.0, "/AutoPilot/Deck/1/PlayPause", "mapping can target an extra destination")
    equal(output.first?.2, endpointID, "mapping carries its endpoint id")
}

do {
    let engine = FLX4Engine()
    engine.userMappings = [ControlMapping(source: .serial, control: "/esp/knob1",
                                          address: "/AutoPilot/Mixer/CH1/Trim",
                                          mode: .absolute, minimum: 0, maximum: 1)]
    check(engine.mapping(forSerial: "/esp/knob1") != nil, "serial mapping is indexed")
    let output = osc(engine.handle(serial: OSCMessage("/esp/knob1", [.float(0.25)])))
    equal(output.first?.0, "/AutoPilot/Mixer/CH1/Trim", "serial control reaches its route")
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
                                          address: "/AutoPilot/Mixer/CH2/Volume",
                                          mode: .absolute, minimum: 0, maximum: 1)]
    let output = osc(engine.handle(osc: OSCMessage("/touch/knob", [.float(0.75)])))
    equal(output.first?.0, "/AutoPilot/Mixer/CH2/Volume", "UDP OSC mapping reaches its route")
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
    monitor.expectFeedback(address: "/AutoPilot/Deck/1/PlayPause", at: sent)
    let roundTrip = monitor.recordFeedback(address: "/Syndicate/Deck/1/PlayPause",
                                           at: sent.addingTimeInterval(0.010))
    check(roundTrip != nil && abs(roundTrip! - 10) < 0.001, "feedback round trip uses the canonical namespace")
    check(monitor.recordFeedback(address: "/AutoPilot/Deck/1/PlayPause",
                                 at: sent.addingTimeInterval(0.02)) == nil, "a probe is consumed once")
    monitor.expectFeedback(address: "/AutoPilot/Deck/1/Cue", at: sent)
    check(monitor.recordFeedback(address: "/AutoPilot/Deck/1/Cue",
                                 at: sent.addingTimeInterval(2)) == nil, "stale probes expire")
    equal(monitor.roundTrip.count, 1, "round-trip stats collect")
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
        sender.send(OSCMessage("/AutoPilot/Deck/1/Sync", [.int(1)]))
        let result = semaphore.wait(timeout: .now() + 2)
        check(result == .success, "UDP loopback delivered a packet")
        equal(box.message?.address, "/AutoPilot/Deck/1/Sync", "UDP loopback address")
        equal(box.message?.firstInt, 1, "UDP loopback value")
        receiver.stop()
        sender.stop()
    }
}

print("\(passes) checks passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
