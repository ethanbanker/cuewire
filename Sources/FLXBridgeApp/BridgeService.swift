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
    private var autoPilot: AutoPilotSettings?
    private var serialMirrorAddresses: Set<String> = []
    private var engineMirrorAddresses: Set<String> = []
    private var routingEndpoints: [OSCEndpoint] = []
    private var lastSerialError: String?
    private var loggedPassthrough: Set<String> = []
    private var serialRetryAt = Date.distantPast

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
        let detected = AutoPilotSettings.detect()
        autoPilot = detected
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
        serialBaud = BridgeService.integer(defaults, Keys.serialBaud) ?? 115_200
        serialFraming = SerialFraming(rawValue: defaults.string(forKey: Keys.serialFraming) ?? "") ?? .auto
        mirrorSerialFeedback = BridgeService.boolean(defaults, Keys.mirrorSerialFeedback) ?? true
        mappingStore = MappingStore()
        mappings = mappingStore.mappings
        endpoints = mappingStore.endpoints
        mappingStore.onChange = { [weak self] in self?.reloadMappings() }
        engine.userMappings = mappings
        refreshSerialMirror()
        routingEndpoints = endpoints
        engineMirrorAddresses = serialMirrorAddresses
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
            self.engineMirrorAddresses = mirror
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
                self.drain(self.engine.handle(packet: packet))
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
            self.engineMirrorAddresses = mirror
            self.drain(self.engine.start())
        }
        startTimer()
        connectSerialIfNeeded(force: true)
        log(.info, "Bridge started: OSC to \(destination):\(destinationPort), feedback on \(feedbackPort)")
        logMIDIDiscovery()
        logAutoPilotDiagnostics()
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
            log(.warn, "OSC control input is disabled: it uses the same port as AUTO/PILOT feedback")
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
            try controlOSC.start(destinations: oscDestinations, bindPort: UInt16(controlInputPort))
            log(.info, "OSC control input listening on \(controlInputPort) (TouchOSC, another bridge, etc.)")
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
        serialPath = nil
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
            serialConnected = true
            return
        }
        let now = Date()
        guard force || now >= serialRetryAt else { return }
        serialRetryAt = now.addingTimeInterval(1.5)
        do {
            try serial.start(path: serialPort.isEmpty ? nil : serialPort,
                              baud: serialBaud, framing: serialFraming)
            serialPath = serial.path
            serialConnected = true
            serialError = nil
            lastSerialError = nil
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
        handleExternalOSC(packet, source: .serial)
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
            osc.send(forwarded)
            if loggedPassthrough.insert(address).inserted {
                logAsync(.info, "\(label) → AUTO/PILOT \(address)")
            }
        }
        passthroughSent += 1
    }

    /// Mirror only routes that a serial control owns, so the ESP32-S3 can drive
    /// LEDs/meters without receiving all 293 AUTO/PILOT feedback paths at 30 Hz.
    private func mirrorToSerial(_ packet: OSCPacket) {
        guard serial.isOpen, !engineMirrorAddresses.isEmpty else { return }
        for message in packet.messages {
            guard engineMirrorAddresses.contains(FLX4Engine.canonical(message.address)) else { continue }
            guard let address = HubRouter.commandAddress(message.address) else { continue }
            serial.send(OSCMessage(address, message.arguments))
        }
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

    private func logAutoPilotDiagnostics() {
        autoPilot = AutoPilotSettings.detect()
        guard let ap = autoPilot else {
            log(.info, "AUTO/PILOT settings not found; using \(destination):\(destinationPort)")
            return
        }
        log(.info, ap.summary)
        if let listen = ap.listenPort, listen != destinationPort {
            log(.warn, "Port mismatch: AUTO/PILOT listens on \(listen) but the bridge sends to \(destinationPort). Fix it in Settings.")
        }
        if !ap.oscEnabled {
            log(.warn, "AUTO/PILOT OSC input is disabled (Settings → OSC). The bridge cannot reach it.")
        }
        if !ap.hasBridgeSubscriptions {
            log(.warn, "AUTO/PILOT feedback subscribes to no deck/mixer paths (\(ap.subscriptionCount) subscriptions). Enable Toggle All feedback so CUE, toggles and LEDs work.")
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
            if now.timeIntervalSince(self.lastRefresh) >= 2 {
                self.lastRefresh = now
                self.midi.refresh()
                self.connectSerialIfNeeded(force: false)
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
            self.learnState = engineLearn
            self.serialFrames = serialFrames
            if accepted > 0 && !self.loggedFirstFeedback {
                self.loggedFirstFeedback = true
                self.log(.info, "Receiving AUTO/PILOT OSC feedback")
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
        if let endpoint {
            osc.send(message, to: OSCDestination(host: endpoint.host, port: UInt16(endpoint.port)))
        } else {
            osc.send(message)
        }
        let address = message.address.lowercased()
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
        let unseen = loggedAddresses.insert(message.address).inserted
        if first || unseen || oscLogCount % 25 == 0 {
            let target = endpoint.map { "\($0.label) \($0.host):\($0.port)" }
                ?? "\(destination):\(destinationPort)"
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if first {
                    self.log(.info, "Sending OSC to \(target) (first packet \(message.address))")
                } else {
                    self.log(.info, "OSC sent \(message.address) → \(target)")
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
