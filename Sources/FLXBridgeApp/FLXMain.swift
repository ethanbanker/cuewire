import AppKit

@main
struct FLXMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            do {
                try SnapshotRenderer.render(to: arguments[index + 1])
                print("Wrote snapshot to \(arguments[index + 1])")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Snapshot failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        if arguments.contains("--ui-smoke") {
            // Verification hook: build the mapping window on a real run loop and
            // quit, so layout/constraint regressions surface without hardware.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MappingWindowController.present()
                if let parent = NSApp.windows.first(where: { $0.title == "Cuewire" }) {
                    SettingsWindowController.present(over: parent)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    exit(0)
                }
            }
        }
        application.run()
    }
}
