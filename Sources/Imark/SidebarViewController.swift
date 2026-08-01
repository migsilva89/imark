import AppKit
import ImarkRender

/// Table of contents plus the sibling `.md` files, in one column.
///
/// A flat table with section-header rows rather than an outline view: the
/// headings already carry their depth as indentation, and nothing here needs
/// to be expanded or collapsed.
final class SidebarViewController: NSViewController {
    enum Row {
        case header(String)
        case heading(TocEntry)
        case file(URL)
    }

    var onSelectHeading: ((String) -> Void)?
    var onSelectFile: ((URL) -> Void)?

    private let scroll = NSScrollView()
    private let table = NSTableView()

    private var rows: [Row] = []
    private var toc: [TocEntry] = []
    private var files: [URL] = []
    private var currentFile: URL?
    private var activeID: String?

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

    func update(toc: [TocEntry]) {
        self.toc = toc
        rebuild()
    }

    func update(files: [URL], current: URL) {
        self.files = files
        self.currentFile = current
        rebuild()
    }

    func setActive(_ id: String) {
        guard activeID != id else { return }
        activeID = id
        // Only the two affected rows need redrawing, but the list is short and
        // reloading it outright avoids bookkeeping bugs.
        table.reloadData()
    }

    private func rebuild() {
        var built: [Row] = []
        if !toc.isEmpty {
            built.append(.header("Contents"))
            built.append(contentsOf: toc.map(Row.heading))
        }
        // A lone file is just the document you already have open.
        if files.count > 1 {
            built.append(.header("Files"))
            built.append(contentsOf: files.map(Row.file))
        }
        rows = built
        table.reloadData()
    }

    @objc private func rowClicked() {
        activate(row: table.clickedRow)
    }

    private func activate(row: Int) {
        guard rows.indices.contains(row) else { return }
        switch rows[row] {
        case .header: break
        case .heading(let entry): onSelectHeading?(entry.id)
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
            return HeaderCell(title: title, isFirst: row == 0)

        case .heading(let entry):
            let cell = ItemCell(
                text: entry.title,
                indent: CGFloat(max(0, entry.level - 1)) * 13,
                isActive: entry.id == activeID
            )
            return cell

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

// MARK: - Cells

private final class HeaderCell: NSTableCellView {
    init(title: String, isFirst: Bool) {
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
    init(text: String, indent: CGFloat, isActive: Bool, symbol: String? = nil) {
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

        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16 + indent),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }
}
