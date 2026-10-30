import Foundation
import Darwin

/// One outbound OSC target. The bridge is a hub: Syndicate is the primary
/// destination and any number of extra machines/apps can be added by prefix.
public struct OSCDestination: Hashable, Sendable {
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public var label: String { "\(host):\(port)" }
}

public final class OSCTransport {
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "flxbridge.osc")
    private let lock = NSLock()
    private var destinations: [OSCDestination: sockaddr_in] = [:]
    private var primary: OSCDestination?
    public var onPacket: ((OSCPacket) -> Void)?
    public var onError: ((String) -> Void)?

    public init() {}

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return descriptor >= 0
    }

    public var currentDestinations: [OSCDestination] {
        lock.lock()
        defer { lock.unlock() }
        return Array(destinations.keys)
    }

    public func start(destination host: String, port: UInt16, bindPort: UInt16,
                      bindHost: String = "127.0.0.1") throws {
        try start(destinations: [OSCDestination(host: host, port: port)], bindPort: bindPort,
                  bindHost: bindHost)
    }

    /// `bindHost` is where incoming OSC is accepted. The default loopback is
    /// right for a socket that only ever hears from an app on this Mac; a
    /// controller on the LAN needs "0.0.0.0", which accepts every interface.
    public func start(destinations: [OSCDestination], bindPort: UInt16,
                      bindHost: String = "127.0.0.1") throws {
        stop()
        guard !destinations.isEmpty else {
            throw NSError(domain: "FLXBridge", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Add at least one OSC destination"])
        }
        let mapped = try destinations.reduce(into: [OSCDestination: sockaddr_in]()) { result, destination in
            result[destination] = try Self.makeAddress(host: destination.host, port: destination.port)
        }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            throw posixError("Create OSC socket")
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var bindAddress = sockaddr_in()
        bindAddress.sin_family = sa_family_t(AF_INET)
        bindAddress.sin_port = bindPort.bigEndian
        guard inet_pton(AF_INET, bindHost, &bindAddress.sin_addr) == 1 else {
            close(fd)
            throw NSError(domain: "FLXBridge", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "OSC bind host must be an IPv4 address, for example 0.0.0.0 (got \(bindHost))"])
        }
        let bound = withUnsafePointer(to: &bindAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let error = posixError("Bind OSC port \(bindPort) on \(bindHost) (is another bridge running?)")
            close(fd)
            throw error
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        lock.lock()
        self.descriptor = fd
        self.destinations = mapped
        self.primary = destinations.first
        lock.unlock()

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.receive()
        }
        source.resume()
        self.source = source
    }

    /// Live-update the hub destinations without dropping the feedback socket.
    public func setDestinations(_ destinations: [OSCDestination]) {
        let mapped = destinations.reduce(into: [OSCDestination: sockaddr_in]()) { result, destination in
            if let value = try? Self.makeAddress(host: destination.host, port: destination.port) {
                result[destination] = value
            }
        }
        lock.lock()
        if !mapped.isEmpty {
            self.destinations = mapped
            if primary == nil || !mapped.keys.contains(primary!) {
                primary = destinations.first
            }
        }
        lock.unlock()
    }

    public func stop() {
        source?.cancel()
        source = nil
        lock.lock()
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
        destinations.removeAll()
        primary = nil
        lock.unlock()
    }

    public func send(_ message: OSCMessage) {
        send(message, to: nil)
    }

    public func send(_ message: OSCMessage, to destination: OSCDestination?) {
        let data = [UInt8](OSCEncoder.encode(message))
        lock.lock()
        let descriptor = self.descriptor
        let target = (destination.flatMap { destinations[$0] }) ?? primary.flatMap { destinations[$0] }
        lock.unlock()
        guard descriptor >= 0, var address = target else { return }
        _ = data.withUnsafeBufferPointer { buffer in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, buffer.baseAddress, buffer.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func receive() {
        var buffer = [UInt8](repeating: 0, count: 65535)
        while true {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(descriptor, &buffer, buffer.count, 0, $0, &length)
                }
            }
            guard count > 0 else { return }
            let data = Data(buffer[0..<count])
            guard let packet = try? OSCDecoder.decode(data) else {
                onError?("Discarded unreadable OSC packet (\(count) bytes)")
                continue
            }
            onPacket?(packet)
        }
    }

    private static func makeAddress(host: String, port: UInt16) throws -> sockaddr_in {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else {
            throw NSError(domain: "FLXBridge", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "OSC destination must be an IPv4 address, for example 127.0.0.1 (got \(host))"])
        }
        var value = sockaddr_in()
        value.sin_family = sa_family_t(AF_INET)
        value.sin_port = port.bigEndian
        value.sin_addr = address
        return value
    }

    private func posixError(_ context: String) -> NSError {
        NSError(domain: "FLXBridge", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "\(context): \(String(cString: strerror(errno)))"])
    }
}
