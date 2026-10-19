import AppKit

final class PillView: NSView {
    private let dot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.backgroundColor = Palette.elevated.cgColor
        layer?.borderColor = Palette.stroke.cgColor
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 23).isActive = true

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 7).isActive = true

        titleLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        titleLabel.textColor = Palette.muted
        valueLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        valueLabel.textColor = Palette.text

        let stack = NSStackView(views: [dot, titleLabel, valueLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5.5
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 9, bottom: 3, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(title: String, value: String, color: NSColor) {
        titleLabel.stringValue = title.uppercased()
        valueLabel.stringValue = value
        dot.layer?.backgroundColor = color.cgColor
    }
}
