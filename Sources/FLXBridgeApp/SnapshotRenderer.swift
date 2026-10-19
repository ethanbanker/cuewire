import AppKit
import BridgeCore

/// Renders the surface offscreen with synthetic live state, so the drawing code can
/// be inspected (`FLXBridge --snapshot /tmp/surface.png`) without a display.
enum SnapshotRenderer {
    static func render(to path: String) throws {
        let engine = FLX4Engine()
        engine.analogPickup = false // match the app's default absolute faders/knobs
        for deck in 1...4 {
            _ = engine.handle(packet: .message(OSCMessage("/AutoPilot/Deck/\(deck)/PlayerType", [.string("track")])))
        }
        _ = engine.handle(packet: .message(OSCMessage("/AutoPilot/Deck/1/Playing", [.float(1)])))
        _ = engine.handle(packet: .message(OSCMessage("/AutoPilot/Deck/1/Sync", [.float(1)])))
        _ = engine.handle(packet: .message(OSCMessage("/AutoPilot/Mixer/CH1/Cue", [.float(1)])))
        _ = engine.handle(packet: .message(OSCMessage("/AutoPilot/Deck/1/TempoSlider", [.float(0.0)])))
        _ = engine.handle(packet: .message(OSCMessage("/AutoPilot/Mixer/CH1/Volume", [.float(0.72)])))
        _ = engine.handle(packet: .message(OSCMessage("/AutoPilot/Mixer/CH1/Meter", [.float(0.55)])))
        _ = engine.handle(midi: [0x90, 11, 127])   // PLAY pressed
        _ = engine.handle(midi: [0x97, 0, 127])    // hot cue 1 pressed
        _ = engine.handle(midi: [0x90, 32, 127])   // bank 2 on the left deck

        let canvas = SurfaceCanvas(frame: NSRect(x: 0, y: 0, width: 1120, height: 520))
        canvas.snapshot = engine.snapshot()
        canvas.layoutSubtreeIfNeeded()

        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            throw NSError(domain: "FLXBridge", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate an offscreen bitmap"])
        }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "FLXBridge", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not encode the snapshot"])
        }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
