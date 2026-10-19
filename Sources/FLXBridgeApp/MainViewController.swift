import AppKit
import BridgeCore

final class MainViewController: NSViewController {
    private let service = BridgeService.shared
    private let surface = SurfaceCanvas()
    private let midiPill = PillView()
    private let serialPill = PillView()
    private let oscPill = PillView()
    private let feedbackPill = PillView()
    private let latencyPill = PillView()
    private let startButton = NSButton(title: "Start", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "CUEWIRE")
    private let subtitleLabel = NSTextField(labelWithString: "CONTROLLERS  →  OSC API")
    private let brandMark = BrandMark()
    private let errorLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let logView = NSTextView()
    private let logScroll = NSScrollView()
    private var lastLogCount = -1

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Palette.background.cgColor
        view = root

        titleLabel.attributedStringValue = NSAttributedString(
            string: "CUEWIRE",
            attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .heavy),
                .foregroundColor: Palette.text,
                .kern: 1.8,
            ])
        subtitleLabel.attributedStringValue = NSAttributedString(
            string: "CONTROLLERS  →  OSC API",
            attributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
                .foregroundColor: Palette.muted,
                .kern: 0.5,
            ])

        brandMark.translatesAutoresizingMaskIntoConstraints = false
        brandMark.widthAnchor.constraint(equalToConstant: 30).isActive = true
        brandMark.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 0

        startButton.target = self
        startButton.action = #selector(toggleBridge)
        startButton.bezelStyle = .rounded
        startButton.font = .systemFont(ofSize: 11, weight: .semibold)
        startButton.controlSize = .small
        startButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 62).isActive = true

        let mappingButton = NSButton(image: NSImage(systemSymbolName: "slider.horizontal.3",
                                                    accessibilityDescription: "Mapping")!,
                                     target: self, action: #selector(openMapping))
        mappingButton.bezelStyle = .rounded
        mappingButton.controlSize = .small
        mappingButton.toolTip = "OSC mapping and destinations"

        let settingsButton = NSButton(image: NSImage(systemSymbolName: "gearshape.fill",
                                                     accessibilityDescription: "Settings")!,
                                      target: self, action: #selector(openSettings))
        settingsButton.bezelStyle = .rounded
        settingsButton.controlSize = .small
        settingsButton.toolTip = "Settings"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [brandMark, titleStack, spacer, midiPill, serialPill, oscPill,
                                         feedbackPill, latencyPill, startButton,
                                         mappingButton, settingsButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 9
        header.setCustomSpacing(12, after: brandMark)
        header.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.font = .systemFont(ofSize: 11, weight: .medium)
        errorLabel.textColor = Palette.red
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        surface.translatesAutoresizingMaskIntoConstraints = false

        let activityTitle = NSTextField(labelWithString: "ACTIVITY")
        activityTitle.font = .systemFont(ofSize: 10, weight: .bold)
        activityTitle.textColor = Palette.muted

        statsLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        statsLabel.textColor = Palette.muted
        statsLabel.alignment = .right

        let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearLog))
        clearButton.isBordered = false
        clearButton.font = .systemFont(ofSize: 10)
        clearButton.contentTintColor = Palette.muted

        let activityHeader = NSStackView(views: [activityTitle, NSView(), statsLabel, clearButton])
        activityHeader.orientation = .horizontal
        activityHeader.alignment = .centerY
        activityHeader.spacing = 10

        logView.isEditable = false
        logView.isSelectable = true
        logView.drawsBackground = false
        logView.textContainerInset = NSSize(width: 8, height: 6)
        logView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logScroll.documentView = logView
        logScroll.drawsBackground = false
        logScroll.hasVerticalScroller = true
        logScroll.autohidesScrollers = true
        logScroll.wantsLayer = true
        logScroll.layer?.backgroundColor = Palette.panel.cgColor
        logScroll.layer?.cornerRadius = Palette.radius
        logScroll.layer?.borderColor = Palette.stroke.cgColor
        logScroll.layer?.borderWidth = 1
        logScroll.translatesAutoresizingMaskIntoConstraints = false

        let activityStack = NSStackView(views: [activityHeader, logScroll])
        activityStack.orientation = .vertical
        activityStack.alignment = .leading
        activityStack.spacing = 6
        activityStack.translatesAutoresizingMaskIntoConstraints = false
        activityStack.setHuggingPriority(.defaultHigh, for: .vertical)

        root.addSubview(header)
        root.addSubview(errorLabel)
        root.addSubview(surface)
        root.addSubview(activityStack)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 44),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            errorLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            errorLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            errorLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            surface.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 12),
            surface.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            surface.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            surface.heightAnchor.constraint(greaterThanOrEqualToConstant: 460),

            activityStack.topAnchor.constraint(equalTo: surface.bottomAnchor, constant: 12),
            activityStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            activityStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            activityStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            logScroll.heightAnchor.constraint(equalToConstant: 150),
            activityStack.widthAnchor.constraint(equalTo: surface.widthAnchor),
        ])

        service.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nil)
    }

    private func refresh() {
        let running = service.running
        let flx4Connected = service.midiInputs.contains { MIDITransport.isFLX4($0) }
        midiPill.update(title: "MIDI",
                        value: service.deviceConnected ? (flx4Connected ? "FLX4" : "controller") : "waiting",
                        color: service.deviceConnected ? Palette.green : Palette.amber)
        midiPill.toolTip = service.midiInputs.isEmpty
            ? "No MIDI inputs seen"
            : "Inputs: " + service.midiInputs.joined(separator: ", ")
        serialPill.update(title: "Serial",
                          value: service.serialConnected ? "\(service.serialBaud)" : (service.serialEnabled ? "waiting" : "off"),
                          color: service.serialConnected ? Palette.green : (service.serialEnabled ? Palette.amber : Palette.muted))
        serialPill.toolTip = service.serialConnected
            ? "OSC over serial on \(service.serialPath ?? "?")"
            : (service.serialError ?? "No serial controller connected")
        let sentTotal = service.oscSent + service.passthroughSent
        oscPill.update(title: "OSC",
                       value: running ? "\(service.destinationPort) · \(sentTotal)" : "stopped",
                       color: running ? (sentTotal > 0 ? Palette.green : Palette.amber) : Palette.red)
        oscPill.toolTip = "Sending to \(service.destination):\(service.destinationPort)"
        feedbackPill.update(title: "Feedback",
                            value: "\(service.feedbackCount)",
                            color: service.feedbackCount > 0 ? Palette.teal : Palette.muted)
        let candidates = [LatencySource.serial, .osc, .midi]
            .compactMap { service.latency[$0] }
            .filter { $0.count > 0 }
        let latency = candidates.max { $0.p95 < $1.p95 } ?? .empty
        latencyPill.update(title: "Latency",
                           value: latency.short,
                           color: latency.count > 0 ? Palette.teal : Palette.muted)
        latencyPill.toolTip = "Input → OSC wire  MIDI: \(service.latency[.midi]?.detailed ?? "none")\nSerial: \(service.latency[.serial]?.detailed ?? "none")\nOSC in: \(service.latency[.osc]?.detailed ?? "none")\nFeedback round-trip: \(service.roundTrip.detailed)"
        startButton.title = running ? "Stop" : "Start"
        startButton.contentTintColor = running ? Palette.text : Palette.accent
        surface.snapshot = service.snapshot
        statsLabel.stringValue = "\(service.oscSent) OSC · \(service.passthroughSent) serial pass-through · \(service.serialFrames) serial frames · RTT \(service.roundTrip.short)"
        if let error = service.lastError {
            errorLabel.stringValue = "  \(error)"
            errorLabel.isHidden = false
        } else {
            errorLabel.isHidden = true
        }
        if service.logs.count != lastLogCount {
            lastLogCount = service.logs.count
            renderLog()
        }
    }

    private func renderLog() {
        let output = NSMutableAttributedString()
        let timeStyle = NSMutableParagraphStyle()
        timeStyle.lineBreakMode = .byTruncatingTail
        for entry in service.logs.suffix(240) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let time = NSAttributedString(string: formatter.string(from: entry.date) + "  ", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: Palette.muted.withAlphaComponent(0.7),
                .paragraphStyle: timeStyle,
            ])
            let color: NSColor
            switch entry.level {
            case .info: color = Palette.muted
            case .warn: color = Palette.amber
            case .error: color = Palette.red
            }
            let message = NSAttributedString(string: entry.message + "\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: color,
                .paragraphStyle: timeStyle,
            ])
            output.append(time)
            output.append(message)
        }
        logView.textStorage?.setAttributedString(output)
        logView.scrollToEndOfDocument(nil)
    }

    @objc private func toggleBridge() {
        service.toggle()
    }

    @objc private func clearLog() {
        service.clearLog()
        lastLogCount = -1
    }

    @objc private func openSettings() {
        guard let window = view.window else { return }
        SettingsWindowController.present(over: window)
    }

    @objc private func openMapping() {
        MappingWindowController.present()
    }
}
