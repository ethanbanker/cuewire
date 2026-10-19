import CoreMIDI
import Foundation

private func flxMIDIRead(_ packetList: UnsafePointer<MIDIPacketList>,
                         _ refCon: UnsafeMutableRawPointer?,
                         _ connRefCon: UnsafeMutableRawPointer?) {
    guard let refCon else { return }
    let transport = Unmanaged<MIDITransport>.fromOpaque(refCon).takeUnretainedValue()
    let count = Int(packetList.pointee.numPackets)
    // Walk the packet list in place. Copying the first packet to a local variable
    // breaks MIDIPacketNext, which needs the real packet memory to find packet 2..n.
    var packet = UnsafeMutableRawPointer(mutating: UnsafeRawPointer(packetList))
        .advanced(by: MemoryLayout<UInt32>.size)
        .assumingMemoryBound(to: MIDIPacket.self)
    let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data) ?? 10
    for _ in 0..<count {
        let length = Int(packet.pointee.length)
        if length > 0 {
            let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(packet).advanced(by: dataOffset),
                                               count: length)
            transport.deliver(Array(bytes))
        }
        packet = MIDIPacketNext(packet)
    }
}

private func flxMIDINotify(_ notification: UnsafePointer<MIDINotification>,
                           _ refCon: UnsafeMutableRawPointer?) {
    guard let refCon else { return }
    let transport = Unmanaged<MIDITransport>.fromOpaque(refCon).takeUnretainedValue()
    switch notification.pointee.messageID {
    case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved, .msgSerialPortOwnerChanged:
        transport.scheduleRefresh()
    default:
        break
    }
}

public func midiDisplayName(_ endpoint: MIDIEndpointRef) -> String {
    var value: Unmanaged<CFString>?
    guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &value) == noErr,
          let name = value?.takeRetainedValue() else { return "" }
    return name as String
}

/// CoreMIDI connection to a DDJ-FLX4. Sources/destinations are matched by name so
/// the app reconnects on its own when the controller is plugged in.
public final class MIDITransport {
    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var destination = MIDIEndpointRef()
    private var connected: [MIDIEndpointRef] = []
    private var signature = ""
    private let queue = DispatchQueue(label: "flxbridge.midi")

    public private(set) var inputNames: [String] = []
    public private(set) var outputNames: [String] = []
    public private(set) var connectedNames: [String] = []
    public private(set) var connectedName: String?
    public var onMessage: (([UInt8]) -> Void)?
    public var onDevicesChanged: (([String], [String]) -> Void)?
    public var onError: ((String) -> Void)?

    public init() {}

    public var ready: Bool { client != 0 && inputPort != 0 && outputPort != 0 }

    /// A name matches when it contains "FLX4" once case, spaces and punctuation are
    /// ignored, so "DDJ-FLX4", "DDJ FLX4" and "Pioneer DDJ-FLX4 MIDI" all work.
    public static func isFLX4(_ name: String) -> Bool {
        let normalized = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return normalized.contains("flx4")
    }

    public func start() throws {
        if client == 0 {
            let status = MIDIClientCreate("Cuewire" as CFString, flxMIDINotify,
                                          Unmanaged.passUnretained(self).toOpaque(), &client)
            guard status == noErr else { throw midiError("Create MIDI client", status) }
        }
        if inputPort == 0 {
            let status = MIDIInputPortCreate(client, "Cuewire input" as CFString, flxMIDIRead,
                                             Unmanaged.passUnretained(self).toOpaque(), &inputPort)
            guard status == noErr else { throw midiError("Create MIDI input", status) }
        }
        if outputPort == 0 {
            let status = MIDIOutputPortCreate(client, "Cuewire output" as CFString, &outputPort)
            guard status == noErr else { throw midiError("Create MIDI output", status) }
        }
        // Enumerate synchronously so `connectedName` is valid as soon as start()
        // returns. The app registers its callbacks before calling start().
        queue.sync { refreshLocked(force: true) }
    }

    public func stop() {
        queue.sync {
            for source in connected {
                MIDIPortDisconnectSource(inputPort, source)
            }
            connected.removeAll()
            signature = ""
            destination = 0
            connectedName = nil
            connectedNames = []
            inputNames = []
            outputNames = []
        }
        if inputPort != 0 { MIDIPortDispose(inputPort); inputPort = 0 }
        if outputPort != 0 { MIDIPortDispose(outputPort); outputPort = 0 }
        if client != 0 { MIDIClientDispose(client); client = 0 }
    }

    /// Re-enumerate endpoints. Cheap enough to poll every couple of seconds.
    public func refresh(force: Bool = false) {
        queue.async { [weak self] in
            self?.refreshLocked(force: force)
        }
    }

    /// Called from CoreMIDI's notification thread when devices come and go.
    fileprivate func scheduleRefresh() {
        refresh(force: true)
    }

    private func refreshLocked(force: Bool) {
        guard client != 0 else { return }
        let sources = (0..<MIDIGetNumberOfSources()).map(MIDIGetSource)
        let destinations = (0..<MIDIGetNumberOfDestinations()).map(MIDIGetDestination)
        let inputs = sources.map(midiDisplayName)
        let outputs = destinations.map(midiDisplayName)
        let next = "\(inputs)|\(outputs)"
        guard force || next != signature else { return }
        signature = next

        // Only touch endpoints that actually changed. Disconnecting and
        // reconnecting live sources on every scan (including each CoreMIDI
        // notification) loses virtual and hot-plugged inputs.
        let wanted = sources.filter { MIDITransport.isFLX4(midiDisplayName($0)) }
        for source in connected where !wanted.contains(source) {
            MIDIPortDisconnectSource(inputPort, source)
        }
        for source in wanted where !connected.contains(source) {
            let status = MIDIPortConnectSource(inputPort, source, nil)
            if status != noErr {
                onError?("CoreMIDI could not open \(midiDisplayName(source)) (OSStatus \(status))")
            }
        }
        connected = wanted
        destination = destinations.first { MIDITransport.isFLX4(midiDisplayName($0)) } ?? 0

        inputNames = inputs
        outputNames = outputs
        connectedNames = connected.map(midiDisplayName)
        connectedName = connectedNames.first
        onDevicesChanged?(inputs, outputs)
    }

    fileprivate func deliver(_ bytes: [UInt8]) {
        onMessage?(bytes)
    }

    public func send(_ bytes: [UInt8]) {
        queue.async { [weak self] in
            guard let self, self.outputPort != 0, self.destination != 0 else { return }
            var list = MIDIPacketList()
            var packet = MIDIPacketListInit(&list)
            packet = MIDIPacketListAdd(&list, 1024, packet, 0, bytes.count, bytes)
            MIDISend(self.outputPort, self.destination, &list)
        }
    }

    private func midiError(_ context: String, _ status: OSStatus) -> NSError {
        NSError(domain: "FLXBridge", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "\(context) failed (OSStatus \(status))"])
    }
}
