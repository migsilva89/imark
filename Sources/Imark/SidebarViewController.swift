import AppKit
import ImarkRender

/// Table of contents plus the sibling `.md` files, in one column.
///
/// A flat table with section-header rows rather than an outline view: the
/// headings already carry their depth as indentation, and the collapsing is
/// simple enough to do by filtering the list.
final class SidebarViewController: NSViewController {
    enum Row {
        case header(String)
        case heading(TocEntry, hasChildren: Bool, isCollapsed: Bool)
        case file(URL)
    }

    var onSelectHeading: ((String) -> Void)?
    var onSelectFile: ((URL) -> Void)?

    private let scroll = NSScrollView()
    private let table = OutlineTable()

    private var rows: [Row] = []
    private var toc: [TocEntry] = []
    private var files: [URL] = []
    private var recents: [URL] = []
    private var currentFile: URL?
    private var activeID: String?

    /// Headings whose descendants are hidden.
    private var collapsed: Set<String> = []
    private var hasChosenDefaultState = false

    /// Beyond this many entries an outline stops being scannable, and the
    /// second level gets folded away until asked for.
    private static let autoCollapseThreshold = 20

    override func loadView() {
        view = NSView()

        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .sourceList
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.addTableColumn(NSTableColumn(identifier: .init("main")))
        table.onArrow = { [weak self] expand in self?.arrowPressed(expand: expand) }

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        // Left on so the list clears the toolbar instead of sliding under it.
        scroll.automaticallyAdjustsContentInsets = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Content

    /// Called when the window switches documents, so one file's folded state
    /// does not carry over to the next.
    func resetOutlineState() {
        collapsed.removeAll()
        hasChosenDefaultState = false
    }

    func update(toc: [TocEntry]) {
        self.toc = toc
        // A live reload rebuilds the outline; keep whatever is still folded.
        collapsed.formIntersection(Set(toc.map(\.id)))
        chooseDefaultStateIfNeeded()
        rebuild()
    }

    func update(files: [URL], current: URL, recents: [URL] = []) {
        self.files = files
        self.currentFile = current
        self.recents = recents
        rebuild()
    }

    func setActive(_ id: String) {
        guard activeID != id else { return }
        activeID = id
        // Following the document into a folded branch should open it, or the
        // highlight lands on a row nobody can see.
        if revealAncestors(of: id) {
            rebuild()
        } else {
            table.reloadData()
        }
    }

    private func chooseDefaultStateIfNeeded() {
        guard !hasChosenDefaultState, !toc.isEmpty else { return }
        hasChosenDefaultState = true
        guard toc.count > Self.autoCollapseThreshold else { return }

        // Fold everything below the shallowest level. On a changelog that
        // leaves one row per version instead of three.
        let top = toc.map(\.level).min() ?? 1
        for (index, entry) in toc.enumerated() where entry.level > top {
            if hasChildren(at: index) { collapsed.insert(entry.id) }
        }
    }

    private func hasChildren(at index: Int) -> Bool {
        guard index + 1 < toc.count else { return false }
        return toc[index + 1].level > toc[index].level
    }

    /// Opens every folded heading that contains `id`. Returns whether anything
    /// actually changed.
    @discardableResult
    private func revealAncestors(of id: String) -> Bool {
        guard let position = toc.firstIndex(where: { $0.id == id }) else { return false }
        var changed = false
        var level = toc[position].level
        for index in stride(from: position - 1, through: 0, by: -1) where toc[index].level < level {
            level = toc[index].level
            if collapsed.remove(toc[index].id) != nil { changed = true }
        }
        return changed
    }

    /// The outline minus anything inside a folded heading.
    private func visibleHeadings() -> [(entry: TocEntry, index: Int)] {
        var result: [(TocEntry, Int)] = []
        var hidingBelow: Int?

        for (index, entry) in toc.enumerated() {
            if let level = hidingBelow {
                if entry.level > level { continue }
                hidingBelow = nil
            }
            result.append((entry, index))
            if collapsed.contains(entry.id) { hidingBelow = entry.level }
        }
        return result
    }

    private func rebuild() {
        var built: [Row] = []
        if !toc.isEmpty {
            built.append(.header("Contents"))
            for (entry, index) in visibleHeadings() {
                built.append(.heading(
                    entry,
                    hasChildren: hasChildren(at: index),
                    isCollapsed: collapsed.contains(entry.id)
                ))
            }
        }
        // A lone file is just the document you already have open.
        if files.count > 1 {
            built.append(.header("In this folder"))
            built.append(contentsOf: files.map(Row.file))
        }
        if !recents.isEmpty {
            built.append(.header("Recent"))
            built.append(contentsOf: recents.map(Row.file))
        }
        rows = built
        table.reloadData()
    }

    // MARK: - Folding

    private func toggle(_ id: String) {
        if collapsed.remove(id) == nil { collapsed.insert(id) }
        rebuild()
    }

    private func arrowPressed(expand: Bool) {
        let index = table.selectedRow
        guard rows.indices.contains(index),
              case .heading(let entry, let hasChildren, let isCollapsed) = rows[index],
              hasChildren, isCollapsed == expand
        else { return }
        toggle(entry.id)
        table.selectRowIndexes([index], byExtendingSelection: false)
    }

    @objc private func rowClicked() {
        activate(row: table.clickedRow)
    }

    private func activate(row: Int) {
        guard rows.indices.contains(row) else { return }
        switch rows[row] {
        case .header: break
        case .heading(let entry, _, _): onSelectHeading?(entry.id)
        case .file(let url): onSelectFile?(url)
        }
    }
}

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return row == 0 ? 22 : 34 }
        return 24
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { return false }
        return true
    }

    /// Arrow keys move the selection, and moving the selection should take the
    /// document with it — otherwise the list scrolls and nothing else happens.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0 else { return }
        activate(row: table.selectedRow)
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        switch rows[row] {
        case .header(let title):
            return HeaderCell(title: title)

        case .heading(let entry, let hasChildren, let isCollapsed):
            return ItemCell(
                text: entry.title,
                indent: CGFloat(max(0, entry.level - 1)) * 13,
                isActive: entry.id == activeID,
                disclosure: hasChildren ? isCollapsed : nil,
                onToggle: { [weak self] in self?.toggle(entry.id) }
            )

        case .file(let url):
            return ItemCell(
                text: url.deletingPathExtension().lastPathComponent,
                indent: 0,
                isActive: url == currentFile,
                symbol: "doc.text"
            )
        }
    }
}

// MARK: - Table

/// Left and right collapse and expand, the way every outline on this platform
/// behaves. NSTableView has no notion of it, so the keys are caught here.
private final class OutlineTable: NSTableView {
    var onArrow: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onArrow?(false)
        case 124: onArrow?(true)
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - Cells

private final class HeaderCell: NSTableCellView {
    init(title: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
}

private final class ItemCell: NSTableCellView {
    /// Every row here goes somewhere when clicked, and a row that goes
    /// somewhere should say so before you press it.
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    private let onToggle: (() -> Void)?

    init(
        text: String,
        indent: CGFloat,
        isActive: Bool,
        symbol: String? = nil,
        disclosure: Bool? = nil,
        onToggle: (() -> Void)? = nil
    ) {
        self.onToggle = onToggle
        super.init(frame: .zero)

        let pill = NSVisualEffectView()
        pill.material = .selection
        pill.state = .active
        pill.isEmphasized = true
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 6
        pill.isHidden = !isActive
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12.5, weight: isActive ? .medium : .regular)
        label.textColor = isActive ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let icon = NSImageView(image: image)
            icon.contentTintColor = .tertiaryLabelColor
            icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            stack.addArrangedSubview(icon)
        }
        stack.addArrangedSubview(label)
        addSubview(stack)

        // The triangle sits in the margin to the left of the text, so folding a
        // section never shifts the outline sideways. That margin has to be wide
        // enough for it: at the old numbers the glyph started 2pt to the left of
        // the selection pill and hung off its edge.
        if let collapsed = disclosure {
            let image = NSImage(
                systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
                accessibilityDescription: nil
            )
            let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(toggled))
            button.isBordered = false
            button.contentTintColor = .tertiaryLabelColor
            button.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 16),
                button.heightAnchor.constraint(equalToConstant: 16),
                button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4 + indent),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Same for every row, with or without a triangle: a heading that can
            // fold used to sit 2pt right of one that cannot.
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22 + indent),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func toggled() { onToggle?() }
}
