import AppKit

/// A fixed-height, scrollable list embedded as a submenu's single item — for long
/// Following / Playlist lists. Mouse-scroll, hover to highlight, click to choose.
/// (A typeable search field can't live inside an NSMenu, so this is mouse-driven.)
final class ScrollListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    struct Item { let title: String; let imageURL: URL?; let payload: Any }

    var onSelect: ((Item) -> Void)?

    private let items: [Item]
    private let imageCornerRadius: CGFloat
    private let width: CGFloat
    private let table = NSTableView()
    private var imageCache: [String: NSImage] = [:]
    private var trackingAreaRef: NSTrackingArea?
    private let rowH: CGFloat = 32

    init(items: [Item], width: CGFloat = 264, maxHeight: CGFloat = 320, imageCornerRadius: CGFloat = 4) {
        self.items = items
        self.imageCornerRadius = imageCornerRadius
        self.width = width
        let contentHeight = max(rowH, CGFloat(items.count) * rowH)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: min(contentHeight, maxHeight)))

        let scroll = NSScrollView(frame: bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = rowH
        table.backgroundColor = .clear
        table.style = .plain        // no inset padding above the first row
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        scroll.documentView = table
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func rowClicked() {
        choose(table.clickedRow)
    }

    private func choose(_ row: Int) {
        guard items.indices.contains(row) else { return }
        let item = items[row]
        enclosingMenuItem?.menu?.cancelTracking()
        onSelect?(item)
    }

    // MARK: Hover highlight (menu-like)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = table.convert(event.locationInWindow, from: nil)
        let row = table.row(at: point)
        if row >= 0 { table.selectRowIndexes([row], byExtendingSelection: false) }
        else { table.deselectAll(nil) }
    }

    override func mouseExited(with event: NSEvent) { table.deselectAll(nil) }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    // Custom row so the selection matches the menu: 6px side margins, rounded, accent.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        InsetSelectionRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell = NSTableCellView()
        var textX: CGFloat = 12

        if item.imageURL != nil {
            let image = NSImageView(frame: NSRect(x: 8, y: 4, width: 24, height: 24))
            image.imageScaling = .scaleProportionallyUpOrDown
            image.wantsLayer = true
            image.layer?.cornerRadius = imageCornerRadius
            image.layer?.masksToBounds = true
            image.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            image.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)
            cell.addSubview(image)
            cell.imageView = image
            loadImage(item.imageURL, into: image)
            textX = 40
        }

        let label = NSTextField(labelWithString: item.title)
        label.frame = NSRect(x: textX, y: 7, width: width - textX - 10, height: 18)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.autoresizingMask = [.width]
        cell.addSubview(label)
        cell.textField = label   // NSTableCellView flips text to white when selected
        return cell
    }

    private func loadImage(_ url: URL?, into view: NSImageView) {
        guard let url else { return }
        if let cached = imageCache[url.absoluteString] { view.image = cached; return }
        Task { @MainActor in
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return }
            self.imageCache[url.absoluteString] = image
            view.image = image
        }
    }
}

/// Row that draws the selection like a menu item: inset 6px, rounded, accent.
private final class InsetSelectionRowView: NSTableRowView {
    // Force "emphasized" so the cell flips its text to white even though the
    // menu's table isn't the key/first-responder view.
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let rect = bounds.insetBy(dx: 6, dy: 1)
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    }
}
