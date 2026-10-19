import AppKit
import BridgeCore

/// Mapping editor: capture a hardware control with Learn, choose an AUTO/PILOT
/// (or hub) route, and save it. The stock FLX4 map remains the fallback; saved
/// mappings override it by control identity.
final class MappingWindowController: NSWindowController, NSTableViewDataSource,
                                      NSTableViewDelegate, NSComboBoxDelegate, NSWindowDelegate {
    private static var active: MappingWindowController?

    static func present() {
        if active == nil {
            active = MappingWindowController()
        }
        active?.showWindow(nil)
        active?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        active?.refreshAll()
    }

    private let service = BridgeService.shared
    private let catalog = AutoPilotCatalog.all()
    private var mappings: [ControlMapping] = []
    private var endpoints: [OSCEndpoint] = []
    private var learned: LearnedControl?
    private var editingID: UUID?
    private var destinationIDs: [UUID?] = [nil]
    private var timer: Timer?
    /// Save/validation messages must not be replaced by the 0.5 s learn-status
    /// refresh before the user can read them.
    private var statusPinnedUntil = Date.distantPast

    private let tabView = NSTabView()

    // Mappings tab
    private let learnButton = NSButton(title: "Learn", target: nil, action: nil)
    private let learnFilter = NSPopUpButton()
    private let learnStatus = NSTextField(labelWithString: "Press Learn, then move a control.")
    private let sourceLabel = NSTextField(labelWithString: "No control captured")
    private let routeCombo = NSComboBox()
    private let routeDetail = NSTextField(labelWithString: "Choose a route or type a custom OSC address.")
    private let modePopup = NSPopUpButton()
    private let deckPopup = NSPopUpButton()
    private let minField = NSTextField(string: "0")
    private let maxField = NSTextField(string: "1")
    private let nameField = NSTextField(string: "")
    private let destinationPopup = NSPopUpButton()
    private let saveButton = NSButton(title: "Save mapping", target: nil, action: nil)
    private let newButton = NSButton(title: "New", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let enableButton = NSButton(title: "Disable", target: nil, action: nil)
    private let mappingTable = NSTableView()
    private var mappingScroll = NSScrollView()

    // Destinations tab
    private let endpointLabelField = NSTextField(string: "")
    private let endpointHostField = NSTextField(string: "127.0.0.1")
    private let endpointPortField = NSTextField(string: "7000")
    private let endpointPrefixField = NSTextField(string: "")
    private let endpointEnabled = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let endpointTable = NSTableView()
    private let endpointScroll = NSScrollView()
    private let endpointSaveButton = NSButton(title: "Save destination", target: nil, action: nil)
    private let endpointNewButton = NSButton(title: "New", target: nil, action: nil)
    private let endpointDeleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private var editingEndpointID: UUID?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Cuewire · OSC Mapping"
        window.minSize = NSSize(width: 820, height: 640)
        window.backgroundColor = Palette.background
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        refreshAll()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refreshLive() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { timer?.invalidate() }

    private func build() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Palette.background.cgColor
        tabView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            tabView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])

        let mappingsTab = NSTabViewItem(identifier: "mappings")
        mappingsTab.label = "Mappings"
        mappingsTab.view = buildMappingsTab()
        tabView.addTabViewItem(mappingsTab)

        let destinationsTab = NSTabViewItem(identifier: "destinations")
        destinationsTab.label = "Destinations"
        destinationsTab.view = buildDestinationsTab()
        tabView.addTabViewItem(destinationsTab)

        window?.contentView = root
    }

    private func buildMappingsTab() -> NSView {
        let root = NSView()

        let title = label("OSC MAPPING", size: 10, weight: .bold, color: Palette.muted)
        let hint = label("Learn captures the next MIDI or serial control. Saved mappings override the stock FLX4 map and can drive any destination.",
                         size: 11, weight: .regular, color: Palette.muted)

        learnButton.target = self
        learnButton.action = #selector(toggleLearn)
        learnButton.bezelStyle = .rounded
        learnFilter.addItems(withTitles: LearnFilter.allCases.map { $0.label })
        learnFilter.selectItem(at: 0)
        learnStatus.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        learnStatus.textColor = Palette.teal
        learnStatus.lineBreakMode = .byTruncatingTail

        let learnRow = NSStackView(views: [learnButton, learnFilter, learnStatus])
        learnRow.orientation = .horizontal
        learnRow.alignment = .centerY
        learnRow.spacing = 8

        sourceLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        sourceLabel.textColor = Palette.text
        sourceLabel.lineBreakMode = .byTruncatingTail

        routeCombo.isEditable = true
        routeCombo.completes = true
        routeCombo.numberOfVisibleItems = 18
        routeCombo.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        routeCombo.addItems(withObjectValues: catalog.map { $0.address })
        routeCombo.delegate = self
        routeCombo.target = self
        routeCombo.action = #selector(routeChanged)
        routeCombo.translatesAutoresizingMaskIntoConstraints = false
        routeCombo.widthAnchor.constraint(greaterThanOrEqualToConstant: 540).isActive = true

        routeDetail.font = .systemFont(ofSize: 10, weight: .regular)
        routeDetail.textColor = Palette.muted
        routeDetail.lineBreakMode = .byTruncatingTail

        let routeStack = NSStackView(views: [routeCombo, routeDetail])
        routeStack.orientation = .vertical
        routeStack.alignment = .leading
        routeStack.spacing = 2

        for (index, mode) in MappingMode.allCases.enumerated() {
            modePopup.addItem(withTitle: mode.label)
            modePopup.item(at: index)?.representedObject = mode.rawValue
        }
        modePopup.selectItem(at: 0)
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        for deck in 1...4 {
            deckPopup.addItem(withTitle: "Deck \(deck)")
        }
        minField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        maxField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        minField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        maxField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        nameField.font = .systemFont(ofSize: 11, weight: .regular)
        nameField.placeholderString = "Optional label"

        let modeRow = NSStackView(views: [
            modePopup, label("Deck", size: 10, weight: .regular, color: Palette.muted), deckPopup,
            label("Min", size: 10, weight: .regular, color: Palette.muted), minField,
            label("Max", size: 10, weight: .regular, color: Palette.muted), maxField,
            label("Send to", size: 10, weight: .regular, color: Palette.muted), destinationPopup,
        ])
        modeRow.orientation = .horizontal
        modeRow.alignment = .centerY
        modeRow.spacing = 6

        saveButton.target = self
        saveButton.action = #selector(saveMapping)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        newButton.target = self
        newButton.action = #selector(newMapping)
        newButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteMapping)
        deleteButton.bezelStyle = .rounded
        enableButton.target = self
        enableButton.action = #selector(toggleMappingEnabled)
        enableButton.bezelStyle = .rounded
        let buttonRow = NSStackView(views: [saveButton, newButton, enableButton, deleteButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        configureMappingTable()
        mappingScroll.documentView = mappingTable
        mappingScroll.hasVerticalScroller = true
        mappingScroll.autohidesScrollers = true
        mappingScroll.drawsBackground = true
        mappingScroll.backgroundColor = Palette.panel
        mappingScroll.wantsLayer = true
        mappingScroll.layer?.cornerRadius = 8
        mappingScroll.layer?.borderColor = Palette.stroke.cgColor
        mappingScroll.layer?.borderWidth = 1
        mappingScroll.translatesAutoresizingMaskIntoConstraints = false
        mappingScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        let grid = NSGridView(views: [
            [label("Control", size: 10, weight: .regular, color: Palette.muted), sourceLabel],
            [label("Route", size: 10, weight: .regular, color: Palette.muted), routeStack],
            [label("Mode / target", size: 10, weight: .regular, color: Palette.muted), modeRow],
            [label("Name", size: 10, weight: .regular, color: Palette.muted), nameField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 84
        grid.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, hint, learnRow, grid, buttonRow, mappingScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            mappingScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return root
    }

    private func configureMappingTable() {
        mappingTable.delegate = self
        mappingTable.dataSource = self
        mappingTable.usesAlternatingRowBackgroundColors = true
        mappingTable.rowHeight = 22
        mappingTable.style = .inset
        for (identifier, title, width) in [
            ("on", "On", CGFloat(42)),
            ("name", "Name", CGFloat(150)),
            ("control", "Control", CGFloat(170)),
            ("target", "OSC target", CGFloat(360)),
            ("mode", "Mode", CGFloat(150)),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            mappingTable.addTableColumn(column)
        }
    }

    private func buildDestinationsTab() -> NSView {
        let root = NSView()
        let title = label("OSC DESTINATIONS", size: 10, weight: .bold, color: Palette.muted)
        let hint = label("AUTO/PILOT is the primary destination. Add other gear with the OSC namespace it owns (for example /Resolume); the longest matching prefix wins, and unmatched serial OSC goes to AUTO/PILOT.",
                         size: 11, weight: .regular, color: Palette.muted)
        hint.maximumNumberOfLines = 2

        for field in [endpointLabelField, endpointHostField, endpointPortField, endpointPrefixField] {
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        }
        endpointLabelField.placeholderString = "Resolume"
        endpointHostField.placeholderString = "127.0.0.1"
        endpointPortField.placeholderString = "7000"
        endpointPrefixField.placeholderString = "/Resolume"
        endpointEnabled.state = .on

        let endpointGrid = NSGridView(views: [
            [label("Label", size: 10, weight: .regular, color: Palette.muted), endpointLabelField,
             label("Host", size: 10, weight: .regular, color: Palette.muted), endpointHostField],
            [label("Port", size: 10, weight: .regular, color: Palette.muted), endpointPortField,
             label("OSC prefix", size: 10, weight: .regular, color: Palette.muted), endpointPrefixField],
            [label("State", size: 10, weight: .regular, color: Palette.muted), endpointEnabled],
        ])
        endpointGrid.rowSpacing = 8
        endpointGrid.columnSpacing = 10
        endpointGrid.column(at: 0).xPlacement = .trailing
        endpointGrid.column(at: 0).width = 84
        endpointGrid.column(at: 2).xPlacement = .trailing
        endpointGrid.column(at: 2).width = 52
        endpointGrid.translatesAutoresizingMaskIntoConstraints = false

        endpointSaveButton.target = self
        endpointSaveButton.action = #selector(saveEndpoint)
        endpointSaveButton.bezelStyle = .rounded
        endpointNewButton.target = self
        endpointNewButton.action = #selector(newEndpoint)
        endpointNewButton.bezelStyle = .rounded
        endpointDeleteButton.target = self
        endpointDeleteButton.action = #selector(deleteEndpoint)
        endpointDeleteButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [endpointSaveButton, endpointNewButton, endpointDeleteButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        configureEndpointTable()
        endpointScroll.documentView = endpointTable
        endpointScroll.hasVerticalScroller = true
        endpointScroll.drawsBackground = true
        endpointScroll.backgroundColor = Palette.panel
        endpointScroll.wantsLayer = true
        endpointScroll.layer?.cornerRadius = 8
        endpointScroll.layer?.borderColor = Palette.stroke.cgColor
        endpointScroll.layer?.borderWidth = 1
        endpointScroll.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, hint, endpointGrid, buttons, endpointScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            endpointGrid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            endpointScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            endpointScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        return root
    }

    private func configureEndpointTable() {
        endpointTable.delegate = self
        endpointTable.dataSource = self
        endpointTable.usesAlternatingRowBackgroundColors = true
        endpointTable.rowHeight = 22
        endpointTable.style = .inset
        for (identifier, title, width) in [
            ("on", "On", CGFloat(42)),
            ("label", "Label", CGFloat(150)),
            ("host", "Host", CGFloat(160)),
            ("port", "Port", CGFloat(70)),
            ("prefix", "OSC prefix", CGFloat(220)),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            endpointTable.addTableColumn(column)
        }
    }

    // MARK: - Refresh

    func refreshAll() {
        mappings = service.mappings
        endpoints = service.endpoints
        refreshDestinationPopup()
        refreshMappingsTable()
        refreshEndpointsTable()
        refreshLearnStatus()
    }

    private func refreshLive() {
        if service.mappings != mappings {
            mappings = service.mappings
            refreshMappingsTable()
        }
        if service.endpoints != endpoints {
            endpoints = service.endpoints
            refreshDestinationPopup()
            refreshEndpointsTable()
        }
        refreshLearnStatus()
    }

    private func refreshMappingsTable() {
        mappingTable.reloadData()
        deleteButton.isEnabled = mappingTable.selectedRow >= 0
        enableButton.isEnabled = mappingTable.selectedRow >= 0
        if mappingTable.selectedRow >= 0, mappingTable.selectedRow < mappings.count {
            enableButton.title = mappings[mappingTable.selectedRow].enabled ? "Disable" : "Enable"
        }
    }

    private func refreshEndpointsTable() {
        endpointTable.reloadData()
        endpointDeleteButton.isEnabled = endpointTable.selectedRow >= 0
    }

    private func refreshDestinationPopup() {
        let selected = destinationPopup.indexOfSelectedItem
        destinationPopup.removeAllItems()
        destinationIDs = [nil] + endpoints.map { $0.id }
        destinationPopup.addItem(withTitle: "AUTO/PILOT (primary)")
        for endpoint in endpoints {
            destinationPopup.addItem(withTitle: "\(endpoint.label) · \(endpoint.host):\(endpoint.port)")
        }
        if selected >= 0 && selected < destinationPopup.numberOfItems {
            destinationPopup.selectItem(at: selected)
        } else {
            destinationPopup.selectItem(at: 0)
        }
    }

    private func refreshLearnStatus() {
        let showStatus = Date() >= statusPinnedUntil
        switch service.learnState {
        case .off:
            learnButton.title = learned == nil ? "Learn" : "Re-learn"
            if learned == nil && showStatus {
                learnStatus.stringValue = "Press Learn, then move a control."
                learnStatus.textColor = Palette.muted
            }
        case .waiting:
            learnButton.title = "Cancel learn"
            if showStatus {
                learnStatus.stringValue = "Listening… move a MIDI or serial control."
                learnStatus.textColor = Palette.amber
            }
        case .learned(let control):
            learnButton.title = "Learn again"
            learned = control
            sourceLabel.stringValue = control.label
            if showStatus {
                learnStatus.stringValue = "Captured \(control.label) — choose a route and save."
                learnStatus.textColor = Palette.teal
            }
        }
    }

    // MARK: - Learn and save

    @objc private func toggleLearn() {
        if service.learnState.isWaiting {
            service.cancelLearn()
            return
        }
        let index = max(0, learnFilter.indexOfSelectedItem)
        let filter = LearnFilter.allCases[min(index, LearnFilter.allCases.count - 1)]
        learned = nil
        statusPinnedUntil = .distantPast
        sourceLabel.stringValue = "Listening…"
        service.onLearned = { [weak self] control in
            guard let self else { return }
            self.learned = control
            self.sourceLabel.stringValue = control.label
            self.learnStatus.stringValue = "Captured \(control.label) — choose a route and save."
            self.learnStatus.textColor = Palette.teal
        }
        service.beginLearn(filter)
    }

    @objc private func modeChanged() {
        let index = max(0, modePopup.indexOfSelectedItem)
        let mode = MappingMode.allCases[min(index, MappingMode.allCases.count - 1)]
        if mode == .bipolar {
            minField.stringValue = "-1"
            maxField.stringValue = "1"
        } else if mode == .absolute {
            minField.stringValue = "0"
            maxField.stringValue = "1"
        }
    }

    @objc private func routeChanged() {
        applyRouteDefaults()
    }

    /// Route kinds imply the control shape: a continuous parameter wants
    /// Absolute and a bipolar one wants Bipolar. Apply that whenever a route is
    /// picked or the address field is left, so a fader is never saved as a
    /// press (which would send one value and then nothing as it moves).
    private func applyRouteDefaults() {
        let address = routeCombo.stringValue.trimmingCharacters(in: .whitespaces)
        let route = AutoPilotCatalog.route(for: address)
        routeDetail.stringValue = "\(route.label) · \(route.group) · \(route.kind.label)"
        if let index = MappingMode.allCases.firstIndex(of: route.kind.suggestedMode) {
            modePopup.selectItem(at: index)
        }
        switch route.kind {
        case .bipolar:
            minField.stringValue = "-1"
            maxField.stringValue = "1"
        case .continuous:
            minField.stringValue = "0"
            maxField.stringValue = "1"
        default:
            break
        }
    }

    // Picking an item from the popup and typing an address are separate paths;
    // both must refresh the mode, or the leftover Trigger stays selected.
    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSComboBox) === routeCombo else { return }
        applyRouteDefaults()
    }

    func controlTextDidChange(_ notification: Notification) {
        // Preview the matched route while typing, but do not touch the mode on
        // every keystroke: partial addresses infer Trigger and would fight the
        // mode the user is choosing.
        guard (notification.object as? NSTextField) === routeCombo else { return }
        let address = routeCombo.stringValue.trimmingCharacters(in: .whitespaces)
        let route = AutoPilotCatalog.route(for: address)
        routeDetail.stringValue = "\(route.label) · \(route.group) · \(route.kind.label)"
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextField) === routeCombo else { return }
        applyRouteDefaults()
    }

    @objc private func saveMapping() {
        // Keep whatever this save reports on screen long enough to read; the
        // learn-status timer otherwise restores its own text within 0.5 s.
        statusPinnedUntil = Date().addingTimeInterval(4)
        let address = routeCombo.stringValue.trimmingCharacters(in: .whitespaces)
        guard address.hasPrefix("/"), address.count > 1 else {
            learnStatus.stringValue = "Enter an OSC address such as /AutoPilot/Deck/{deck}/PlayPause."
            learnStatus.textColor = Palette.red
            return
        }
        let source: (MappingSourceKind, Int?, Int?, String?)
        if let learned {
            source = (learned.source, learned.channel, learned.number, learned.control)
        } else if let id = editingID, let mapping = mappings.first(where: { $0.id == id }) {
            source = (mapping.source, mapping.channel, mapping.number, mapping.control)
        } else {
            learnStatus.stringValue = "Press Learn and move a control first."
            learnStatus.textColor = Palette.red
            return
        }
        let modeIndex = max(0, modePopup.indexOfSelectedItem)
        let selectedMode = MappingMode.allCases[min(modeIndex, MappingMode.allCases.count - 1)]
        let route = AutoPilotCatalog.route(for: address)
        let mode = MappingModeResolver.resolvedMode(for: address, selected: selectedMode)
        var modeNote = ""
        if mode != selectedMode {
            // A pasted or fast-entered address can still arrive with Trigger
            // selected. Saving it as a press would move the parameter once,
            // then fall silent, so apply the route's own mode and say so.
            modePopup.selectItem(at: MappingMode.allCases.firstIndex(of: mode) ?? 0)
            minField.stringValue = mode == .bipolar ? "-1" : "0"
            maxField.stringValue = "1"
            modeNote = " \(route.label) takes \(route.kind.label), so its mode is \(mode.label)."
        }
        if mode == .passthrough && (source.0 == .midiNote || source.0 == .midiCC) {
            learnStatus.stringValue = "Passthrough is for OSC input sources; use Trigger/Momentary/Toggle for MIDI."
            learnStatus.textColor = Palette.red
            return
        }
        let deck = max(1, deckPopup.indexOfSelectedItem + 1)
        let destinationIndex = destinationPopup.indexOfSelectedItem
        let endpointID = destinationIndex >= 0 && destinationIndex < destinationIDs.count ? destinationIDs[destinationIndex] : nil
        let minimum = Double(minField.stringValue) ?? 0
        let maximum = Double(maxField.stringValue) ?? 1
        let existing = editingID.flatMap { id in mappings.first { $0.id == id } }
        var mapping = existing ?? ControlMapping(source: source.0, address: address, mode: mode)
        mapping.source = source.0
        mapping.channel = source.1
        mapping.number = source.2
        mapping.control = source.3
        mapping.address = address
        mapping.mode = mode
        mapping.deck = deck
        mapping.minimum = minimum
        mapping.maximum = maximum
        mapping.endpointID = endpointID
        mapping.name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        mapping.enabled = existing?.enabled ?? true
        guard mapping.isValid else {
            learnStatus.stringValue = "That control or route is incomplete."
            learnStatus.textColor = Palette.red
            return
        }
        if existing == nil {
            service.addMapping(mapping)
        } else {
            service.updateMapping(mapping)
        }
        service.cancelLearn()
        learned = nil
        editingID = mapping.id
        mappings = service.mappings
        refreshMappingsTable()
        learnStatus.stringValue = "Saved \(mapping.displayName).\(modeNote)"
        learnStatus.textColor = Palette.teal
    }

    @objc private func newMapping() {
        service.cancelLearn()
        statusPinnedUntil = .distantPast
        editingID = nil
        learned = nil
        sourceLabel.stringValue = "No control captured"
        nameField.stringValue = ""
        minField.stringValue = "0"
        maxField.stringValue = "1"
        modePopup.selectItem(at: 0)
        if mappingTable.selectedRow >= 0 { mappingTable.deselectRow(mappingTable.selectedRow) }
        deleteButton.isEnabled = false
        enableButton.isEnabled = false
        learnStatus.stringValue = "Press Learn, then move a control."
        learnStatus.textColor = Palette.muted
    }

    @objc private func deleteMapping() {
        let row = mappingTable.selectedRow
        guard row >= 0, row < mappings.count else { return }
        let mapping = mappings[row]
        service.removeMapping(id: mapping.id)
        mappings = service.mappings
        refreshMappingsTable()
        if editingID == mapping.id { newMapping() }
    }

    @objc private func toggleMappingEnabled() {
        let row = mappingTable.selectedRow
        guard row >= 0, row < mappings.count else { return }
        let mapping = mappings[row]
        service.setMappingEnabled(!mapping.enabled, id: mapping.id)
        mappings = service.mappings
        refreshMappingsTable()
    }

    // MARK: - Destinations

    @objc private func saveEndpoint() {
        let label = endpointLabelField.stringValue.trimmingCharacters(in: .whitespaces)
        let host = endpointHostField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, !host.isEmpty, let port = Int(endpointPortField.stringValue),
              (1...65_535).contains(port) else {
            learnStatus.stringValue = "Destination needs a label, IPv4 host and port 1…65535."
            learnStatus.textColor = Palette.red
            return
        }
        let prefix = endpointPrefixField.stringValue.trimmingCharacters(in: .whitespaces)
        var endpoint = editingEndpointID.flatMap { id in endpoints.first { $0.id == id } }
            ?? OSCEndpoint(label: label)
        endpoint.label = label
        endpoint.host = host
        endpoint.port = port
        endpoint.prefix = prefix.isEmpty ? "" : (prefix.hasPrefix("/") ? prefix : "/" + prefix)
        endpoint.enabled = endpointEnabled.state == .on
        guard endpoint.isValid else {
            learnStatus.stringValue = "Destination host must be an IPv4 address."
            learnStatus.textColor = Palette.red
            return
        }
        if editingEndpointID == nil {
            service.addEndpoint(endpoint)
        } else {
            service.updateEndpoint(endpoint)
        }
        editingEndpointID = endpoint.id
        endpoints = service.endpoints
        refreshEndpointsTable()
        refreshDestinationPopup()
    }

    @objc private func newEndpoint() {
        editingEndpointID = nil
        endpointLabelField.stringValue = ""
        endpointHostField.stringValue = "127.0.0.1"
        endpointPortField.stringValue = "7000"
        endpointPrefixField.stringValue = ""
        endpointEnabled.state = .on
        endpointDeleteButton.isEnabled = false
    }

    @objc private func deleteEndpoint() {
        let row = endpointTable.selectedRow
        guard row >= 0, row < endpoints.count else { return }
        service.removeEndpoint(id: endpoints[row].id)
        endpoints = service.endpoints
        refreshEndpointsTable()
        refreshDestinationPopup()
    }

    // MARK: - Table data

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === mappingTable ? mappings.count : endpoints.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let identifier = tableColumn.identifier.rawValue
        if tableView === mappingTable {
            guard row < mappings.count else { return nil }
            let mapping = mappings[row]
            let text: String
            let color: NSColor
            switch identifier {
            case "on": text = mapping.enabled ? "ON" : "off"; color = mapping.enabled ? Palette.green : Palette.muted
            case "name": text = mapping.displayName; color = Palette.text
            case "control": text = mapping.sourceLabel; color = Palette.muted
            case "target": text = mapping.targetLabel; color = Palette.text
            case "mode": text = mapping.mode.label; color = Palette.muted
            default: text = ""; color = Palette.text
            }
            return cell(text, color: color, mono: identifier != "name")
        } else {
            guard row < endpoints.count else { return nil }
            let endpoint = endpoints[row]
            let text: String
            let color: NSColor
            switch identifier {
            case "on": text = endpoint.enabled ? "ON" : "off"; color = endpoint.enabled ? Palette.green : Palette.muted
            case "label": text = endpoint.label; color = Palette.text
            case "host": text = endpoint.host; color = Palette.text
            case "port": text = String(endpoint.port); color = Palette.muted
            case "prefix": text = endpoint.prefix; color = Palette.muted
            default: text = ""; color = Palette.text
            }
            return cell(text, color: color, mono: true)
        }
    }

    private func cell(_ text: String, color: NSColor, mono: Bool) -> NSView {
        let field = NSTextField(labelWithString: text)
        field.font = mono ? .monospacedSystemFont(ofSize: 10, weight: .regular)
                          : .systemFont(ofSize: 11, weight: .regular)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === mappingTable {
            let row = mappingTable.selectedRow
            guard row >= 0, row < mappings.count else { return }
            loadMapping(mappings[row])
        } else {
            let row = endpointTable.selectedRow
            guard row >= 0, row < endpoints.count else { return }
            loadEndpoint(endpoints[row])
        }
    }

    private func loadMapping(_ mapping: ControlMapping) {
        service.cancelLearn()
        editingID = mapping.id
        learned = nil
        sourceLabel.stringValue = mapping.sourceLabel
        routeCombo.stringValue = mapping.address
        nameField.stringValue = mapping.name
        modePopup.selectItem(at: MappingMode.allCases.firstIndex(of: mapping.mode) ?? 0)
        deckPopup.selectItem(at: min(3, max(0, mapping.deck - 1)))
        minField.stringValue = format(mapping.minimum)
        maxField.stringValue = format(mapping.maximum)
        if let index = destinationIDs.firstIndex(where: { $0 == mapping.endpointID }) {
            destinationPopup.selectItem(at: index)
        } else {
            destinationPopup.selectItem(at: 0)
        }
        routeChanged()
        enableButton.title = mapping.enabled ? "Disable" : "Enable"
        enableButton.isEnabled = true
        deleteButton.isEnabled = true
    }

    private func loadEndpoint(_ endpoint: OSCEndpoint) {
        editingEndpointID = endpoint.id
        endpointLabelField.stringValue = endpoint.label
        endpointHostField.stringValue = endpoint.host
        endpointPortField.stringValue = String(endpoint.port)
        endpointPrefixField.stringValue = endpoint.prefix
        endpointEnabled.state = endpoint.enabled ? .on : .off
        endpointDeleteButton.isEnabled = true
    }

    private func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.3f", value)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        service.cancelLearn()
        service.onLearned = nil
        MappingWindowController.active = nil
    }
}
