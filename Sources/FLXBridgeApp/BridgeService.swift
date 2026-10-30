import BridgeCore
import Foundation

struct LogEntry {
    let date: Date
    let level: LogLevel
    let message: String
}

/// Owns the engine, the UDP socket and CoreMIDI, and publishes read-only state
/// to the AppKit UI. UI callbacks always arrive on the main thread.
final class BridgeService {
    static let shared = BridgeService()

    private(set) var snapshot = SurfaceSnapshot()
    private(set) var running = false
    private(set) var deviceConnected = false
    private(set) var midiInputs: [String] = []
    private(set) var midiOutputs: [String] = []
    private(set) var logs: [LogEntry] = []
    private(set) var lastError: String?
    private(set) var oscSent = 0
    private(set) var passthroughSent = 0
    private(set) var feedbackCount = 0
    private(set) var lastFeedback: Date?

    private(set) var destination: String
    private(set) var destinationPort: Int
    private(set) var feedbackPort: Int
    private(set) var controlInputPort: Int
    private(set) var autoStart: Bool
    /// Analog controls send their physical position immediately unless the user
    /// opts into soft takeover. DJ software (rekordbox, Serato) behaves this way.
    private(set) var analogPickup: Bool

    private(set) var serialConnected = false
    private(set) var serialPath: String?
    private(set) var serialPorts: [String] = []
    private(set) var serialFrames = 0
    private(set) var serialError: String?
    private(set) var serialEnabled: Bool
    private(set) var serialPort: String
    private(set) var serialBaud: Int
    private(set) var serialFraming: SerialFraming
    private(set) var mirrorSerialFeedback: Bool

    private(set) var latency: [LatencySource: LatencyStats] = [:]
    private(set) var roundTrip: LatencyStats = .empty
    private(set) var linkRoundTrip: LatencyStats = .empty
    /// Recent samples for the latency panel's sparklines.
    private(set) var latencyHistory: [LatencySource: [Double]] = [:]
    private(set) var linkRoundTripHistory: [Double] = []
    private(set) var learnState: LearnState = .off
    private(set) var lastLearned: LearnedControl?

    let mappingStore: MappingStore
    private(set) var mappings: [ControlMapping] = []
    private(set) var endpoints: [OSCEndpoint] = []

    var onChange: (() -> Void)?
    var onLearned: ((LearnedControl) -> Void)?

    private let engine = FLX4Engine()
    private let osc = OSCTransport()
    private let controlOSC = OSCTransport()
    private let midi = MIDITransport()
    private let serial = SerialTransport()
    private let latencyMonitor = LatencyMonitor()
    private let queue = DispatchQueue(label: "flxbridge.engine")
    private var timer: DispatchSourceTimer?
    private var lastPublish = Date.distantPast
    private var lastRefresh = Date.distantPast
    private var didAutoStart = false
    private var loggedFirstFeedback = false
    private var loggedFirstSend = false
    private var oscLogCount = 0
    private var loggedAddresses: Set<String> = []
    private var midiMessageCount = 0
    private var syndicate: SyndicateSettings?
    private var serialMirrorAddresses: Set<String> = []
    private var serialMirror = SerialFeedbackMirror()
    private var playback = DeckPlaybackTracker()
    private var serialDeviceIdentity: UInt64?
    private var heartbeat = SerialHeartbeat()
    private var serialPingSentAt: Date?
    private var loggedLinkRtt = 0
    private var loggedTracks: Set<String> = []
    private var loggedTrackAddresses: Set<String> = []
    private var loggedDeckMutations: Set<String> = []
    private var tempoTracker = DeckTempoTracker()
    private var lastLiveTempo: [Int: Double] = [:]
    private var lastTempoSentAt: [Int: Date] = [:]
    private var lastMetadataSave: Date = .distantPast
    private var lastHeaderTempoLog: Date = .distantPast
    /// First master-clock beat forwarded to a freshly connected board. One line
    /// is enough to show the clock is wired; every beat would flood the log.
    private var loggedClockBeat = false
    /// Deck titles/BPM survive a relaunch and cover a resend that was missed.
    private var deckMetadata = BridgeService.loadDeckMetadata()

    private static var deckMetadataPath: String {
        (MappingStore.defaultDirectory as NSString).appendingPathComponent("deck-metadata.json")
    }

    private static func loadDeckMetadata() -> DeckMetadataCache {
        guard let data = FileManager.default.contents(atPath: deckMetadataPath) else {
            return DeckMetadataCache()
        }
        return DeckMetadataCache.decode(data)
    }

    private func saveDeckMetadata() {
        do {
            try FileManager.default.createDirectory(atPath: MappingStore.defaultDirectory,
                                                    withIntermediateDirectories: true)
            try deckMetadata.encoded().write(to: URL(fileURLWithPath: Self.deckMetadataPath),
                                             options: .atomic)
        } catch {
            logAsync(.warn, "Could not save deck metadata: \(error.localizedDescription)")
        }
    }
    private var routingEndpoints: [OSCEndpoint] = []
    private var lastSerialError: String?
    private var loggedPassthrough: Set<String> = []
    private var serialRetryAt = Date.distantPast
    /// Last palette written to the pod strip, so an unchanged palette is not
    /// resent every tick.
    private var lastPodStripPalette: [String] = []
    private var lastPodStripRefresh = Date.distantPast

    private enum Keys {
        static let destination = "oscDestination"
        static let destinationPort = "oscDestinationPort"
        static let feedbackPort = "oscFeedbackPort"
        static let controlInputPort = "oscControlInputPort"
        static let autoStart = "autoStart"
        static let analogPickup = "analogPickup"
        static let serialEnabled = "serialEnabled"
        static let serialPort = "serialPort"
        static let serialBaud = "serialBaud"
        static let serialFraming = "serialFraming"
        static let mirrorSerialFeedback = "mirrorSerialFeedback"
    }

    private init() {
        let defaults = UserDefaults.standard
        let detected = SyndicateSettings.detect()
        syndicate = detected
        destination = defaults.string(forKey: Keys.destination)
            ?? detected?.feedbackHost
            ?? "127.0.0.1"
        destinationPort = BridgeService.integer(defaults, Keys.destinationPort)
            ?? detected?.listenPort
            ?? 9090
        feedbackPort = BridgeService.integer(defaults, Keys.feedbackPort)
            ?? detected?.feedbackPort
            ?? 9096
        controlInputPort = BridgeService.integer(defaults, Keys.controlInputPort) ?? 0
        autoStart = BridgeService.boolean(defaults, Keys.autoStart) ?? true
        analogPickup = BridgeService.boolean(defaults, Keys.analogPickup) ?? false
        serialEnabled = BridgeService.boolean(defaults, Keys.serialEnabled) ?? true
        serialPort = defaults.string(forKey: Keys.serialPort) ?? ""
        serialBaud = BridgeService.integer(defaults, Keys.serialBaud) ?? SerialTransport.defaultBaud
        serialFraming = SerialFraming(rawValue: defaults.string(forKey: Keys.serialFraming) ?? "") ?? .auto
        mirrorSerialFeedback = BridgeService.boolean(defaults, Keys.mirrorSerialFeedback) ?? true
        mappingStore = MappingStore()
        mappings = mappingStore.mappings
        endpoints = mappingStore.endpoints
        mappingStore.onChange = { [weak self] in self?.reloadMappings() }
        engine.userMappings = mappings
        refreshSerialMirror()
        routingEndpoints = endpoints
        serialMirror.setOwned(serialMirrorAddresses)
        serialPorts = SerialTransport.availablePorts()
    }

    /// UserDefaults returns command-line overrides (`-oscDestinationPort 19090`)
    /// as strings, so accept both representations.
    private static func integer(_ defaults: UserDefaults, _ key: String) -> Int? {
        if let value = defaults.object(forKey: key) as? Int { return value }
        if let value = defaults.object(forKey: key) as? NSNumber { return value.intValue }
        if let value = defaults.object(forKey: key) as? String { return Int(value) }
        return nil
    }

    /// Command-line overrides (`-serialEnabled NO`) arrive as strings, so accept
    /// the spellings UserDefaults writes for booleans as well as real Bools.
    private static func boolean(_ defaults: UserDefaults, _ key: String) -> Bool? {
        if let value = defaults.object(forKey: key) as? Bool { return value }
        if let value = defaults.object(forKey: key) as? NSNumber { return value.boolValue }
        if let value = defaults.object(forKey: key) as? String {
            switch value.lowercased() {
            case "yes", "true", "1": return true
            case "no", "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    func configure(destination: String, destinationPort: Int, feedbackPort: Int,
                   controlPort: Int = 0, autoStart: Bool, analogPickup: Bool? = nil) {
        self.destination = destination
        self.destinationPort = destinationPort
        self.feedbackPort = feedbackPort
        self.controlInputPort = controlPort
        self.autoStart = autoStart
        if let analogPickup { self.analogPickup = analogPickup }
        let defaults = UserDefaults.standard
        defaults.set(destination, forKey: Keys.destination)
        defaults.set(destinationPort, forKey: Keys.destinationPort)
        defaults.set(feedbackPort, forKey: Keys.feedbackPort)
        defaults.set(controlPort, forKey: Keys.controlInputPort)
        defaults.set(autoStart, forKey: Keys.autoStart)
        if let analogPickup { defaults.set(analogPickup, forKey: Keys.analogPickup) }
    }

    func configureSerial(enabled: Bool, port: String, baud: Int, framing: SerialFraming,
                         mirrorFeedback: Bool) {
        serialEnabled = enabled
        serialPort = port
        serialBaud = baud
        serialFraming = framing
        mirrorSerialFeedback = mirrorFeedback
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: Keys.serialEnabled)
        defaults.set(port, forKey: Keys.serialPort)
        defaults.set(baud, forKey: Keys.serialBaud)
        defaults.set(framing.rawValue, forKey: Keys.serialFraming)
        defaults.set(mirrorFeedback, forKey: Keys.mirrorSerialFeedback)
    }

    // MARK: - Hub mappings

    func reloadMappings() {
        let nextMappings = mappingStore.mappings
        let nextEndpoints = mappingStore.endpoints
        mappings = nextMappings
        endpoints = nextEndpoints
        refreshSerialMirror()
        let mirror = serialMirrorAddresses
        queue.async { [weak self] in
            guard let self else { return }
            self.engine.userMappings = nextMappings
            self.routingEndpoints = nextEndpoints
            self.serialMirror.setOwned(mirror)
            self.publish()
        }
        updateDestinations()
        notify()
    }

    private func refreshSerialMirror() {
        serialMirrorAddresses = Set(mappings.filter { $0.source == .serial && $0.enabled }
            .map { FLX4Engine.canonical($0.resolvedAddress()) })
    }

    private func updateDestinations() {
        osc.setDestinations(oscDestinations)
    }

    private var oscDestinations: [OSCDestination] {
        var list = [OSCDestination(host: destination, port: UInt16(max(1, min(65_535, destinationPort))))]
        for endpoint in endpoints where endpoint.enabled && endpoint.isValid {
            let target = OSCDestination(host: endpoint.host, port: UInt16(endpoint.port))
            if !list.contains(target) { list.append(target) }
        }
        return list
    }

    func addMapping(_ mapping: ControlMapping) {
        mappingStore.add(mapping)
    }

    func updateMapping(_ mapping: ControlMapping) {
        mappingStore.update(mapping)
    }

    func removeMapping(id: UUID) {
        mappingStore.remove(id: id)
    }

    func setMappingEnabled(_ enabled: Bool, id: UUID) {
        mappingStore.setEnabled(enabled, id: id)
    }

    func addEndpoint(_ endpoint: OSCEndpoint) {
        mappingStore.addEndpoint(endpoint)
    }

    func updateEndpoint(_ endpoint: OSCEndpoint) {
        mappingStore.updateEndpoint(endpoint)
    }

    func removeEndpoint(id: UUID) {
        mappingStore.removeEndpoint(id: id)
    }

    func beginLearn(_ filter: LearnFilter = .any) {
        queue.async { [weak self] in
            guard let self else { return }
            self.engine.beginLearn(filter)
            self.learnState = self.engine.learnState
            DispatchQueue.main.async { self.onChange?() }
        }
        lastLearned = nil
    }

    func cancelLearn() {
        queue.async { [weak self] in
            guard let self else { return }
            self.engine.cancelLearn()
            self.learnState = self.engine.learnState
            DispatchQueue.main.async { self.onChange?() }
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        guard (1...65535).contains(destinationPort), (1...65535).contains(feedbackPort) else {
            fail("Ports must be between 1 and 65535")
            return
        }
        osc.onPacket = { [weak self] packet in
            self?.queue.async {
                guard let self else { return }
                for message in packet.messages {
                    self.latencyMonitor.recordFeedback(address: message.address)
                }
                self.logTrackFeedback(packet)
                self.trackLiveTempo(packet)
                self.drain(self.engine.handle(packet: packet))
                // Syndicate never publishes Playing, so position movement is
                // what tells us a deck is running.
                self.playback.observe(packet)
                if self.mirrorSerialFeedback {
                    self.mirrorToSerial(packet)
                }
                self.serialFrames = self.serial.framesIn
            }
        }
        osc.onError = { [weak self] message in
            DispatchQueue.main.async { self?.log(.warn, message) }
        }
        // Register handlers *before* opening the MIDI client: the initial endpoint
        // scan happens inside start(), and watching the FLX4 already be present at
        // launch was previously lost, leaving the UI on "waiting" forever.
        midi.onMessage = { [weak self] bytes in
            let ingress = self?.latencyMonitor.begin() ?? 0
            self?.queue.async {
                guard let self else { return }
                self.midiMessageCount += 1
                // Show the first few reports so a silent controller is obvious.
                if self.midiMessageCount <= 8 {
                    let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                    DispatchQueue.main.async { [weak self] in
                        self?.log(.info, "MIDI input received: \(hex)")
                    }
                }
                self.drain(self.engine.handle(midi: bytes))
                self.latencyMonitor.finish(ingress, source: .midi)
            }
        }
        midi.onDevicesChanged = { [weak self] inputs, outputs in
            DispatchQueue.main.async {
                guard let self else { return }
                self.midiInputs = inputs
                self.midiOutputs = outputs
                self.syncMIDIState()
            }
        }
        midi.onError = { [weak self] message in
            DispatchQueue.main.async { self?.log(.warn, message) }
        }
        serial.onFrame = { [weak self] packet, ingress in
            self?.queue.async {
                guard let self else { return }
                self.handleSerial(packet: packet)
                self.serialFrames = self.serial.framesIn
                self.latencyMonitor.finish(ingress, source: .serial)
            }
        }
        serial.onError = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.serialError = message
                self.log(.warn, message)
            }
        }
        serial.onDisconnect = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.serialConnected = false
                self.serialPath = nil
                self.serialDeviceIdentity = nil
                self.serialRetryAt = .distantPast
                self.notify()
            }
        }
        do {
            try osc.start(destinations: oscDestinations, bindPort: UInt16(feedbackPort))
        } catch {
            fail(error.localizedDescription)
            return
        }
        startControlListener()
        do {
            try midi.start()
        } catch {
            osc.stop()
            controlOSC.stop()
            fail(error.localizedDescription)
            return
        }
        running = true
        lastError = nil
        midiMessageCount = 0
        deviceConnected = midi.connectedName != nil
        let nextMappings = mappings
        let nextEndpoints = endpoints
        let mirror = serialMirrorAddresses
        let flx4Present = midi.connectedNames.contains { MIDITransport.isFLX4($0) }
        queue.async { [weak self] in
            guard let self else { return }
            self.engine.userMappings = nextMappings
            self.engine.analogPickup = self.analogPickup
            self.engine.flx4PresetEnabled = flx4Present
            self.routingEndpoints = nextEndpoints
            self.serialMirror.setOwned(mirror)
            self.drain(self.engine.start())
        }
        startTimer()
        connectSerialIfNeeded(force: true)
        // Syndicate sends state on change only, so a freshly started bridge
        // knows neither the deck tempos nor the SYNC relationships until one of
        // them moves. The documented way to catch up is Feedback/Resend, which
        // replays every subscribed value (user guide 14.10).
        requestFeedbackResend()
        log(.info, "Bridge started: OSC to \(destination):\(destinationPort), feedback on \(feedbackPort)")
        logMIDIDiscovery()
        logSyndicateDiagnostics()
        logSerialDiscovery()
        notify()
    }

    private func startControlListener() {
        controlOSC.stop()
        guard controlInputPort > 0 else { return }
        guard (1...65_535).contains(controlInputPort) else {
            log(.warn, "OSC control input port \(controlInputPort) is out of range")
            return
        }
        guard controlInputPort != feedbackPort else {
            log(.warn, "OSC control input is disabled: it uses the same port as Syndicate feedback")
            return
        }
        controlOSC.onPacket = { [weak self] packet in
            let ingress = self?.latencyMonitor.begin() ?? 0
            self?.queue.async {
                guard let self else { return }
                self.handleExternalOSC(packet, source: .osc)
                self.latencyMonitor.finish(ingress, source: .osc)
            }
        }
        controlOSC.onError = { [weak self] message in
            DispatchQueue.main.async { self?.log(.warn, message) }
        }
        do {
            // Controllers send from the LAN: the control port binds every
            // interface, unlike the feedback socket, which only hears Syndicate
            // on this Mac.
            try controlOSC.start(destinations: oscDestinations, bindPort: UInt16(controlInputPort),
                                 bindHost: "0.0.0.0")
            log(.info, "OSC control input listening on 0.0.0.0:\(controlInputPort) (TouchOSC, OSC/PILOT, another bridge, etc.)")
        } catch {
            log(.warn, "OSC control input \(controlInputPort) unavailable: \(error.localizedDescription)")
        }
    }

    func stop(reason: String? = nil) {
        guard running else { return }
        timer?.cancel()
        timer = nil
        queue.sync {
            loggedFirstSend = false
            loggedAddresses.removeAll()
            oscLogCount = 0
            drain(engine.shutdown())
        }
        osc.stop()
        controlOSC.stop()
        midi.stop()
        serial.stop()
        running = false
        deviceConnected = false
        serialConnected = false
        serialPingSentAt = nil
        serialPath = nil
        serialDeviceIdentity = nil
        midiInputs = []
        midiOutputs = []
        log(.info, reason.map { "Bridge stopped: \($0)" } ?? "Bridge stopped")
        notify()
    }

    func toggle() {
        running ? stop() : start()
    }

    func startIfNeeded() {
        guard !didAutoStart else { return }
        didAutoStart = true
        if autoStart, !running { start() }
    }

    func applySettings() {
        let wasRunning = running
        if wasRunning { stop(reason: "settings changed") }
        if wasRunning { start() }
    }

    func reconnectMIDI() {
        do {
            try midi.start()
            midi.refresh(force: true)
            log(.info, "Rescanned MIDI ports")
            logMIDIDiscovery()
        } catch {
            log(.error, error.localizedDescription)
        }
        notify()
    }

    func reconnectSerial() {
        serial.stop()
        serialConnected = false
        serialPath = nil
        serialDeviceIdentity = nil
        connectSerialIfNeeded(force: true)
        notify()
    }

    // MARK: - Serial OSC

    private func connectSerialIfNeeded(force: Bool) {
        serialPorts = SerialTransport.availablePorts()
        guard serialEnabled else {
            if serial.isOpen { serial.stop() }
            serialConnected = false
            serialPath = nil
            return
        }
        if serial.isOpen {
            // A descriptor survives its device: unplugging the controller leaves
            // it open, so without this check the port is never reopened and the
            // user has to toggle Serial OSC to recover.
            if SerialTransport.isStale(path: serial.path, identity: serialDeviceIdentity) {
                logAsync(.info, "Serial device changed; reopening")
                serial.stop()
                serialConnected = false
                serialPath = nil
                serialDeviceIdentity = nil
                serialRetryAt = .distantPast
            } else {
                serialConnected = true
                return
            }
        }
        let now = Date()
        guard force || now >= serialRetryAt else { return }
        serialRetryAt = now.addingTimeInterval(1.5)
        let resolved = SerialTransport.resolve(configured: serialPort, available: serialPorts)
        do {
            try serial.start(path: resolved, baud: serialBaud, framing: serialFraming)
            if !serialPort.isEmpty && resolved != serialPort {
                logAsync(.info, "Configured port \(serialPort) is gone; using \(serial.path ?? "?")")
            }
            serialPath = serial.path
            serialDeviceIdentity = serial.path.flatMap { SerialTransport.deviceIdentity($0) }
            serialConnected = true
            loggedClockBeat = false
            heartbeat.opened(at: Date())
            serialPingSentAt = nil
            serialError = nil
            lastSerialError = nil
            // A freshly opened port usually means a freshly booted controller,
            // so republish the current deck state instead of waiting out the
            // refresh interval.
            queue.async { [weak self] in
                guard let self else { return }
                // A fresh port usually means a freshly booted board: replay what
                // Syndicate only sends on change (titles, BPM, loop state).
                self.serialMirror.reset()
                for message in self.serialMirror.snapshot() {
                    self.serial.send(message)
                }
            }
            logAsync(.info, "Serial OSC connected on \(serial.path ?? "?") at \(serialBaud) baud (\(serialFraming.rawValue))")
        } catch {
            serialConnected = false
            serialPath = nil
            serialError = error.localizedDescription
            if lastSerialError != serialError {
                lastSerialError = serialError
                logAsync(.info, "Serial OSC waiting: \(error.localizedDescription)")
            }
        }
    }

    private func logSerialDiscovery() {
        serialPorts = SerialTransport.availablePorts()
        if serialConnected {
            log(.info, "Serial OSC in use: \(serialPath ?? "?") · \(serialFraming.rawValue)")
        } else if serialEnabled {
            if serialPorts.isEmpty {
                log(.info, "No USB serial controller found; waiting for the ESP32-S3")
            } else {
                log(.info, "Serial ports seen: \(serialPorts.joined(separator: ", ")) (choose one in Settings)")
            }
        }
    }

    /// Incoming OSC from serial or the UDP control port: learned mappings are
    /// transformed, everything else is forwarded through the hub with deck/mixer
    /// abbreviations expanded.
    private func handleSerial(packet: OSCPacket) {
        // The board answers /Nexus/Ping with /Nexus/Pong and echoes the track
        // it kept. Those are link housekeeping, not controller input, so they
        // never reach the mapping engine or the passthrough destinations.
        var remaining: [OSCMessage] = []
        var encoderInputs: [OSCMessage] = []
        for incoming in packet.messages {
            // Firmware from before the Nexus rename speaks /Aether, and a saved
            // mapping may still name that prefix. Fold both onto /Nexus here,
            // at the boundary, so nothing downstream has to know about it.
            var message = incoming
            message.address = NexusAddress.canonical(incoming.address)
            switch SerialInputRouter.kind(for: message.address) {
            case .housekeeping:
                let lower = message.address.lowercased()
                if lower == "/nexus/pong" {
                    recordPong()
                } else if lower.hasPrefix("/nexus/track") {
                    logTrackEcho(message)
                } else {
                    sendCachedTrack(for: message)
                }
            case .mappable:
                encoderInputs.append(message)
            case .control:
                remaining.append(message)
            }
        }
        handleEncoderInput(encoderInputs)
        guard !remaining.isEmpty else { return }
        handleExternalOSC(OSCPacket.bundle(remaining.map { .message($0) }), source: .serial)
    }

    /// Feed encoder turns and presses through learn/mapping only.
    private func handleEncoderInput(_ messages: [OSCMessage]) {
        guard !messages.isEmpty else { return }
        let learning: Bool
        if case .waiting(let filter) = engine.learnState {
            learning = filter == .any || filter == .serial
        } else {
            learning = false
        }
        for message in messages {
            if learning || engine.mapping(forControl: message.address) != nil {
                drain(engine.handle(control: message, source: .serial))
            } else if loggedPassthrough.insert(message.address).inserted {
                logAsync(.info, "Encoder input \(message.address) has no mapping; learn it in Bridge → OSC Mapping…")
            }
        }
        if engine.learnState.isActive {
            learnState = engine.learnState
        }
    }

    /// Turns each deck's position stream into its live tempo and forwards it as
    /// `/Deck/<n>/BPM` to the controller. Syndicate's own BPM route does not
    /// follow the fader, and position is the only high-rate signal it sends.
    private func trackLiveTempo(_ packet: OSCPacket) {
        let now = Date()
        for message in packet.messages {
            let lower = message.address.lowercased()
            guard lower.hasSuffix("/position"),
                  let deck = DeckMetadataCache.deckNumber(in: message.address),
                  let position = message.firstFloat.map(Double.init) else { continue }
            guard let rate = tempoTracker.observe(deck: deck, position: position, at: now),
                  let metadata = deckMetadata.decks[deck], metadata.bpm > 0 else { continue }
            // Five updates a second is as fast as the panel can usefully follow
            // a fader. Evaluate the change only at that cadence.
            if now.timeIntervalSince(lastTempoSentAt[deck] ?? .distantPast) < 0.2 { continue }

            // A synced deck runs at the session tempo by definition, so the
            // exact `/Header/BPM` beats any measurement of its playhead. This is
            // also the case that used to jitter between 129.0 and 129.1: a
            // fitted rate is never exactly 1.0.
            let syncedMaster = metadata.synced == true ? deckMetadata.masterTempo : nil
            let raw: Double
            let live: Double
            if let master = syncedMaster, master > 0 {
                raw = master
                live = (master * 10).rounded() / 10
                guard lastLiveTempo[deck] != live else { continue }
            } else {
                raw = metadata.bpm * rate
                guard LiveTempoDisplay.shouldReplace(previous: lastLiveTempo[deck], raw: raw)
                else { continue }
                live = LiveTempoDisplay.value(trackBpm: metadata.bpm, rate: rate)
            }
            if lastLiveTempo[deck] == nil {
                logAsync(.info, "Deck \(deck) live tempo from position: \(String(format: "%.1f", live))")
            }
            lastTempoSentAt[deck] = now
            lastLiveTempo[deck] = live
            deckMetadata.recordLiveBpm(deck: deck, bpm: live)
            if now.timeIntervalSince(lastMetadataSave) >= 5 {
                lastMetadataSave = now
                saveDeckMetadata()
            }
            serial.send(OSCMessage("/Syndicate/Deck/\(deck)/BPM", [.float(Float(live))]))
        }
    }

    /// Ask Syndicate to republish every subscribed value. Change-only routes
    /// (`BPM`, `Sync`, `TrackInfo`, `TempoSliderEnabled`) are otherwise invisible
    /// to a bridge that started after them, which is why cards used to sit on a
    /// stale tempo and the MASTER tag only appeared after a deck was toggled.
    private func requestFeedbackResend() {
        // The resend lives under the address root, which can be renamed. Send
        // the detected root and the default, so a renamed app still answers.
        var roots = ["/Syndicate"]
        if let root = syndicate?.addressRoot, !roots.contains(root) { roots.append(root) }
        for root in roots {
            osc.send(OSCMessage("\(root)/Feedback/Resend", [.int(1)]))
        }
    }

    /// Remembers the session tempo so a reconnecting board starts with the
    /// right number instead of waiting for the fader to move.
    private func observeMasterTempo(_ message: OSCMessage) {
        guard message.address.lowercased().hasSuffix("/header/bpm"), let bpm = message.firstFloat
        else { return }
        guard deckMetadata.recordMasterTempo(Double(bpm)) else { return }
        saveDeckMetadata()
        // A synced deck follows the header even while it is paused, when there
        // is no playhead to measure. Push the exact number so a stopped card
        // does not sit on the tempo it had before the master fader moved.
        let now = Date()
        for deck in deckMetadata.decks.keys.sorted() {
            sendSyncedTempo(deck: deck, at: now)
        }
    }

    /// Send the session tempo to one synced deck, rate limited like the
    /// measured stream so a moving header fader cannot flood the serial link.
    private func sendSyncedTempo(deck: Int, at now: Date) {
        guard deckMetadata.decks[deck]?.synced == true,
              let live = deckMetadata.liveBpmMessage(for: deck),
              now.timeIntervalSince(lastTempoSentAt[deck] ?? .distantPast) >= 0.2 else { return }
        lastTempoSentAt[deck] = now
        lastLiveTempo[deck] = deckMetadata.decks[deck]?.currentBpm
        serial.send(live)
    }

    /// The board asks for a deck's metadata when it has none, which recovers a
    /// `TrackInfo` that was dropped on the wire.
    private func sendCachedTrack(for request: OSCMessage) {
        guard let raw = request.address.split(separator: "/").last, let deck = Int(raw),
              let message = deckMetadata.message(for: deck) else { return }
        serial.send(message)
        if let live = deckMetadata.liveBpmMessage(for: deck) { serial.send(live) }
        logAsync(.info, "Board asked for deck \(deck) metadata; resent it")
    }

    private func logTrackEcho(_ message: OSCMessage) {
        let title = message.arguments.compactMap { argument -> String? in
            if case .string(let value) = argument { return value }
            return nil
        }.first ?? ""
        logAsync(.info, "Board kept \(message.address): \(title.isEmpty ? "(no title)" : title)")
    }

    // MARK: - Serial link liveness

    private func recordPong() {
        let received = Date()
        if let sent = serialPingSentAt {
            let milliseconds = received.timeIntervalSince(sent) * 1_000
            if milliseconds >= 0, milliseconds < 6_000 {
                latencyMonitor.recordLinkRoundTrip(milliseconds: milliseconds)
                if loggedLinkRtt < 5 {
                    loggedLinkRtt += 1
                    logAsync(.info, "Serial link round-trip: \(String(format: "%.2f", milliseconds)) ms")
                }
            }
            serialPingSentAt = nil
        }
        switch heartbeat.recordPong(at: received) {
        case .steady:
            return
        case .linked:
            republishDeckState()
            // The board just came up; ask for a full resend so it starts with
            // the current tempo and SYNC state rather than an empty card.
            requestFeedbackResend()
        case .resynced:
            republishDeckState()
            logAsync(.info, "Controller came back; republishing deck state")
            // Ask Syndicate to resend everything too: the host may have missed
            // changes while the link was down.
            requestFeedbackResend()
        }
    }

    private func republishDeckState() {
        let snapshot = serialMirror.snapshot()
        // Track info only arrives on load, so after a restart the mirror has
        // none: fall back to the cached copy for any deck it cannot cover.
        let covered = Set(snapshot
            .filter { $0.address.lowercased().hasSuffix("/trackinfo") }
            .compactMap { DeckMetadataCache.deckNumber(in: $0.address) })
        serialMirror.reset()
        for message in snapshot {
            serial.send(message)
        }
        for deck in covered {
            if let live = deckMetadata.liveBpmMessage(for: deck) { serial.send(live) }
            if let sync = deckMetadata.syncMessage(for: deck) { serial.send(sync) }
        }
        for deck in deckMetadata.decks.keys.sorted() where !covered.contains(deck) {
            if let sync = deckMetadata.syncMessage(for: deck) { serial.send(sync) }
        }
        if let tempo = deckMetadata.masterTempoMessage() { serial.send(tempo) }
        var replayed = 0
        for message in deckMetadata.messages() {
            if let deck = DeckMetadataCache.deckNumber(in: message.address), covered.contains(deck) {
                continue
            }
            serial.send(message)
            replayed += 1
            // TrackInfo carries the file tempo; restore the live one too.
            if let deck = DeckMetadataCache.deckNumber(in: message.address),
               let live = deckMetadata.liveBpmMessage(for: deck) {
                serial.send(live)
            }
        }
        if replayed > 0 {
            logAsync(.info, "Replayed cached metadata for \(replayed) deck(s)")
        }
        // A board that just connected has no pixels yet, so paint it straight
        // away rather than waiting for the next tick.
        sendPodStrip()
    }

    /// The pod strip shows Syndicate's eight hot-cue colours, pixel *n* under
    /// pod key *n*. The palette is a general preference the user can change
    /// while both apps run, so it is re-read on a fast tick.
    ///
    /// The frame is resent every time rather than only when it changes. A board
    /// that reboots keeps the USB port open and goes on answering pings, so
    /// nothing else notices; its pixels are wiped, and because the firmware
    /// deduplicates frames it never repaints itself. Repainting on a tick is
    /// what brings the strip back from the firmware's idle colour, and eight
    /// small messages on a 921600 link cost nothing.
    private func refreshPodStrip(at now: Date) {
        guard serial.isOpen, now.timeIntervalSince(lastPodStripRefresh) >= 2 else { return }
        lastPodStripRefresh = now
        sendPodStrip()
    }

    private func sendPodStrip() {
        guard serial.isOpen else { return }
        let palette = PodStrip.palette(from: SyndicateSettings.detect())
        let changed = palette != lastPodStripPalette
        lastPodStripPalette = palette
        for message in PodStrip.messages(for: palette) {
            serial.send(message)
        }
        if changed {
            logAsync(.info, "Pod strip ← hot-cue palette \(palette.joined(separator: ", "))")
        }
    }

    /// Pings the board and reopens the port when it stops answering. Without
    /// this a wedged (or silently half-closed) descriptor keeps looking healthy,
    /// the panels freeze, and only a manual rescan in Settings revives them.
    private func maintainSerialLink(at now: Date) {
        guard serial.isOpen else { return }
        if heartbeat.pingDue(at: now) {
            serialPingSentAt = now
            serial.send(OSCMessage(NexusAddress.ping, [.int(1)]))
        }
        if heartbeat.shouldRestart(at: now) {
            let silence = String(format: "%.0f", heartbeat.silence(at: now))
            logAsync(.warn, "Serial controller silent for \(silence)s; reopening \(serialPath ?? "port")")
            restartSerialLink()
        }
    }

    /// Queue-local reopen: reconnecting from the timer must not bounce through
    /// the UI-facing `reconnectSerial`, which Settings calls on the main thread.
    private func restartSerialLink() {
        serial.stop()
        serialPingSentAt = nil
        serialConnected = false
        serialPath = nil
        serialDeviceIdentity = nil
        serialRetryAt = .distantPast
        connectSerialIfNeeded(force: true)
    }

    private func handleExternalOSC(_ packet: OSCPacket, source: MappingSourceKind) {
        for message in packet.messages {
            let learning: Bool
            if case .waiting(let filter) = engine.learnState {
                learning = filter == .any
                    || (source == .serial && filter == .serial)
                    || (source == .osc && filter == .osc)
            } else {
                learning = false
            }
            if learning || engine.mapping(forControl: message.address) != nil {
                drain(engine.handle(control: message, source: source))
            } else {
                forward(message, source: source)
            }
        }
        if engine.learnState.isActive {
            learnState = engine.learnState
        }
    }

    private func forward(_ message: OSCMessage, source: MappingSourceKind) {
        guard let address = HubRouter.commandAddress(message.address) else {
            logAsync(.warn, "\(source.label) message ignored: \(message.address)")
            return
        }
        let label = source == .serial ? "Serial OSC" : "OSC in"
        let forwarded = OSCMessage(address, message.arguments)
        if let endpoint = HubRouter.endpoint(for: address, endpoints: routingEndpoints) {
            osc.send(forwarded, to: OSCDestination(host: endpoint.host, port: UInt16(endpoint.port)))
            if loggedPassthrough.insert(address).inserted {
                logAsync(.info, "\(label) → \(endpoint.label) \(address)")
            }
        } else {
            let sent = HubRouter.retarget(forwarded.address, root: syndicate?.addressRoot)
            osc.send(OSCMessage(sent, forwarded.arguments))
            if loggedPassthrough.insert(sent).inserted {
                logAsync(.info, "\(label) → Syndicate \(sent)")
            }
        }
        passthroughSent += 1
    }

    /// Turn the derived play state into the `/Deck/<n>/Playing` messages the
    /// serial controller listens for. Runs on every timer tick; the mirror drops
    /// repeats and refreshes once a second so a rebooted board catches up.
    private func publishDeckState(at now: Date) {
        guard mirrorSerialFeedback, serial.isOpen else { return }
        let states = playback.states(at: now)
        guard !states.isEmpty else { return }
        let packet = OSCPacket.bundle(states.keys.sorted().map { deck in
            .message(OSCMessage("/Syndicate/Deck/\(deck)/Playing", [.int(states[deck] == true ? 1 : 0)]))
        })
        for message in serialMirror.messages(for: packet, at: now) {
            serial.send(message)
        }
    }

    /// Mirror mapped routes plus deck play state, so the ESP32-S3 can drive its
    /// panels and LEDs without receiving all 293 Syndicate feedback paths at
    /// 30 Hz.
    private func mirrorToSerial(_ packet: OSCPacket) {
        guard serial.isOpen else { return }
        for message in serialMirror.messages(for: packet) {
            observeDeckMetadata(message)
            observeMasterTempo(message)
            logDeckMutation(message)
            logHeaderTempo(message)
            if !loggedClockBeat, message.address.lowercased().hasSuffix("/header/clock") {
                loggedClockBeat = true
                logAsync(.info, "Master clock → board: beat \(message.firstInt ?? 0)")
            }
            serial.send(message)
        }
    }

    /// Logs the deck messages that *change* the card (not the playhead), once
    /// each. This is what shows whether a later `Loaded` wipes the title that
    /// `TrackInfo` just set.
    private func logDeckMutation(_ message: OSCMessage) {
        let lower = message.address.lowercased()
        guard lower.contains("/deck/") else { return }
        guard lower.hasSuffix("/trackinfo") || lower.hasSuffix("/loaded")
            || lower.hasSuffix("/bpm") || lower.hasSuffix("/playing")
            || lower.hasSuffix("/loopinfo") || lower.hasSuffix("/temposliderenabled")
            || lower.hasSuffix("/temposlider") || lower.hasSuffix("/sync") else { return }

        let arguments = message.arguments.map { argument -> String in
            switch argument {
            case .int(let value): return "i:\(value)"
            case .float(let value): return "f:\(String(format: "%.2f", value))"
            case .string(let value): return "s:\(value)"
            case .blob(let bytes): return "b:\(bytes.count)"
            }
        }.joined(separator: " ")
        let key = message.address + "|" + arguments
        guard loggedDeckMutations.insert(key).inserted, loggedDeckMutations.count <= 60 else { return }
        logAsync(.info, "Deck ← \(message.address) \(arguments)")
    }

    /// Logs the session tempo the board receives, once a second at most.
    private func logHeaderTempo(_ message: OSCMessage) {
        guard message.address.lowercased().hasSuffix("/header/bpm") else { return }
        let now = Date()
        guard now.timeIntervalSince(lastHeaderTempoLog) >= 1 else { return }
        lastHeaderTempoLog = now
        let arguments = message.arguments.map { argument -> String in
            switch argument {
            case .int(let value): return "i:\(value)"
            case .float(let value): return "f:\(String(format: "%.3f", value))"
            case .string(let value): return "s:\(value)"
            case .blob(let bytes): return "b:\(bytes.count)"
            }
        }.joined(separator: " ")
        logAsync(.info, "Session tempo → board: \(arguments)")
    }

    /// Keep the last known title/BPM per deck on disk, so a restarted app or a
    /// rebooted board can repopulate its cards without a track load.
    private func observeDeckMetadata(_ message: OSCMessage) {
        let lower = message.address.lowercased()
        var changed = false
        if lower.hasSuffix("/trackinfo") {
            changed = deckMetadata.record(trackInfo: message)
            logDeckMetadata(message)
        } else if lower.hasSuffix("/loaded"), message.firstInt == 0,
                  let deck = DeckMetadataCache.deckNumber(in: message.address) {
            changed = deckMetadata.clear(deck: deck)
        } else if lower.hasSuffix("/sync"), message.firstInt != nil,
                  let deck = DeckMetadataCache.deckNumber(in: message.address) {
            changed = deckMetadata.recordSync(deck: deck, synced: message.firstInt == 1)
            // Turning SYNC on locks the deck to the header immediately; the
            // board should not wait for a playhead update to show that tempo.
            if message.firstInt == 1 { sendSyncedTempo(deck: deck, at: Date()) }
        } else if lower.hasSuffix("/bpm"), message.firstFloat != nil,
                  let deck = DeckMetadataCache.deckNumber(in: message.address) {
            // The deck's live tempo, which a master tempo or pitch changes.
            changed = deckMetadata.recordLiveBpm(deck: deck, bpm: Double(message.firstFloat ?? 0))
        }
        if changed { saveDeckMetadata() }
    }

    /// Logs every distinct track-related feedback address once. Titles are
    /// change-only, so this is the quickest way to tell "the panel is broken"
    /// from "Syndicate has not sent a track yet".
    private func logTrackFeedback(_ packet: OSCPacket) {
        for message in packet.messages {
            let lower = message.address.lowercased()
            guard lower.contains("/deck/") else { continue }
            guard lower.contains("trackinfo") || lower.contains("title") || lower.contains("artist")
                || lower.contains("load") || lower.contains("bpm") || lower.hasSuffix("/sync") else { continue }
            guard loggedTrackAddresses.insert(lower).inserted else { continue }
            guard loggedTrackAddresses.count <= 40 else { continue }
            let strings = message.arguments.compactMap { argument -> String? in
                if case .string(let value) = argument { return value }
                return nil
            }
            logAsync(.info, "Track feedback \(message.address) [\(message.arguments.count) args] "
                     + strings.prefix(3).joined(separator: " · "))
        }
    }

    /// Syndicate only sends `TrackInfo` when a track is loaded, so the panels
    /// stay blank until that happens. Logging it once per track makes that
    /// obvious instead of looking like a broken display.
    private func logDeckMetadata(_ message: OSCMessage) {
        guard message.address.lowercased().hasSuffix("/trackinfo") else { return }
        let strings = message.arguments.compactMap { argument -> String? in
            if case .string(let value) = argument { return value }
            return nil
        }
        let key = message.address + "|" + strings.joined(separator: "|")
        guard loggedTracks.insert(key).inserted else { return }
        if loggedTracks.count > 32 { loggedTracks.removeFirst() }
        logAsync(.info, "Deck metadata \(message.address): \(strings.joined(separator: " · "))")
    }

    // MARK: - Diagnostics

    private func syncMIDIState() {
        let connected = midi.connectedName != nil
        // Stock FLX4 bindings only run while an FLX4 is actually present, so a
        // generic controller on the same channels is never mapped by accident.
        let flx4Present = midi.connectedNames.contains { MIDITransport.isFLX4($0) }
        queue.async { [weak self] in
            self?.engine.flx4PresetEnabled = flx4Present
        }
        if connected != deviceConnected {
            deviceConnected = connected
            if let name = midi.connectedName {
                log(.info, "MIDI controller connected (\(name))")
            } else {
                log(.warn, "MIDI controller disconnected; waiting")
            }
        }
        notify()
    }

    private func logMIDIDiscovery() {
        if !midi.connectedNames.isEmpty {
            log(.info, "MIDI input in use: \(midi.connectedNames.joined(separator: ", "))")
            let hasFLX4 = midi.connectedNames.contains { MIDITransport.isFLX4($0) }
            if !hasFLX4 { return }
            if let output = midi.outputNames.first(where: { MIDITransport.isFLX4($0) }) {
                log(.info, "MIDI output in use: \(output)")
            } else {
                log(.warn, "No FLX4 MIDI output found; LEDs and the keepalive will not be sent")
            }
        } else if midi.inputNames.isEmpty {
            log(.warn, "No MIDI inputs found; waiting for a controller")
        } else {
            log(.warn, "MIDI inputs seen but none opened: \(midi.inputNames.joined(separator: ", "))")
        }
    }

    private func logSyndicateDiagnostics() {
        syndicate = SyndicateSettings.detect()
        guard let ap = syndicate else {
            log(.info, "Syndicate settings not found; using \(destination):\(destinationPort)")
            return
        }
        log(.info, ap.summary)
        if let listen = ap.listenPort, listen != destinationPort {
            log(.warn, "Port mismatch: Syndicate listens on \(listen) but the bridge sends to \(destinationPort). Fix it in Settings.")
        }
        if !ap.oscEnabled {
            log(.warn, "Syndicate OSC input is disabled (Settings → OSC). The bridge cannot reach it.")
        }
        if !ap.hasBridgeSubscriptions {
            log(.warn, "Syndicate feedback subscribes to no deck/mixer paths (\(ap.subscriptionCount) subscriptions). Enable Toggle All feedback so CUE, toggles and LEDs work.")
        }
        // Tempo and MASTER come from three specific subscriptions. Without them
        // the cards stay blank however healthy the rest of the link looks.
        let paths = Set(ap.feedbackPaths.map { $0.lowercased() })
        let tempoRoutes = ["deck/1/bpm", "deck/1/sync", "deck/1/temposliderenabled"]
        let missing = tempoRoutes.filter { route in !paths.contains { $0.hasSuffix("/" + route) } }
        if !missing.isEmpty {
            log(.warn, "Syndicate feedback is missing \(missing.joined(separator: ", ")). Tempo and the MASTER tag need Deck BPM, Sync and TempoSliderEnabled ticked in Settings → OSC FEEDBACK.")
        }
    }

    func clearLog() {
        logs.removeAll()
        notify()
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.drain(self.engine.tick())
            let now = Date()
            self.publishDeckState(at: now)
            self.maintainSerialLink(at: now)
            if now.timeIntervalSince(self.lastRefresh) >= 2 {
                self.lastRefresh = now
                self.midi.refresh()
                self.connectSerialIfNeeded(force: false)
                self.refreshPodStrip(at: now)
            }
            if now.timeIntervalSince(self.lastPublish) >= 0.1 {
                self.lastPublish = now
                self.publish()
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func publish() {
        let snapshot = engine.snapshot()
        let sent = engine.oscSent
        let accepted = engine.feedbackAccepted
        let feedback = engine.lastFeedback
        let latencies = Dictionary(uniqueKeysWithValues: LatencySource.allCases.map {
            ($0, latencyMonitor.stats($0))
        })
        let roundTrip = latencyMonitor.roundTrip
        let linkRoundTrip = latencyMonitor.linkRoundTrip
        let histories = Dictionary(uniqueKeysWithValues: LatencySource.allCases.map {
            ($0, latencyMonitor.recent($0))
        })
        let linkHistory = latencyMonitor.recentLinkRoundTrips()
        let engineLearn = engine.learnState
        let passthrough = passthroughSent
        let serialFrames = serial.framesIn
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshot = snapshot
            self.oscSent = sent
            self.passthroughSent = passthrough
            self.feedbackCount = accepted
            self.lastFeedback = feedback
            self.latency = latencies
            self.roundTrip = roundTrip
            self.linkRoundTrip = linkRoundTrip
            self.latencyHistory = histories
            self.linkRoundTripHistory = linkHistory
            self.learnState = engineLearn
            self.serialFrames = serialFrames
            if accepted > 0 && !self.loggedFirstFeedback {
                self.loggedFirstFeedback = true
                self.log(.info, "Receiving Syndicate OSC feedback")
            }
            self.onChange?()
        }
    }

    private func drain(_ effects: [EngineEffect]) {
        for effect in effects {
            switch effect {
            case .osc(let message):
                dispatch(message, endpoint: nil)
            case .oscTo(let message, let id):
                let endpoint = routingEndpoints.first { $0.id == id && $0.enabled }
                dispatch(message, endpoint: endpoint)
            case .midi(let bytes):
                midi.send(bytes)
            case .log(let level, let message):
                DispatchQueue.main.async { self.log(level, message) }
            case .learned(let control):
                logAsync(.info, "Learn captured \(control.label); choose a route in the Mapping window")
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.lastLearned = control
                    self.learnState = .learned(control)
                    self.onLearned?(control)
                    self.onChange?()
                }
            }
        }
    }

    private func dispatch(_ message: OSCMessage, endpoint: OSCEndpoint?) {
        // The primary app may listen on a custom root or, on a pre-rename
        // build, still on `/AutoPilot`; commands have to follow the detected
        // root or they are discarded by the app that received them. Extra
        // destinations keep their own prefixes untouched.
        let outbound: OSCMessage
        if endpoint == nil {
            outbound = OSCMessage(HubRouter.retarget(message.address, root: syndicate?.addressRoot),
                                  message.arguments)
        } else {
            outbound = message
        }
        if let endpoint {
            osc.send(outbound, to: OSCDestination(host: endpoint.host, port: UInt16(endpoint.port)))
        } else {
            osc.send(outbound)
        }
        let address = outbound.address.lowercased()
        if endpoint == nil && !address.hasSuffix("/feedback/resend") {
            latencyMonitor.expectFeedback(address: message.address)
        }
        oscLogCount += 1
        let first = !loggedFirstSend
        if first {
            loggedFirstSend = true
        }
        // Log the first send of every address — that is how a user sees
        // which control works — then throttle: faders can stream.
        let sentAddress = outbound.address
        let unseen = loggedAddresses.insert(sentAddress).inserted
        if first || unseen || oscLogCount % 25 == 0 {
            let target = endpoint.map { "\($0.label) \($0.host):\($0.port)" }
                ?? "\(destination):\(destinationPort)"
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if first {
                    self.log(.info, "Sending OSC to \(target) (first packet \(sentAddress))")
                } else {
                    self.log(.info, "OSC sent \(sentAddress) → \(target)")
                }
            }
        }
    }

    private func fail(_ message: String) {
        lastError = message
        log(.error, message)
        notify()
    }

    private func logAsync(_ level: LogLevel, _ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.log(level, message)
        }
    }

    func log(_ level: LogLevel, _ message: String) {
        let entry = LogEntry(date: Date(), level: level, message: message)
        logs.append(entry)
        if logs.count > 400 { logs.removeFirst(logs.count - 400) }
        lastError = level == .error ? message : lastError
        writeToLogFile(entry)
        notify()
    }

    /// Mirror to ~/Library/Logs/Cuewire.log so a run can be inspected after the fact.
    private func writeToLogFile(_ entry: LogEntry) {
        guard let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs") else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Cuewire.log")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(formatter.string(from: entry.date)) [\(entry.level.rawValue)] \(entry.message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private func notify() {
        onChange?()
    }
}
