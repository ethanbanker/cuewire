import Foundation

/// How Cuewire treats one message arriving from a serial controller.
public enum SerialInputKind: Equatable, Sendable {
    /// Link housekeeping the board owns: ping replies, track echoes and the
    /// board's request for missing metadata. Consumed here, never forwarded.
    case housekeeping
    /// Device-owned, mappable-only input such as the Nexus 4 rotary encoder. It
    /// has no fixed action, so it reaches a destination only through a learned
    /// mapping; forwarding an unmapped turn would put an unknown route on
    /// Syndicate for every detent.
    case mappable
    /// Controller input. Runs through the mapping engine when a mapping exists
    /// and is forwarded through the hub otherwise.
    case control
}

/// The controller's own OSC namespace.
///
/// Nexus 4 speaks `/Nexus`. Firmware from before the rename speaks `/Aether`,
/// and a saved mapping may still name it, so the old prefix is folded onto the
/// new one rather than left to fail quietly.
public enum NexusAddress {
    public static let prefix = "/Nexus"
    public static let legacyPrefix = "/Aether"
    public static let ping = prefix + "/Ping"

    /// Rewrite a legacy `/Aether/...` address as `/Nexus/...`. Any other address
    /// is returned unchanged, so custom controllers keep their own names.
    public static func canonical(_ address: String) -> String {
        let legacy = legacyPrefix.lowercased()
        let lower = address.lowercased()
        guard lower == legacy || lower.hasPrefix(legacy + "/") else { return address }
        return prefix + address.dropFirst(legacyPrefix.count)
    }
}

/// Classifies serial input by address, kept pure so the rules can be checked
/// without a board attached.
public enum SerialInputRouter {
    public static func kind(for address: String) -> SerialInputKind {
        let lower = NexusAddress.canonical(address).lowercased()
        if lower == "/nexus/pong" || lower.hasPrefix("/nexus/track")
            || lower.hasPrefix("/nexus/needtrack/") {
            return .housekeeping
        }
        if lower.hasPrefix("/nexus/encoder/") {
            return .mappable
        }
        return .control
    }
}
