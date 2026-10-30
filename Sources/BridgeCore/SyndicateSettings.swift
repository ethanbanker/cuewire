import Foundation

/// Ports and feedback state read from Syndicate's own settings file.
///
/// Syndicate reads OSC on `osc.listenPort` and sends feedback to
/// `osc.feedbackHost:osc.feedbackPort`. Reading that file lets the bridge match
/// the running app instead of assuming the defaults, which is the most common
/// reason "nothing is sent" (the datagrams go to a port nobody listens on).
public struct SyndicateSettings: Sendable {
    public var settingsPath: String
    public var oscEnabled: Bool
    public var listenPort: Int?
    public var feedbackPort: Int?
    public var feedbackHost: String?
    public var subscriptionCount: Int
    public var hasBridgeSubscriptions: Bool
    /// OSC namespace the app publishes feedback on ("Syndicate", "AutoPilot"
    /// on a pre-rename build, or a custom root).
    public var namespace: String?
    /// Full address root, including any extra segments: `/Syndicate`, or
    /// `/Stage/Left` when the root has been changed in the OSC API window.
    public var addressRoot: String?
    /// Every feedback route the running Syndicate build has subscribed to. The
    /// mapping editor merges these into its route picker, which is how the list
    /// tracks app versions without a hard-coded API dump.
    public var feedbackPaths: [String]
    /// `general.cueColor1…8`, the eight hot-cue swatches Syndicate paints on its
    /// decks, in the app's own `AARRGGBB` spelling. Slots the file does not name
    /// are empty strings, so index *n* is always hot cue *n*.
    public var cueColours: [String]

    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Syndicate/Syndicate.settings")
            .path
    }

    /// The app shipped as AUTO/PILOT before the rename and kept its settings in
    /// that folder. The OSC routes are identical, so the same reader applies.
    public static var legacyPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoPilot/AutoPilot.settings")
            .path
    }

    public static var searchPaths: [String] { [defaultPath, legacyPath] }

    /// The first settings file that exists, so a renamed app is still found.
    public static func detect() -> SyndicateSettings? {
        detect(in: searchPaths)
    }

    public static func detect(in paths: [String]) -> SyndicateSettings? {
        for path in paths {
            if let detected = detect(path: path) { return detected }
        }
        return nil
    }

    public static func detect(path: String) -> SyndicateSettings? {
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
        // whatever this build publishes on, so match the area instead of assuming
        // "/Syndicate": a modern build subscribes to "/Syndicate/Deck/1/Playing" for
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
        // Keep every segment before the area: a custom root such as
        // `/Stage/Left/` must not collapse to `/Stage`.
        var addressRoot: String?
        for path in paths {
            let parts = path.split(separator: "/")
            guard let area = parts.firstIndex(where: { areas.contains($0.lowercased()) }),
                  area > 0 else { continue }
            addressRoot = "/" + parts[..<area].joined(separator: "/")
            break
        }
        // The hot-cue palette is a general preference rather than an OSC
        // setting, but it is the only place the app publishes the colours, and
        // the pod strip wants them.
        var cueColours = Array(repeating: "", count: 8)
        if let general = root["general"] as? [String: Any] {
            for slot in 1...8 {
                if let colour = general["cueColor\(slot)"] as? String {
                    cueColours[slot - 1] = colour
                }
            }
        }
        return SyndicateSettings(
            settingsPath: path,
            oscEnabled: (osc["enabled"] as? Bool) ?? true,
            listenPort: (osc["listenPort"] as? NSNumber)?.intValue,
            feedbackPort: (osc["feedbackPort"] as? NSNumber)?.intValue,
            feedbackHost: osc["feedbackHost"] as? String,
            subscriptionCount: paths.count,
            hasBridgeSubscriptions: covered > 0,
            namespace: namespace,
            addressRoot: addressRoot,
            feedbackPaths: paths,
            cueColours: cueColours
        )
    }

    public var summary: String {
        guard let listenPort else { return "Syndicate settings found but OSC ports are missing" }
        let feedback = feedbackPort.map(String.init) ?? "?"
        var summary = "Syndicate listens on \(listenPort), feedback to \(feedbackHost ?? "127.0.0.1"):\(feedback)"
        if let namespace { summary += ", namespace /\(namespace)" }
        return summary
    }
}
