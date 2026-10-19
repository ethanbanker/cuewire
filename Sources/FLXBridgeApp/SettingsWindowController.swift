import AppKit
import BridgeCore

final class SettingsWindowController: NSWindowController {
    private static var active: SettingsWindowController?

    private let service = BridgeService.shared
    private let destinationField = NSTextField(string: "")
    private let portField = NSTextField(string: "")
    private let feedbackField = NSTextField(string: "")
    private let controlPortField = NSTextField(string: "0")
    private let autoStartToggle = NSButton(checkboxWithTitle: "Start the bridge when the app opens",
                                           target: nil, action: nil)
    private let pickupToggle = NSButton(checkboxWithTitle: "Soft takeover (pickup) for faders and knobs",
                                        target: nil, action: nil)
    private let pickupHint = NSTextField(labelWithString: "Off sends the knob/fader's physical position immediately (rekordbox-style). On waits until it crosses AUTO/PILOT's value.")
    private let inputsLabel = NSTextField(labelWithString: "")
    private let autoPilotLabel = NSTextField(labelWithString: "")
    private let useAutoPilotButton = NSButton(title: "Use AUTO/PILOT ports", target: nil, action: nil)
    private let errorLabel = NSTextField(labelWithString: "")
    private let serialToggle = NSButton(checkboxWithTitle: "Receive OSC from a USB serial controller",
                                        target: nil, action: nil)
    private let serialPortPopup = NSPopUpButton()
    private let serialBaudPopup = NSPopUpButton()
    private let serialFramingPopup = NSPopUpButton()
    private let mirrorSerialToggle = NSButton(checkboxWithTitle: "Mirror mapped feedback back to the controller",
                                              target: nil, action: nil)
    private let serialHint = NSTextField(labelWithString: "")

    static func present(over parent: NSWindow) {
        let controller = SettingsWindowController()
        active = controller
        parent.beginSheet(controller.window!) { _ in
            active = nil
        }
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 668),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Cuewire Settings"
        window.backgroundColor = Palette.panel
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Palette.panel.cgColor

        let title = label("Settings", size: 16, weight: .bold, color: Palette.text)
        let hint = label("Start AUTO/PILOT first: its OSC input and feedback ports must match.",
                         size: 11, weight: .regular, color: Palette.muted)

        destinationField.stringValue = service.destination
        portField.stringValue = String(service.destinationPort)
        feedbackField.stringValue = String(service.feedbackPort)
        controlPortField.stringValue = String(service.controlInputPort)
        [destinationField, portField, feedbackField, controlPortField].forEach {
            $0.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        autoStartToggle.state = service.autoStart ? .on : .off
        autoStartToggle.contentTintColor = Palette.text
        pickupToggle.state = service.analogPickup ? .on : .off
        pickupToggle.contentTintColor = Palette.text
        pickupHint.font = .systemFont(ofSize: 10, weight: .regular)
        pickupHint.textColor = Palette.muted
        pickupHint.lineBreakMode = .byTruncatingTail
        pickupHint.translatesAutoresizingMaskIntoConstraints = false

        inputsLabel.stringValue = midiSummary()
        inputsLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        inputsLabel.textColor = Palette.text.withAlphaComponent(0.8)
        inputsLabel.lineBreakMode = .byTruncatingTail
        inputsLabel.translatesAutoresizingMaskIntoConstraints = false

        autoPilotLabel.font = .systemFont(ofSize: 10, weight: .regular)
        autoPilotLabel.textColor = Palette.muted
        autoPilotLabel.lineBreakMode = .byTruncatingTail
        autoPilotLabel.translatesAutoresizingMaskIntoConstraints = false
        updateAutoPilotLabel()

        useAutoPilotButton.target = self
        useAutoPilotButton.action = #selector(useAutoPilotPorts)
        useAutoPilotButton.bezelStyle = .rounded
        useAutoPilotButton.controlSize = .small
        useAutoPilotButton.font = .systemFont(ofSize: 10, weight: .regular)
        useAutoPilotButton.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.font = .systemFont(ofSize: 11, weight: .medium)
        errorLabel.textColor = Palette.red
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        serialToggle.state = service.serialEnabled ? .on : .off
        serialToggle.contentTintColor = Palette.text
        populateSerialPorts()
        for baud in SerialTransport.baudRates {
            serialBaudPopup.addItem(withTitle: String(baud))
        }
        if let index = SerialTransport.baudRates.firstIndex(of: service.serialBaud) {
            serialBaudPopup.selectItem(at: index)
        } else {
            serialBaudPopup.selectItem(at: 0)
        }
        serialFramingPopup.addItems(withTitles: SerialFraming.allCases.map { $0.label })
        serialFramingPopup.selectItem(at: SerialFraming.allCases.firstIndex(of: service.serialFraming) ?? 0)
        mirrorSerialToggle.state = service.mirrorSerialFeedback ? .on : .off
        mirrorSerialToggle.contentTintColor = Palette.text
        serialHint.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        serialHint.textColor = Palette.muted
        serialHint.lineBreakMode = .byTruncatingTail
        serialHint.translatesAutoresizingMaskIntoConstraints = false
        updateSerialHint()

        let grid = NSGridView(views: [
            [label("OSC destination", size: 11, weight: .regular, color: Palette.muted), destinationField],
            [label("OSC port", size: 11, weight: .regular, color: Palette.muted), portField],
            [label("Feedback port", size: 11, weight: .regular, color: Palette.muted), feedbackField],
            [label("OSC control in", size: 11, weight: .regular, color: Palette.muted), controlPortField],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 1).width = 140

        let midiTitle = label("MIDI inputs", size: 10, weight: .bold, color: Palette.muted)
        let serialTitle = label("USB SERIAL CONTROLLER", size: 10, weight: .bold, color: Palette.muted)
        let refreshPorts = NSButton(title: "Rescan", target: self, action: #selector(rescanSerial))
        refreshPorts.bezelStyle = .rounded
        refreshPorts.controlSize = .small
        serialPortPopup.widthAnchor.constraint(equalToConstant: 170).isActive = true
        serialBaudPopup.widthAnchor.constraint(equalToConstant: 86).isActive = true
        serialFramingPopup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let serialRow = NSStackView(views: [serialPortPopup, refreshPorts, serialBaudPopup, serialFramingPopup])
        serialRow.orientation = .horizontal
        serialRow.spacing = 6
        serialRow.translatesAutoresizingMaskIntoConstraints = false

        let reconnect = NSButton(title: "Reconnect MIDI", target: self, action: #selector(reconnect))
        reconnect.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: "Apply", target: self, action: #selector(apply))
        apply.keyEquivalent = "\r"
        let buttons = NSStackView(views: [reconnect, NSView(), cancel, apply])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        [title, hint, grid, autoPilotLabel, useAutoPilotButton, autoStartToggle, pickupToggle, pickupHint, midiTitle, inputsLabel,
         serialTitle, serialToggle, serialRow, mirrorSerialToggle, serialHint, errorLabel, buttons].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            hint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),

            grid.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            grid.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 16),

            autoPilotLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            autoPilotLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 10),
            autoPilotLabel.trailingAnchor.constraint(lessThanOrEqualTo: useAutoPilotButton.leadingAnchor, constant: -8),
            useAutoPilotButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            useAutoPilotButton.centerYAnchor.constraint(equalTo: autoPilotLabel.centerYAnchor),

            autoStartToggle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            autoStartToggle.topAnchor.constraint(equalTo: autoPilotLabel.bottomAnchor, constant: 16),
            pickupToggle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            pickupToggle.topAnchor.constraint(equalTo: autoStartToggle.bottomAnchor, constant: 8),
            pickupHint.leadingAnchor.constraint(equalTo: title.leadingAnchor, constant: 18),
            pickupHint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            pickupHint.topAnchor.constraint(equalTo: pickupToggle.bottomAnchor, constant: 1),

            midiTitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            midiTitle.topAnchor.constraint(equalTo: pickupHint.bottomAnchor, constant: 16),
            inputsLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            inputsLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            inputsLabel.topAnchor.constraint(equalTo: midiTitle.bottomAnchor, constant: 4),

            serialTitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            serialTitle.topAnchor.constraint(equalTo: inputsLabel.bottomAnchor, constant: 18),
            serialToggle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            serialToggle.topAnchor.constraint(equalTo: serialTitle.bottomAnchor, constant: 6),
            serialRow.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            serialRow.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            serialRow.topAnchor.constraint(equalTo: serialToggle.bottomAnchor, constant: 8),
            mirrorSerialToggle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            mirrorSerialToggle.topAnchor.constraint(equalTo: serialRow.bottomAnchor, constant: 8),
            serialHint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            serialHint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            serialHint.topAnchor.constraint(equalTo: mirrorSerialToggle.bottomAnchor, constant: 4),

            errorLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            errorLabel.topAnchor.constraint(equalTo: serialHint.bottomAnchor, constant: 10),

            buttons.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])

        window.contentView = root
    }

    required init?(coder: NSCoder) { fatalError() }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }

    @objc private func apply() {
        let destination = destinationField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !destination.isEmpty else {
            fail("Enter an OSC destination such as 127.0.0.1")
            return
        }
        guard let port = Int(portField.stringValue), (1...65535).contains(port),
              let feedback = Int(feedbackField.stringValue), (1...65535).contains(feedback),
              let control = Int(controlPortField.stringValue), control == 0 || (1...65535).contains(control) else {
            fail("Ports must be numbers between 1 and 65535 (control input may be 0 to disable)")
            return
        }
        let serialPort = serialPortPopup.indexOfSelectedItem <= 0
            ? "" : (serialPortPopup.titleOfSelectedItem ?? "")
        let baud = Int(serialBaudPopup.titleOfSelectedItem ?? "") ?? 115_200
        let framingIndex = max(0, serialFramingPopup.indexOfSelectedItem)
        let framing = SerialFraming.allCases[min(framingIndex, SerialFraming.allCases.count - 1)]
        service.configure(destination: destination, destinationPort: port,
                          feedbackPort: feedback, controlPort: control,
                          autoStart: autoStartToggle.state == .on,
                          analogPickup: pickupToggle.state == .on)
        service.configureSerial(enabled: serialToggle.state == .on, port: serialPort,
                                baud: baud, framing: framing,
                                mirrorFeedback: mirrorSerialToggle.state == .on)
        service.applySettings()
        dismiss()
    }

    @objc private func cancel() {
        dismiss()
    }

    @objc private func reconnect() {
        service.reconnectMIDI()
        inputsLabel.stringValue = midiSummary()
    }

    @objc private func rescanSerial() {
        populateSerialPorts()
        service.reconnectSerial()
        updateSerialHint()
    }

    private func populateSerialPorts() {
        serialPortPopup.removeAllItems()
        serialPortPopup.addItem(withTitle: "Auto-detect")
        let ports = SerialTransport.availablePorts()
        serialPortPopup.addItems(withTitles: ports)
        if !service.serialPort.isEmpty, let index = ports.firstIndex(of: service.serialPort) {
            serialPortPopup.selectItem(at: index + 1)
        } else {
            serialPortPopup.selectItem(at: 0)
        }
        updateSerialHint()
    }

    private func updateSerialHint() {
        if service.serialConnected {
            serialHint.stringValue = "Connected: \(service.serialPath ?? "?") · \(service.serialFrames) frames"
            serialHint.textColor = Palette.green
        } else if let error = service.serialError {
            serialHint.stringValue = error
            serialHint.textColor = Palette.amber
        } else {
            serialHint.stringValue = SerialTransport.availablePorts().isEmpty
                ? "No USB serial device found (ESP32-S3 not connected)"
                : "Ports: " + SerialTransport.availablePorts().joined(separator: "  ·  ")
            serialHint.textColor = Palette.muted
        }
    }

    @objc private func useAutoPilotPorts() {
        guard let ap = AutoPilotSettings.detect() else {
            fail("No AUTO/PILOT settings found at \(AutoPilotSettings.defaultPath)")
            return
        }
        if let host = ap.feedbackHost, !host.isEmpty { destinationField.stringValue = host }
        if let listen = ap.listenPort { portField.stringValue = String(listen) }
        if let feedback = ap.feedbackPort { feedbackField.stringValue = String(feedback) }
        updateAutoPilotLabel()
    }

    private func updateAutoPilotLabel() {
        guard let ap = AutoPilotSettings.detect() else {
            autoPilotLabel.stringValue = "AUTO/PILOT settings not found — enter its OSC ports manually."
            autoPilotLabel.textColor = Palette.amber
            useAutoPilotButton.isEnabled = false
            return
        }
        useAutoPilotButton.isEnabled = true
        let matches = ap.listenPort == Int(portField.stringValue)
            && ap.feedbackPort == Int(feedbackField.stringValue)
        autoPilotLabel.stringValue = ap.summary + (matches ? "  ·  match" : "  ·  uses different ports")
        autoPilotLabel.textColor = matches ? Palette.green : Palette.amber
    }

    private func midiSummary() -> String {
        let matched = service.midiInputs.filter { MIDITransport.isFLX4($0) }
        guard !service.midiInputs.isEmpty else { return "None detected" }
        if matched.isEmpty {
            return "No FLX4 · seen: " + service.midiInputs.joined(separator: "  ·  ")
        }
        return "FLX4 · " + matched.joined(separator: "  ·  ")
    }

    private func fail(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }

    private func dismiss() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }
}
