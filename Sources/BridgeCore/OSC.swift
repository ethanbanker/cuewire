import Foundation

/// Minimal OSC 1.0 codec: messages and bundles, int/float/string/blob arguments.
public struct OSCMessage: Equatable, Sendable {
    public var address: String
    public var arguments: [OSCArgument]

    public init(_ address: String, _ arguments: [OSCArgument] = []) {
        self.address = address
        self.arguments = arguments
    }

    public init(_ address: String, int: Int32) {
        self.init(address, [.int(int)])
    }

    public init(_ address: String, float: Double) {
        self.init(address, [.float(Float(float))])
    }

    public var firstFloat: Float? {
        for argument in arguments {
            if case .float(let value) = argument { return value }
            if case .int(let value) = argument { return Float(value) }
        }
        return nil
    }

    public var firstInt: Int32? {
        for argument in arguments {
            if case .int(let value) = argument { return value }
            if case .float(let value) = argument, value.rounded() == value { return Int32(value) }
        }
        return nil
    }

    public var firstString: String? {
        for argument in arguments {
            if case .string(let value) = argument { return value }
        }
        return nil
    }
}

public enum OSCArgument: Equatable, Sendable {
    case int(Int32)
    case float(Float)
    case string(String)
    case blob([UInt8])

    var typeTag: Character {
        switch self {
        case .int: return "i"
        case .float: return "f"
        case .string: return "s"
        case .blob: return "b"
        }
    }
}

public enum OSCPacket: Equatable, Sendable {
    case message(OSCMessage)
    case bundle([OSCPacket])

    public var messages: [OSCMessage] {
        switch self {
        case .message(let message):
            return [message]
        case .bundle(let packets):
            return packets.flatMap(\.messages)
        }
    }
}

public enum OSCError: Error, CustomStringConvertible {
    case truncated
    case notOSC
    case unsupported(String)

    public var description: String {
        switch self {
        case .truncated: return "OSC packet ended early"
        case .notOSC: return "Not an OSC packet"
        case .unsupported(let detail): return "Unsupported OSC data: \(detail)"
        }
    }
}

public enum OSCEncoder {
    public static func encode(_ packet: OSCPacket) -> Data {
        switch packet {
        case .message(let message):
            return encode(message)
        case .bundle(let packets):
            var data = pad("#bundle")
            data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 1]) // immediate timetag
            for packet in packets {
                let encoded = encode(packet)
                data.append(bigEndian: UInt32(encoded.count))
                data.append(encoded)
            }
            return data
        }
    }

    public static func encode(_ message: OSCMessage) -> Data {
        var data = pad(message.address)
        let tags = "," + String(message.arguments.map(\.typeTag))
        data.append(pad(tags))
        for argument in message.arguments {
            switch argument {
            case .int(let value):
                data.append(bigEndian: UInt32(bitPattern: value))
            case .float(let value):
                data.append(bigEndian: value.bitPattern)
            case .string(let value):
                data.append(pad(value))
            case .blob(let bytes):
                data.append(bigEndian: UInt32(bytes.count))
                data.append(contentsOf: bytes)
                data.append(contentsOf: [UInt8](repeating: 0, count: (4 - bytes.count % 4) % 4))
            }
        }
        return data
    }

    private static func pad(_ string: String) -> Data {
        var bytes = Array(string.utf8)
        let padding = 4 - bytes.count % 4 // always at least the terminating NUL
        bytes.append(contentsOf: [UInt8](repeating: 0, count: padding))
        return Data(bytes)
    }
}

public enum OSCDecoder {
    public static func decode(_ data: Data) throws -> OSCPacket {
        var reader = Reader(data: data)
        return try read(&reader, depth: 0)
    }

    private static func read(_ reader: inout Reader, depth: Int) throws -> OSCPacket {
        guard depth <= 8 else { throw OSCError.unsupported("bundle nesting") }
        if reader.remaining >= 8, reader.peek(7) == Array("#bundle".utf8) {
            _ = try reader.string()
            reader.skip(8) // timetag
            var packets: [OSCPacket] = []
            while reader.remaining >= 4 {
                let size = Int(try reader.uint32())
                guard size > 0, size <= reader.remaining else { throw OSCError.truncated }
                let payload = try reader.take(size)
                var inner = Reader(data: payload)
                packets.append(try read(&inner, depth: depth + 1))
            }
            return .bundle(packets)
        }
        let address = try reader.string()
        guard address.hasPrefix("/") else { throw OSCError.notOSC }
        guard let tags = try? reader.string(), tags.hasPrefix(",") else {
            return .message(OSCMessage(address))
        }
        var arguments: [OSCArgument] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "i":
                arguments.append(.int(Int32(bitPattern: try reader.uint32())))
            case "f":
                arguments.append(.float(Float(bitPattern: try reader.uint32())))
            case "d":
                let high = UInt64(try reader.uint32())
                let low = UInt64(try reader.uint32())
                arguments.append(.float(Float(Double(bitPattern: high << 32 | low))))
            case "s":
                arguments.append(.string(try reader.string()))
            case "b":
                let size = Int(try reader.uint32())
                guard size <= reader.remaining else { throw OSCError.truncated }
                arguments.append(.blob([UInt8](try reader.take(size))))
            case "[", "]", "T", "F", "N", "I":
                // Arrays are bracketed and carry no payload of their own; the
                // enclosed tags follow inline. T/F/N/I are payload-free too.
                // Syndicate sends /Syndicate/ColorPalette as ,[iiii][iiii]…,
                // which previously rejected the whole packet.
                continue
            case "c", "r", "m":
                _ = try reader.uint32()
            case "h", "t":
                _ = try reader.uint32()
                _ = try reader.uint32()
            case "S":
                arguments.append(.string(try reader.string()))
            default:
                throw OSCError.unsupported("type tag \(tag)")
            }
        }
        return .message(OSCMessage(address, arguments))
    }

    private struct Reader {
        let data: [UInt8]
        var offset = 0

        init(data: Data) {
            self.data = [UInt8](data)
        }

        var remaining: Int { data.count - offset }

        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= remaining else { throw OSCError.truncated }
            let slice = Data(data[offset..<offset + count])
            offset += count
            return slice
        }

        mutating func skip(_ count: Int) {
            offset = min(offset + count, data.count)
        }

        mutating func uint32() throws -> UInt32 {
            let bytes = [UInt8](try take(4))
            return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        }

        mutating func string() throws -> String {
            guard let end = data[offset...].firstIndex(of: 0) else { throw OSCError.truncated }
            let bytes = data[offset..<end]
            offset = min(((end - offset) / 4 + 1) * 4 + offset, data.count)
            return String(decoding: bytes, as: UTF8.self)
        }

        func peek(_ count: Int) -> [UInt8] {
            Array(data[offset..<min(offset + count, data.count)])
        }
    }
}

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        append(contentsOf: [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }
}
