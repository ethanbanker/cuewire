import Foundation

/// Ports and feedback state read from AUTO/PILOT's own settings file.
///
/// AUTO/PILOT reads OSC on `osc.listenPort` and sends feedback to
/// `osc.feedbackHost:osc.feedbackPort`. Reading that file lets the bridge match
/// the running app instead of assuming the defaults, which is the most common
/// reason "nothing is sent" (the datagrams go to a port nobody listens on).
public struct AutoPilotSettings: Sendable {
    public var settingsPath: String
    public var oscEnabled: Bool
    public var listenPort: Int?
    public var feedbackPort: Int?
    public var feedbackHost: String?
    public var subscriptionCount: Int
    public var hasBridgeSubscriptions: Bool
    /// OSC namespace AP publishes feedback on ("Syndicate", "AutoPilot", ...).
    public var namespace: String?
    /// Every feedback route the running AUTO/PILOT build has subscribed to. The
    /// mapping editor merges these into its route picker, which is how the list
    /// tracks AP versions without a hard-coded API dump.
    public var feedbackPaths: [String]

    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoPilot/AutoPilot.settings")
            .path
    }

    public static func detect(path: String = AutoPilotSettings.defaultPath) -> AutoPilotSettings? {
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let osc = root["osc"] as? [String: Any] else {
            return nil
        }
        var paths: [String] = []
        if let subscriptions = osc["feedbackSubscriptions"] as? String,
           let raw = subscriptions.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
           let list = parsed["paths"] as? [String] {
            paths = list
        }
        // Subscriptions are written as "<namespace>/<area>/...". The namespace is
        // whatever this AP build publishes on, so match the area instead of assuming
        // "/AutoPilot": a modern build subscribes to "/Syndicate/Deck/1/Playing" for
        // exactly the route the bridge uses.
        let areas: Set<String> = ["deck", "mixer", "header", "browser", "feedback", "arrangement", "sampler"]
        var namespaces: Set<String> = []
        var covered = 0
        for path in paths {
            let parts = path.split(separator: "/")
            guard parts.count >= 2 else { continue }
            guard areas.contains(parts[1].lowercased()) else { continue }
            covered += 1
            namespaces.insert(String(parts[0]))
        }
        let namespace = namespaces.count == 1 ? namespaces.first : (namespaces.isEmpty ? nil : "mixed")
        return AutoPilotSettings(
            settingsPath: path,
            oscEnabled: (osc["enabled"] as? Bool) ?? true,
            listenPort: (osc["listenPort"] as? NSNumber)?.intValue,
            feedbackPort: (osc["feedbackPort"] as? NSNumber)?.intValue,
            feedbackHost: osc["feedbackHost"] as? String,
            subscriptionCount: paths.count,
            hasBridgeSubscriptions: covered > 0,
            namespace: namespace,
            feedbackPaths: paths
        )
    }

    public var summary: String {
        guard let listenPort else { return "AUTO/PILOT settings found but OSC ports are missing" }
        let feedback = feedbackPort.map(String.init) ?? "?"
        var summary = "AUTO/PILOT listens on \(listenPort), feedback to \(feedbackHost ?? "127.0.0.1"):\(feedback)"
        if let namespace { summary += ", namespace /\(namespace)" }
        return summary
    }
}
