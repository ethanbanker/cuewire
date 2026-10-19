import AppKit
import BridgeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let service = BridgeService.shared
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var toggleItem: NSMenuItem?
    private var statusLabelItem: NSMenuItem?
    private var openItem: NSMenuItem?
    private var signalSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandler()
        buildMainMenu()
        buildStatusItem()
        buildWindow()
        service.startIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        service.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    // MARK: - Window

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Cuewire"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Palette.background
        window.minSize = NSSize(width: 1060, height: 760)
        window.contentViewController = MainViewController()
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.setFrameAutosaveName("FLXBridgeMainWindow")
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        service.log(.info, "Cuewire window ready")
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Cuewire", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Cuewire", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let bridgeItem = NSMenuItem()
        let bridgeMenu = NSMenu(title: "Bridge")
        bridgeMenu.addItem(withTitle: "Show Cuewire", action: #selector(showWindow), keyEquivalent: "0")
        bridgeMenu.addItem(.separator())
        bridgeMenu.addItem(withTitle: "Start Bridge", action: #selector(toggleBridge), keyEquivalent: "b")
        bridgeMenu.addItem(withTitle: "Reconnect MIDI", action: #selector(reconnect), keyEquivalent: "m")
        bridgeMenu.addItem(.separator())
        bridgeMenu.addItem(withTitle: "OSC Mapping…", action: #selector(openMapping), keyEquivalent: "l")
        bridgeMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        // Screenshot export is a README tool, so it only appears when asked for.
        if CommandLine.arguments.contains("--screenshots") {
            bridgeMenu.addItem(.separator())
            bridgeMenu.addItem(withTitle: "Save Screenshot", action: #selector(exportScreenshots), keyEquivalent: "")
        }
        bridgeItem.submenu = bridgeMenu
        mainMenu.addItem(bridgeItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu bar icon

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Cuewire")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Cuewire"
        }
        let menu = NSMenu()
        menu.delegate = self

        let open = NSMenuItem(title: "Open Cuewire", action: #selector(showWindow), keyEquivalent: "")
        let status = NSMenuItem(title: "Waiting for DDJ-FLX4", action: nil, keyEquivalent: "")
        status.isEnabled = false
        let toggle = NSMenuItem(title: "Start Bridge", action: #selector(toggleBridge), keyEquivalent: "")
        let reconnect = NSMenuItem(title: "Reconnect MIDI", action: #selector(reconnect), keyEquivalent: "")
        let quit = NSMenuItem(title: "Quit Cuewire", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        [open, status, toggle, reconnect, quit].forEach(menu.addItem)
        menu.insertItem(.separator(), at: 1)
        menu.insertItem(.separator(), at: 5)

        item.menu = menu
        statusItem = item
        service.log(.info, "Menu bar icon ready")
        openItem = open
        statusLabelItem = status
        toggleItem = toggle
        syncMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        syncMenu()
    }

    private func syncMenu() {
        toggleItem?.title = service.running ? "Stop Bridge" : "Start Bridge"
        statusLabelItem?.title = service.deviceConnected
            ? "DDJ-FLX4 connected · \(service.oscSent) OSC sent"
            : "Waiting for DDJ-FLX4"
        openItem?.title = "Open Cuewire"
    }

    private func installSignalHandler() {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        signalSource = source
    }

    // MARK: - Actions

    @objc private func showWindow() {
        if window == nil { buildWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleBridge() {
        service.toggle()
        syncMenu()
    }

    @objc private func reconnect() {
        service.reconnectMIDI()
        syncMenu()
    }

    @objc private func openSettings() {
        showWindow()
        guard let window else { return }
        SettingsWindowController.present(over: window)
    }

    @objc private func openMapping() {
        MappingWindowController.present()
    }

    /// Writes the app's own windows to /tmp/cuewire-shots for the README. Own-window
    /// capture needs no screen-recording permission, so it also works on a fresh machine.
    @objc private func exportScreenshots() {
        let directory = "/tmp/cuewire-shots"
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for window in NSApp.windows where window.isVisible {
            let name: String
            switch window.title {
            case "Cuewire": name = "main"
            case "Cuewire Settings": name = "settings"
            default: name = window.title.contains("OSC Mapping") ? "mapping" : "window"
            }
            guard let image = capture(window), let data = image.representation(using: .png, properties: [:]) else {
                service.log(.warn, "Could not capture \(window.title)")
                continue
            }
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
            try? data.write(to: url)
            service.log(.info, "Screenshot: \(url.path)")
        }
    }

    private func capture(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView, let layer = view.layer else { return nil }
        let scale = window.backingScaleFactor
        let width = Int(view.bounds.width * scale)
        let height = Int(view.bounds.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.scaleBy(x: scale, y: scale)
        // Compositing the layer tree keeps the layer-backed header, pills and
        // buttons, which a plain drawRect capture would drop.
        layer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }
}
