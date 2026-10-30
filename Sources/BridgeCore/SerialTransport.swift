import Foundation
import Darwin

/// OSC over a USB serial link (the ESP32-S3 hardware controller project).
///
/// Two framing modes are supported so firmware can pick whichever is convenient:
/// - `.slip`: standard OSC-over-serial framing (RFC 1055), one packet per frame.
/// - `.text`: one message per line, `address arg arg`, args may be plain numbers,
///   or tagged with `i:`, `f:` and `s:` for an unambiguous type.
/// - `.auto` starts in either mode as soon as the first frame delimiter arrives.
public enum SerialFraming: String, Codable, CaseIterable, Sendable {
    case auto, slip, text

    public var label: String {
        switch self {
        case .auto: return "Auto (SLIP or text)"
        case .slip: return "SLIP-framed OSC"
        case .text: return "Newline text"
        }
    }
}

public enum OSCSerialCodec {
    /// Split one text line into an OSC message. Returns nil for blank lines,
    /// comments and anything that does not start with `/`.
    public static func parseText(_ line: String) -> OSCMessage? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        var parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let address = parts.first, address.hasPrefix("/") else { return nil }
        parts.removeFirst()
        var arguments: [OSCArgument] = []
        for token in parts {
            if token.hasPrefix("i:"), let value = Int32(token.dropFirst(2)) {
                arguments.append(.int(value))
            } else if token.hasPrefix("f:"), let value = Float(token.dropFirst(2)) {
                arguments.append(.float(value))
            } else if token.hasPrefix("s:") {
                arguments.append(.string(String(token.dropFirst(2))))
            } else if let value = Int32(token) {
                arguments.append(.int(value))
            } else if let value = Float(token) {
                arguments.append(.float(value))
            } else if token == "true" {
                arguments.append(.int(1))
            } else if token == "false" {
                arguments.append(.int(0))
            } else {
                arguments.append(.string(token))
            }
        }
        return OSCMessage(address, arguments)
    }

    public static func textLine(_ message: OSCMessage) -> Data {
        var line = message.address
        for argument in message.arguments {
            switch argument {
            case .int(let value): line += " i:\(value)"
            case .float(let value): line += " f:\(String(format: "%.6g", value))"
            case .string(let value): line += " s:\(value.replacingOccurrences(of: " ", with: "_"))"
            case .blob(let bytes): line += " s:" + bytes.map { String(format: "%02x", $0) }.joined()
            }
        }
        line += "\n"
        return Data(line.utf8)
    }

    public static func slip(_ data: Data) -> Data {
        var output = Data()
        for byte in data {
            switch byte {
            case 0xc0:
                output.append(contentsOf: [0xdb, 0xdc])
            case 0xdb:
                output.append(contentsOf: [0xdb, 0xdd])
            default:
                output.append(byte)
            }
        }
        output.append(0xc0)
        return output
    }
}

struct SlipDecoder {
    private var frame: [UInt8] = []
    private var escaped = false
    private(set) var discarded = 0

    mutating func feed(_ bytes: [UInt8]) -> [Data] {
        var output: [Data] = []
        for byte in bytes {
            if byte == 0xc0 {
                if !frame.isEmpty {
                    output.append(Data(frame))
                    frame.removeAll(keepingCapacity: true)
                }
                escaped = false
            } else if escaped {
                switch byte {
                case 0xdc: frame.append(0xc0)
                case 0xdd: frame.append(0xdb)
                default: frame.append(byte)
                }
                escaped = false
            } else if byte == 0xdb {
                escaped = true
            } else {
                frame.append(byte)
            }
            if frame.count > 65_535 {
                frame.removeAll(keepingCapacity: true)
                escaped = false
                discarded += 1
            }
        }
        return output
    }
}

/// Incremental framer; pure so the serial protocol can be checked without a device.
public struct OSCSerialFramer {
    public private(set) var mode: SerialFraming
    private var pending: [UInt8] = []
    private var slip = SlipDecoder()
    private var textBuffer: [UInt8] = []
    public private(set) var discardedFrames = 0

    public init(framing: SerialFraming = .auto) {
        self.mode = framing
    }

    public mutating func feed(_ bytes: [UInt8]) -> [OSCPacket] {
        switch mode {
        case .slip:
            return slip.feed(bytes).compactMap { try? OSCDecoder.decode($0) }
        case .text:
            return text(bytes)
        case .auto:
            pending.append(contentsOf: bytes)
            if pending.contains(0xc0) {
                mode = .slip
                let buffered = pending
                pending.removeAll()
                return slip.feed(buffered).compactMap { try? OSCDecoder.decode($0) }
            }
            if let newline = pending.firstIndex(where: { $0 == 0x0a || $0 == 0x0d }) {
                // Only call it text when everything before the line break is
                // printable; a binary SLIP payload can contain 0x0A and must not
                // be mistaken for a line-oriented controller.
                let printable = pending[..<newline].allSatisfy { $0 == 0x09 || $0 >= 0x20 }
                if printable {
                    mode = .text
                    let buffered = pending
                    pending.removeAll()
                    return text(buffered)
                }
            }
            if pending.count > 4_096 {
                // A device that never sends a delimiter is not speaking either
                // protocol; drop the buffer rather than growing without bound.
                pending.removeAll()
                discardedFrames += 1
            }
            return []
        }
    }

    private mutating func text(_ bytes: [UInt8]) -> [OSCPacket] {
        textBuffer.append(contentsOf: bytes)
        var output: [OSCPacket] = []
        while let index = textBuffer.firstIndex(where: { $0 == 0x0a || $0 == 0x0d }) {
            let line = textBuffer[..<index]
            textBuffer.removeFirst(index - textBuffer.startIndex + 1)
            guard let message = OSCSerialCodec.parseText(String(decoding: line, as: UTF8.self)) else { continue }
            output.append(.message(message))
        }
        if textBuffer.count > 4_096 {
            textBuffer.removeAll()
            discardedFrames += 1
        }
        return output
    }
}

public final class SerialTransport {
    public var onFrame: ((OSCPacket, UInt64) -> Void)?
    public var onError: ((String) -> Void)?
    public var onDisconnect: (() -> Void)?

    public private(set) var path: String?
    public private(set) var framing: SerialFraming = .auto
    public private(set) var activeFraming: SerialFraming = .auto
    public private(set) var bytesIn = 0
    public private(set) var framesIn = 0
    public private(set) var bytesOut = 0

    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "flxbridge.serial")
    private var framer = OSCSerialFramer()
    private var loggedUnreadable = false

    public init() {}

    public var isOpen: Bool { descriptor >= 0 }

    /// USB serial devices only; Bluetooth and debug consoles are excluded.
    public static func availablePorts() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev") else { return [] }
        let prefixes = ["cu.usbmodem", "cu.usbserial", "cu.wchusbserial", "cu.SLAB_USBtoUART",
                        "cu.usb", "cu.serial", "cu.wchusb", "cu.usbtmc"]
        var paths = Set<String>()
        for name in names where !name.lowercased().contains("bluetooth") {
            guard prefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            paths.insert("/dev/" + name)
        }
        // A `cu.*` and `tty.*` node point at the same hardware; callers only need one.
        for path in paths where path.hasPrefix("/dev/tty.") {
            let callout = path.replacingOccurrences(of: "/dev/tty.", with: "/dev/cu.")
            if paths.contains(callout) { paths.remove(path) }
        }
        return paths.sorted()
    }

    /// Pick the device to open. A configured path wins while it is present; when
    /// the controller has been unplugged and comes back under a different name
    /// (or the saved path is stale) this falls back to auto-detection, so the
    /// link recovers on its own instead of needing the setting cleared.
    public static func resolve(configured: String, available: [String]) -> String? {
        if !configured.isEmpty, available.contains(configured) { return configured }
        // Falling back must not open whatever happens to be plugged in: a stray
        // Bluetooth or debug console node is not a controller.
        let usb = available.filter { path in
            let lower = path.lowercased()
            return lower.contains("usb") || lower.contains("slab")
        }
        return preferredPort(from: usb)
    }

    /// Identity of the device node behind `path`. A replug normally produces a
    /// different inode/device number, which is how a still-open but dead
    /// descriptor is told apart from a healthy one.
    public static func deviceIdentity(_ path: String) -> UInt64? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return (UInt64(truncatingIfNeeded: info.st_rdev) << 20) ^ UInt64(truncatingIfNeeded: info.st_ino)
    }

    /// True when the descriptor we hold no longer refers to the device it was
    /// opened on. USB serial nodes disappear on unplug, but the descriptor stays
    /// open, so without this check the bridge never reopens the port.
    public static func isStale(path: String?, identity: UInt64?) -> Bool {
        guard let path, !path.isEmpty, let identity else { return true }
        guard let current = deviceIdentity(path) else { return true }
        return current != identity
    }

    public static func preferredPort(from ports: [String]) -> String? {
        // ESP32-S3 native USB usually shows up as usbmodem; CP210x/CH340 adapters
        // show up as usbserial/wchusbserial. Prefer the native names.
        let ranked = ["usbmodem", "usbserial", "wchusbserial", "SLAB", "wchusb", "serial"]
        for needle in ranked {
            if let match = ports.first(where: { $0.contains(needle) }) { return match }
        }
        return ports.count == 1 ? ports.first : nil
    }

    public func start(path requested: String?, baud: Int = SerialTransport.defaultBaud,
                      framing: SerialFraming = .auto) throws {
        stop()
        let path: String
        if let requested, !requested.isEmpty {
            path = requested
        } else {
            let ports = Self.availablePorts()
            guard let detected = Self.preferredPort(from: ports) else {
                let detail = ports.isEmpty ? "no USB serial devices found" : "several ports: " + ports.joined(separator: ", ")
                throw NSError(domain: "FLXBridge", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Choose a serial port (\(detail))"])
            }
            path = detected
        }

        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw posixError("Open \(path)") }
        do {
            Self.releaseModemLines(fd)
            try configure(fd, baud: baud)
        } catch {
            close(fd)
            throw error
        }
        descriptor = fd
        self.path = path
        self.framing = framing
        activeFraming = framing
        framer = OSCSerialFramer(framing: framing)
        bytesIn = 0
        framesIn = 0
        bytesOut = 0
        loggedUnreadable = false

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
        path = nil
    }

    public func send(_ message: OSCMessage) {
        send(.message(message))
    }

    public func send(_ packet: OSCPacket) {
        guard descriptor >= 0 else { return }
        let encoded = OSCEncoder.encode(packet)
        let data: Data
        switch activeFraming {
        case .text:
            if case .message(let message) = packet { data = OSCSerialCodec.textLine(message) } else { data = OSCSerialCodec.slip(encoded) }
        case .slip, .auto:
            data = OSCSerialCodec.slip(encoded)
        }
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { buffer in
                write(descriptor, buffer.baseAddress, buffer.count)
            }
            if written > 0 {
                offset += written
                bytesOut += written
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return // the link is saturated; drop this update rather than block the engine
            } else {
                onError?("Serial write failed: \(String(cString: strerror(errno)))")
                return
            }
        }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let ingress = DispatchTime.now().uptimeNanoseconds
                bytesIn += count
                let packets = framer.feed(Array(buffer[0..<count]))
                if framer.mode != .auto { activeFraming = framer.mode }
                discardedFrames = framer.discardedFrames
                for packet in packets {
                    framesIn += 1
                    onFrame?(packet, ingress)
                }
            } else if count == 0 {
                // Some USB drivers and pseudo-terminals report zero once their
                // current buffer is drained rather than EAGAIN. Only call it a
                // disconnect when the device node is actually gone.
                if let path, FileManager.default.fileExists(atPath: path) {
                    return
                }
                let path = self.path ?? "serial device"
                stop()
                onError?("\(path) disconnected")
                onDisconnect?()
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                let message = "Serial read failed: \(String(cString: strerror(errno)))"
                stop()
                onError?(message)
                onDisconnect?()
                return
            }
        }
    }

    private var discardedFrames = 0

    /// Deassert DTR and RTS straight after opening the port.
    ///
    /// An ESP32 (or any board with the usual two-transistor auto-reset circuit)
    /// holds EN/GPIO0 low while both lines are asserted, which pins the chip in
    /// reset for as long as the port stays open: the firmware never starts, so a
    /// controller looks dead and a display never initialises. Clearing them on
    /// open lets the sketch run; flashing tools still drive the lines themselves.
    private static func releaseModemLines(_ fd: Int32) {
        var lines: Int32 = 0
        _ = ioctl(fd, TIOCMSET, &lines)
    }

    /// macOS termios stops at 230400; faster rates need IOSSIOSPEED.
    private static let ioctlSetSpeed = UInt(0x8004_5402)
    /// Highest rate a plain termios call can express.
    private static let termiosMaximum = 230_400

    private func configure(_ fd: Int32, baud: Int) throws {
        let expressible = baud > Self.termiosMaximum
        guard let speed = Self.speed(expressible ? Self.termiosMaximum : baud) else {
            throw NSError(domain: "FLXBridge", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Unsupported serial baud rate \(baud)"])
        }
        var settings = termios()
        guard tcgetattr(fd, &settings) == 0 else { throw posixError("Read serial settings") }
        cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        settings.c_cflag &= ~tcflag_t(PARENB)
        settings.c_cflag &= ~tcflag_t(CSTOPB)
        settings.c_cflag &= ~tcflag_t(CSIZE)
        settings.c_cflag |= tcflag_t(CS8)
        settings.c_cc.16 = 0 // VMIN
        settings.c_cc.17 = 0 // VTIME
        cfsetispeed(&settings, speed)
        cfsetospeed(&settings, speed)
        guard tcsetattr(fd, TCSANOW, &settings) == 0 else { throw posixError("Configure serial") }
        tcflush(fd, TCIOFLUSH)
        if expressible {
            var rate = speed_t(baud)
            guard ioctl(fd, Self.ioctlSetSpeed, &rate) == 0 else {
                throw posixError("Set serial speed \(baud)")
            }
        }
    }

    private static func speed(_ baud: Int) -> speed_t? {
        switch baud {
        case 9_600: return speed_t(B9600)
        case 19_200: return speed_t(B19200)
        case 38_400: return speed_t(B38400)
        case 57_600: return speed_t(B57600)
        case 115_200: return speed_t(B115200)
        case 230_400: return speed_t(B230400)
        default: return nil
        }
    }

    private func posixError(_ context: String) -> NSError {
        NSError(domain: "FLXBridge", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "\(context): \(String(cString: strerror(errno)))"])
    }
}

extension SerialTransport {
    /// 921600 is the firmware's default: at 115200 a 21-byte ping costs 1.8 ms
    /// each way, which is most of the measured round trip. 460800 is the safe
    /// fallback for a bridge that cannot hold the higher rate.
    public static let baudRates = [9_600, 19_200, 38_400, 57_600, 115_200, 230_400,
                                   460_800, 921_600]
    public static let defaultBaud = 921_600
}
