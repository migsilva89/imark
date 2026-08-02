import AppKit

/// One window for the whole app, not one per document — these are preferences,
/// not properties of the file you have open.
///
/// A single pane with three headed groups rather than a toolbar of tabs: nine
/// options fit on one screen, and a tab holding two controls is more frame than
/// contents. Everything writes straight to `Settings`, which announces itself,
/// so every open document follows along without this window knowing they exist.
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PreferencesWindowController()

    private let appearance = NSSegmentedControl()
    private let lightPalette = NSPopUpButton()
    private let darkPalette = NSPopUpButton()
    private let textSize = NSSlider()
    private let textSizeLabel = NSTextField(labelWithString: "")
    private let width = NSPopUpButton()
    private let author = NSTextField()
    private var swatches: [Swatch] = []
    private let engine = NSPopUpButton()
    private let editor = NSPopUpButton()
    private let makeDefault = NSButton()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Imark Settings"
        super.init(window: window)
        window.delegate = self

        // One grid for all three groups, not one each: separate grids each pick
        // their own label column width, and three columns of labels that nearly
        // line up read worse than no alignment at all.
        let grid = NSGridView()
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false

        add(heading: "Appearance", to: grid, first: true)
        add(rows: appearanceRows(), to: grid)
        add(heading: "Comments", to: grid, first: false)
        add(rows: commentRows(), to: grid)
        add(heading: "General", to: grid, first: false)
        add(rows: generalRows(), to: grid)

        grid.column(at: 0).xPlacement = .trailing

        let host = NSView()
        host.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: host.topAnchor, constant: 18),
            grid.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -22),
        ])
        window.contentView = host
        // Sized to its contents rather than to a number picked by hand: the
        // rows grow with the longest editor name, and a fixed width would clip.
        window.setContentSize(host.fittingSize)
        window.center()

        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    static func show() {
        shared.showWindow(nil)
        shared.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The name is committed on the way out as well as on ⏎ — closing a window
    /// with something typed in it and finding it forgotten is its own small
    /// betrayal.
    func windowWillClose(_ notification: Notification) { commitAuthor() }

    // MARK: - Groups

    private func appearanceRows() -> [(String, NSView)] {
        appearance.segmentStyle = .rounded
        appearance.trackingMode = .selectOne
        appearance.segmentCount = Settings.Theme.allCases.count
        for (index, theme) in Settings.Theme.allCases.enumerated() {
            appearance.setLabel(theme.label, forSegment: index)
        }
        appearance.target = self
        appearance.action = #selector(appearanceChanged)

        fill(lightPalette, with: Settings.Palette.light, action: #selector(paletteChanged))
        fill(darkPalette, with: Settings.Palette.dark, action: #selector(paletteChanged))

        textSize.minValue = Settings.textScaleRange.lowerBound
        textSize.maxValue = Settings.textScaleRange.upperBound
        textSize.numberOfTickMarks = Int(Settings.textScaleRange.upperBound - Settings.textScaleRange.lowerBound) + 1
        textSize.allowsTickMarkValuesOnly = true
        textSize.target = self
        textSize.action = #selector(textSizeChanged)
        textSizeLabel.textColor = .secondaryLabelColor
        textSizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        let size = NSStackView(views: [textSize, textSizeLabel])
        size.spacing = 8
        textSize.widthAnchor.constraint(equalToConstant: 180).isActive = true

        width.removeAllItems()
        for value in Settings.Width.allCases { width.addItem(withTitle: value.label) }
        width.target = self
        width.action = #selector(widthChanged)

        return [
            ("Theme", appearance),
            ("Light", lightPalette),
            ("Dark", darkPalette),
            ("Text size", size),
            ("Column", width),
        ]
    }

    private func commentRows() -> [(String, NSView)] {
        author.placeholderString = NSFullUserName()
        author.target = self
        author.action = #selector(authorCommitted)
        author.widthAnchor.constraint(equalToConstant: 220).isActive = true

        swatches = NoteColour.allCases.map { Swatch($0, target: self, action: #selector(colourPicked(_:))) }
        let colours = NSStackView(views: swatches)
        colours.spacing = 6

        return [
            ("Sign notes as", author),
            ("Default colour", colours),
        ]
    }

    private func generalRows() -> [(String, NSView)] {
        engine.removeAllItems()
        for value in Settings.SearchEngine.allCases { engine.addItem(withTitle: value.label) }
        engine.target = self
        engine.action = #selector(engineChanged)

        editor.removeAllItems()
        let editors = Editors.installed
        if editors.isEmpty {
            editor.addItem(withTitle: "No editors found")
            editor.isEnabled = false
        } else {
            for found in editors {
                let item = NSMenuItem(title: found.name, action: nil, keyEquivalent: "")
                item.representedObject = found.url
                editor.menu?.addItem(item)
            }
        }
        editor.target = self
        editor.action = #selector(editorChanged)

        makeDefault.title = "Make Imark the Default"
        makeDefault.bezelStyle = .rounded
        makeDefault.target = self
        makeDefault.action = #selector(makeDefaultPressed)

        return [
            ("Search with", engine),
            ("Open in", editor),
            ("Markdown files", makeDefault),
        ]
    }

    // MARK: - Building blocks

    /// A heading spans both columns, so it starts at the left edge instead of
    /// being pushed into the control column with the rest.
    private func add(heading: String, to grid: NSGridView, first: Bool) {
        let label = NSTextField(labelWithString: heading)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor

        // Two cells, then merged: adding one cell to an empty grid makes a
        // one-column grid, and the first heading ended up in the label column
        // while the later ones spanned both.
        let row = grid.addRow(with: [label, NSGridCell.emptyContentView])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        // The merged cell inherits the label column's trailing placement, which
        // pushes a heading to the far right of the window.
        row.cell(at: 0).xPlacement = .leading
        row.topPadding = first ? 0 : 14
        row.bottomPadding = 2
    }

    private func add(rows: [(String, NSView)], to grid: NSGridView) {
        for (label, control) in rows {
            let caption = NSTextField(labelWithString: label)
            caption.alignment = .right
            let row = grid.addRow(with: [caption, control])
            // Baselines line a label up with the text inside a control, which is
            // right for popups and fields. A slider and a row of circles have no
            // text to sit on, so those rows centre instead.
            if control is NSPopUpButton || control is NSTextField {
                row.rowAlignment = .firstBaseline
            } else {
                row.rowAlignment = .none
                row.yPlacement = .center
            }
        }
    }

    private func fill(_ button: NSPopUpButton, with palettes: [Settings.Palette], action: Selector) {
        button.removeAllItems()
        for palette in palettes {
            let item = NSMenuItem(title: palette.label, action: nil, keyEquivalent: "")
            item.representedObject = palette.rawValue
            button.menu?.addItem(item)
        }
        button.target = self
        button.action = action
    }

    // MARK: - Reading the settings back

    private func refresh() {
        appearance.selectedSegment = Settings.Theme.allCases.firstIndex(of: Settings.theme) ?? 0
        select(lightPalette, Settings.lightPalette.rawValue)
        select(darkPalette, Settings.darkPalette.rawValue)

        textSize.doubleValue = Settings.textScale
        textSizeLabel.stringValue = "\(Int(Settings.textScale)) pt"
        width.selectItem(at: Settings.Width.allCases.firstIndex(of: Settings.width) ?? 1)

        // Left empty when it is only the account name, so the placeholder can
        // say where the name is coming from instead of it looking chosen.
        let stored = UserDefaults.standard.string(forKey: "authorName") ?? ""
        author.stringValue = stored
        for swatch in swatches { swatch.isPicked = swatch.colour == Settings.noteColour }

        engine.selectItem(at: Settings.SearchEngine.allCases.firstIndex(of: Settings.searchEngine) ?? 0)
        if let preferred = Editors.preferred(from: Editors.installed),
           let index = editor.itemArray.firstIndex(where: { $0.representedObject as? URL == preferred }) {
            editor.selectItem(at: index)
        }
        makeDefault.isEnabled = !MarkdownType.imarkIsDefault
        makeDefault.title = MarkdownType.imarkIsDefault ? "Imark is the Default" : "Make Imark the Default"
    }

    private func select(_ button: NSPopUpButton, _ raw: String) {
        guard let index = button.itemArray.firstIndex(where: { $0.representedObject as? String == raw })
        else { return }
        button.selectItem(at: index)
    }

    // MARK: - Actions

    @objc private func appearanceChanged() {
        let all = Settings.Theme.allCases
        guard all.indices.contains(appearance.selectedSegment) else { return }
        Settings.theme = all[appearance.selectedSegment]
        Settings.applyThemeToApp()
    }

    @objc private func paletteChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let palette = Settings.Palette(rawValue: raw) else { return }
        if palette.isDark { Settings.darkPalette = palette } else { Settings.lightPalette = palette }
    }

    @objc private func textSizeChanged() {
        Settings.textScale = textSize.doubleValue.rounded()
        textSizeLabel.stringValue = "\(Int(Settings.textScale)) pt"
    }

    @objc private func widthChanged() {
        guard Settings.Width.allCases.indices.contains(width.indexOfSelectedItem) else { return }
        Settings.width = Settings.Width.allCases[width.indexOfSelectedItem]
    }

    @objc private func authorCommitted() { commitAuthor() }

    private func commitAuthor() {
        guard Settings.authorName != author.stringValue else { return }
        Settings.authorName = author.stringValue
    }

    @objc private func colourPicked(_ sender: Swatch) {
        Settings.noteColour = sender.colour
        for swatch in swatches { swatch.isPicked = swatch === sender }
    }

    @objc private func engineChanged() {
        guard Settings.SearchEngine.allCases.indices.contains(engine.indexOfSelectedItem) else { return }
        Settings.searchEngine = Settings.SearchEngine.allCases[engine.indexOfSelectedItem]
    }

    @objc private func editorChanged() {
        Settings.preferredEditor = editor.selectedItem?.representedObject as? URL
    }

    @objc private func makeDefaultPressed() {
        MarkdownType.makeImarkDefault { [weak self] _ in self?.refresh() }
    }
}
