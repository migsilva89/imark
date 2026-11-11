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
    private let palette = NSPopUpButton()
    private let textSize = NSSlider()
    private let textSizeLabel = NSTextField(labelWithString: "")
    private let width = NSPopUpButton()
    private let author = NSTextField()
    private let commentingControls = NSButton()
    private var swatches: [Swatch] = []
    private let engine = NSPopUpButton()
    private let editorStyle = NSPopUpButton()
    private let editor = NSPopUpButton()
    private let makeDefault = NSButton()
    /// Shown instead of the button once there is nothing left to press. A
    /// greyed-out button that states a fact reads as broken; a tick reads as
    /// done.
    private let isDefault = NSStackView()
    private let menuBar = NSButton()
    private let updates = NSButton()
    private let shortcuts = NSButton()

    private init() {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("Imark Settings", comment: "")
        super.init(window: window)
        window.delegate = self

        // One grid for all three groups, not one each: separate grids each pick
        // their own label column width, and three columns of labels that nearly
        // line up read worse than no alignment at all.
        let grid = NSGridView()
        grid.rowSpacing = 14
        grid.columnSpacing = 14
        grid.translatesAutoresizingMaskIntoConstraints = false

        add(heading: NSLocalizedString("Appearance", comment: ""), to: grid, first: true)
        add(rows: appearanceRows(), to: grid)
        add(heading: NSLocalizedString("Comments", comment: ""), to: grid, first: false)
        add(rows: commentRows(), to: grid)
        add(heading: NSLocalizedString("General", comment: ""), to: grid, first: false)
        add(rows: generalRows(), to: grid)

        grid.column(at: 0).xPlacement = .trailing

        let host = NSView()
        host.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 30),
            grid.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -30),
            grid.topAnchor.constraint(equalTo: host.topAnchor, constant: 24),
            grid.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -30),
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

        palette.removeAllItems()
        for value in Settings.Palette.allCases { palette.addItem(withTitle: value.label) }
        palette.target = self
        palette.action = #selector(paletteChanged)

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
            // Not "Appearance" again: the group above it already says that, and
            // a row that repeats its own heading tells you nothing.
            (NSLocalizedString("Mode", comment: ""), appearance),
            (NSLocalizedString("Theme", comment: ""), palette),
            (NSLocalizedString("Text size", comment: ""), size),
            (NSLocalizedString("Column", comment: ""), width),
        ]
    }

    private func commentRows() -> [(String, NSView)] {
        commentingControls.title = NSLocalizedString("Show controls for adding comments", comment: "")
        commentingControls.setButtonType(.switch)
        commentingControls.target = self
        commentingControls.action = #selector(commentingControlsChanged)

        author.placeholderString = NSFullUserName()
        author.target = self
        author.action = #selector(authorCommitted)
        author.widthAnchor.constraint(equalToConstant: 220).isActive = true

        swatches = NoteColour.allCases.map { Swatch($0, target: self, action: #selector(colourPicked(_:))) }
        let colours = NSStackView(views: swatches)
        colours.spacing = 6

        return [
            (NSLocalizedString("Commenting", comment: ""), commentingControls),
            (NSLocalizedString("Sign notes as", comment: ""), author),
            (NSLocalizedString("Default colour", comment: ""), colours),
        ]
    }

    private func generalRows() -> [(String, NSView)] {
        engine.removeAllItems()
        for value in Settings.SearchEngine.allCases { engine.addItem(withTitle: value.label) }
        engine.target = self
        engine.action = #selector(engineChanged)

        editorStyle.removeAllItems()
        for value in Settings.EditorStyle.allCases { editorStyle.addItem(withTitle: value.label) }
        editorStyle.target = self
        editorStyle.action = #selector(editorStyleChanged)
        // Said where it is chosen, because the menu's ⇧⌘E only changes the
        // window you are in, and only until editing ends.
        editorStyle.toolTip = NSLocalizedString("Which editor Editing Mode opens in. ⇧⌘E switches while editing.", comment: "")

        editor.removeAllItems()
        let editors = Editors.installed
        if editors.isEmpty {
            editor.addItem(withTitle: NSLocalizedString("No editors found", comment: ""))
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

        makeDefault.title = NSLocalizedString("Make Imark the Default", comment: "")
        makeDefault.bezelStyle = .rounded
        makeDefault.target = self
        makeDefault.action = #selector(makeDefaultPressed)

        let tick = NSImageView(image: NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: nil
        ) ?? NSImage())
        tick.contentTintColor = .systemGreen
        let done = NSTextField(labelWithString: NSLocalizedString("Imark opens them", comment: ""))
        done.textColor = .secondaryLabelColor
        isDefault.setViews([tick, done], in: .leading)
        isDefault.spacing = 6

        let markdown = NSStackView(views: [makeDefault, isDefault])
        markdown.spacing = 0

        menuBar.title = NSLocalizedString("Show icon in the menu bar", comment: "")
        menuBar.setButtonType(.switch)
        menuBar.target = self
        menuBar.action = #selector(menuBarChanged)

        updates.title = NSLocalizedString("Check for updates automatically", comment: "")
        updates.setButtonType(.switch)
        updates.target = self
        updates.action = #selector(updatesChanged)
        updates.toolTip = NSLocalizedString("Checks GitHub once a day. No documents are sent.", comment: "")

        shortcuts.title = NSLocalizedString("Keyboard Shortcuts…", comment: "")
        shortcuts.bezelStyle = .rounded
        shortcuts.target = self
        shortcuts.action = #selector(shortcutsPressed)

        return [
            (NSLocalizedString("Editor style", comment: ""), editorStyle),
            (NSLocalizedString("Search with", comment: ""), engine),
            (NSLocalizedString("Open in", comment: ""), editor),
            (NSLocalizedString("Markdown files", comment: ""), markdown),
            (NSLocalizedString("Menu bar", comment: ""), menuBar),
            (NSLocalizedString("Updates", comment: ""), updates),
            (NSLocalizedString("Reference", comment: ""), shortcuts),
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
        // A group is told apart by the air above it more than by its title.
        row.topPadding = first ? 0 : 22
        row.bottomPadding = 6
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

    // MARK: - Reading the settings back

    private func refresh() {
        appearance.selectedSegment = Settings.Theme.allCases.firstIndex(of: Settings.theme) ?? 0
        palette.selectItem(at: Settings.Palette.allCases.firstIndex(of: Settings.palette) ?? 0)

        textSize.doubleValue = Settings.textScale
        textSizeLabel.stringValue = String(format: NSLocalizedString("%@ pt", comment: ""), String(describing: Int(Settings.textScale)))
        width.selectItem(at: Settings.Width.allCases.firstIndex(of: Settings.width) ?? 1)

        // Left empty when it is only the account name, so the placeholder can
        // say where the name is coming from instead of it looking chosen.
        let stored = UserDefaults.standard.string(forKey: "authorName") ?? ""
        author.stringValue = stored
        commentingControls.state = Settings.showsCommentingControls ? .on : .off
        for swatch in swatches { swatch.isPicked = swatch.colour == Settings.noteColour }

        editorStyle.selectItem(at: Settings.EditorStyle.allCases.firstIndex(of: Settings.editorStyle) ?? 0)
        engine.selectItem(at: Settings.SearchEngine.allCases.firstIndex(of: Settings.searchEngine) ?? 0)
        if let preferred = Editors.preferred(from: Editors.installed),
           let index = editor.itemArray.firstIndex(where: { $0.representedObject as? URL == preferred }) {
            editor.selectItem(at: index)
        }
        menuBar.state = Settings.showInMenuBar ? .on : .off
        updates.state = Updates.automaticallyChecksForUpdates ? .on : .off
        // One or the other, never a dead button: there is either something to
        // press or a fact to state.
        let owns = MarkdownType.imarkIsDefault
        makeDefault.isHidden = owns
        isDefault.isHidden = !owns
    }

    // MARK: - Actions

    @objc private func appearanceChanged() {
        let all = Settings.Theme.allCases
        guard all.indices.contains(appearance.selectedSegment) else { return }
        Settings.theme = all[appearance.selectedSegment]
        Settings.applyThemeToApp()
    }

    @objc private func paletteChanged() {
        guard Settings.Palette.allCases.indices.contains(palette.indexOfSelectedItem) else { return }
        Settings.palette = Settings.Palette.allCases[palette.indexOfSelectedItem]
    }

    @objc private func textSizeChanged() {
        Settings.textScale = textSize.doubleValue.rounded()
        textSizeLabel.stringValue = String(format: NSLocalizedString("%@ pt", comment: ""), String(describing: Int(Settings.textScale)))
    }

    @objc private func widthChanged() {
        guard Settings.Width.allCases.indices.contains(width.indexOfSelectedItem) else { return }
        Settings.width = Settings.Width.allCases[width.indexOfSelectedItem]
    }

    @objc private func authorCommitted() { commitAuthor() }

    @objc private func commentingControlsChanged() {
        Settings.showsCommentingControls = commentingControls.state == .on
    }

    private func commitAuthor() {
        guard Settings.authorName != author.stringValue else { return }
        Settings.authorName = author.stringValue
    }

    @objc private func colourPicked(_ sender: Swatch) {
        Settings.noteColour = sender.colour
        for swatch in swatches { swatch.isPicked = swatch === sender }
    }

    @objc private func editorStyleChanged() {
        guard Settings.EditorStyle.allCases.indices.contains(editorStyle.indexOfSelectedItem) else { return }
        Settings.editorStyle = Settings.EditorStyle.allCases[editorStyle.indexOfSelectedItem]
    }

    @objc private func engineChanged() {
        guard Settings.SearchEngine.allCases.indices.contains(engine.indexOfSelectedItem) else { return }
        Settings.searchEngine = Settings.SearchEngine.allCases[engine.indexOfSelectedItem]
    }

    @objc private func editorChanged() {
        Settings.preferredEditor = editor.selectedItem?.representedObject as? URL
    }

    @objc private func menuBarChanged() {
        Settings.showInMenuBar = menuBar.state == .on
        MenuBarItem.shared.sync()
    }

    @objc private func updatesChanged() {
        Updates.automaticallyChecksForUpdates = updates.state == .on
    }

    @objc private func shortcutsPressed() { ShortcutsPanel.toggle() }

    @objc private func makeDefaultPressed() {
        MarkdownType.makeImarkDefault { [weak self] _ in self?.refresh() }
    }
}


/// Escape closes it, as it closes the Keyboard Shortcuts panel. A plain window
/// passes Escape on as `cancel:`, which nothing here answers, so the key did
/// nothing and the way out was ⌘W or the red dot. Closing goes through
/// `windowWillClose`, so a name still being typed is kept.
private final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}
