// MARK: - STabFolders.swift
// Copyright © 2026 avenged110.
// SPDX-License-Identifier: GPL-3.0-only
// LAN Stream settings window: "Shared Folders" tab.
//
// The full implementation lives in SettingsTabFoldersController, a pure-AppKit
// NSViewController hosted directly as a settings tab. This follows the
// STabPK pattern rather than the SwiftUI-centric STabAQ one: the add/remove
// buttons here mutate a list that an NSTableView renders, and driving that
// through SwiftUI bindings is exactly the arrangement that produced the
// updateNSView race conditions documented in STabPK.swift.

import AppKit

// MARK: - SettingsTabFoldersController
final class SettingsTabFoldersController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, Loggable {

    nonisolated static let logTag = "[STabFolders]"

    // MARK: - Dependencies
    private let folderStore: FolderStore
    private let status: ServerStatus

    // MARK: - Stored UI references
    private var foldersTable: NSTableView!
    private var removeButton: NSButton!
    private var statusLabel: NSTextField!

    // MARK: - State
    // Deleted batches, newest last, for ⌘Z undo. Mirrors STabPK's stack.
    private var deletedBatchesStack: [[(index: Int, folder: SharedFolder)]] = []

    // Drives the live status line and reachability coloring while the tab is on
    // screen. Both are updated by background rescans that this controller has no
    // direct signal from, and this is the tab a user opens precisely when trying to
    // work out why a folder is not showing up on the player — a status line frozen
    // at whatever it said when the window opened would be actively misleading.
    private var refreshTimer: Timer?
    private static let refreshInterval: TimeInterval = 2.0

    private let folderColumnID = NSUserInterfaceItemIdentifier("FolderColumn")
    private let folderCellID = NSUserInterfaceItemIdentifier("FolderCell")

    // Held so the container-format setting can rewrite it without rebuilding the
    // tab. The tab is created once and kept, so a header set only at load would go
    // stale the moment the setting changed in the other tab.
    private weak var headerLabel: NSTextField?
    private var lastKnownFileCounts: [UUID: Int] = [:]

    // "Share the <formats> files in these folders and their subfolders:"
    private static func headerText() -> String {
        "Share the \(Preferences.containerFormats.contentDescription) files in these "
            + "folders and their subfolders:"
    }

    // MARK: - Init
    @MainActor
    init(folderStore: FolderStore, status: ServerStatus) {
        self.folderStore = folderStore
        self.status = status
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - loadView (builds the entire UI programmatically)
    override func loadView() {
        // The window pins the view to its own (measured) size once hosted; this is only
        // the initial frame Auto Layout resolves against.
        let contentSize = NSSize(width: SettingsLayout.contentWidth,
                                 height: SettingsLayout.minimumContentHeight)
        self.view = NSView(frame: NSRect(origin: .zero, size: contentSize))
        self.preferredContentSize = contentSize

        // --- Header ---------------------------------------------------------
        let headerLabel = NSTextField(labelWithString: Self.headerText())
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        self.headerLabel = headerLabel

        let headerContainer = NSView()
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(headerLabel)
        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(
                equalTo: headerContainer.topAnchor,
                constant: SettingsLayout.folderHeaderExtraTopPadding),
            headerLabel.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            headerLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: headerContainer.trailingAnchor),
            headerContainer.heightAnchor.constraint(
                equalToConstant: SettingsLayout.headerHeight)
        ])

        // --- Table ----------------------------------------------------------
        let tableScroll = NSScrollView()
        tableScroll.borderType = .bezelBorder
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = false
        tableScroll.translatesAutoresizingMaskIntoConstraints = false

        foldersTable = NSTableView()
        foldersTable.headerView = nil
        foldersTable.allowsMultipleSelection = true
        // Two-line cells (name over path) need more room than the single-line
        // 22 pt rows used elsewhere in the app.
        foldersTable.rowHeight = 38
        foldersTable.usesAlternatingRowBackgroundColors = true
        foldersTable.delegate = self
        foldersTable.dataSource = self
        foldersTable.allowsColumnResizing = false
        foldersTable.registerForDraggedTypes([.fileURL])
        foldersTable.setDraggingSourceOperationMask(.copy, forLocal: false)
        foldersTable.draggingDestinationFeedbackStyle = .regular
        foldersTable.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: folderColumnID)
        column.title = "Shared Folder"
        column.minWidth = 320
        foldersTable.addTableColumn(column)
        // Keep the single column flush with the scroll view's clip width so it can
        // never be fractionally wider than the visible area.
        foldersTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableScroll.documentView = foldersTable

        // --- Buttons --------------------------------------------------------
        let addButton = NSButton(title: "+", target: self,
                                 action: #selector(addFolder(_:)))
        addButton.bezelStyle = .rounded
        addButton.controlSize = .regular
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.toolTip = "Add a folder to share (⌘N)"

        removeButton = NSButton(title: "−", target: self,
                                action: #selector(removeFolder(_:)))
        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .regular
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.isEnabled = false
        removeButton.toolTip = "Stop sharing the selected folders (Delete)"

        // Live server state, shown here because this is the tab where the user is
        // most likely to be diagnosing "why can't the player see my files".
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        // Middle rather than tail. This line is now three facts joined together —
        // what is being served, where, and what is missing — and the two that matter
        // most sit at its ends. Tail truncation drops the unavailable count, which is
        // the one piece of it a user needs to act on; middle truncation elides the
        // address instead, which is the least critical part and is on the menu anyway.
        // Only reached by an unusually long combination (many folders, a long
        // address); the ordinary line has room to spare.
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.defaultLow,
                                                            for: .horizontal)

        let buttonStack = NSStackView(views: [addButton, removeButton, statusLabel])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.alignment = .centerY
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        // --- Layout ---------------------------------------------------------
        let verticalStack = NSStackView(
            views: [headerContainer, tableScroll, buttonStack])
        verticalStack.orientation = .vertical
        verticalStack.alignment = .leading
        verticalStack.spacing = SettingsLayout.tabStackSpacing
        verticalStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(verticalStack)

        NSLayoutConstraint.activate([
            verticalStack.topAnchor.constraint(
                equalTo: view.topAnchor, constant: SettingsLayout.tabTopPadding),
            verticalStack.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: SettingsLayout.tabPadding),
            verticalStack.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -SettingsLayout.tabPadding),
            verticalStack.bottomAnchor.constraint(
                equalTo: view.bottomAnchor, constant: -SettingsLayout.tabPadding),

            tableScroll.leadingAnchor.constraint(equalTo: verticalStack.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: verticalStack.trailingAnchor),
            buttonStack.leadingAnchor.constraint(equalTo: verticalStack.leadingAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: verticalStack.trailingAnchor)
        ])

        tableScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        tableScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        foldersTable.reloadData()
        refreshStatusLabel()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The container-format setting lives in the other tab, and only one tab is
        // ever on screen, so becoming visible is a sufficient — and the only
        // necessary — moment to pick up a change to it.
        headerLabel?.stringValue = Self.headerText()
        foldersTable.reloadData()
        refreshStatusLabel()
        // The table must be first responder for the Delete key and ⌘-shortcuts
        // handled in keyDown to reach this controller.
        unsafe view.window?.makeFirstResponder(foldersTable)

        refreshTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval,
                                         repeats: true) { [weak self] _ in
            // Timer callbacks scheduled on the main run loop are delivered on the
            // main thread, which is this controller's isolation domain.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshStatusLabel()
                self.refreshReachabilityIfChanged()
            }
        }
        // .common so the status keeps updating while a menu is open or the table is
        // being scrolled, rather than stalling in event-tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        refreshTimer?.invalidate()
        refreshTimer = nil
        // NSTabViewController keeps every tab's content controller loaded, so a
        // selection made before switching tabs would otherwise persist invisibly
        // and leave the "−" button enabled against rows the user cannot see.
        foldersTable.deselectAll(nil)
        updateRemoveButtonState()
    }

    // MARK: - Status line
    private func refreshStatusLabel() {
        // servingSummaryWithAddress folds the address into the sentence, which there
        // is room for here but not in the menu, where it occupies its own line.
        //
        // Unreachable folders no longer change the SHAPE of this line, only its
        // numbers. The counts already describe what is servable right now, so a
        // missing drive makes them drop on their own — and this tab is the one place
        // that names the affected folder in the row above, in red, with its last
        // known path. Repeating that as a warning down here swapped out the address
        // to say something the table was already saying better.
        let text = status.servingSummaryWithAddress
        guard statusLabel.stringValue != text else { return }
        statusLabel.stringValue = text
    }

    // Reloads the table only when reachability actually changed. Reloading
    // unconditionally on every tick would cancel an in-progress selection drag and
    // fight the user for control of the list.
    private var lastKnownReachability: [UUID: Bool] = [:]

    private func refreshReachabilityIfChanged() {
        var current: [UUID: Bool] = [:]
        for folder in folderStore.folders {
            if let reachable = folderStore.isReachable(folder) {
                current[folder.id] = reachable
            }
        }
        // File counts are refreshed on the same tick and by the same rule. They
        // change for reasons the table has no other way to hear about — a rescan
        // finishing, a file appearing in a watched folder — and a count that only
        // updated when reachability happened to flip would sit wrong indefinitely.
        let currentCounts = folderStore.fileCounts

        // Both deltas are computed before anything is reloaded, and the reload
        // happens at most once. A finishing rescan routinely moves both at the same
        // moment, and this used to answer that by rebuilding the table twice on the
        // same tick — through two paths that did not even agree about preserving the
        // selection.
        let countsChanged = currentCounts != lastKnownFileCounts
        let reachabilityChanged = current != lastKnownReachability
        guard countsChanged || reachabilityChanged else { return }

        lastKnownFileCounts = currentCounts
        lastKnownReachability = current

        let selection = foldersTable.selectedRowIndexes
        foldersTable.reloadData()
        foldersTable.selectRowIndexes(selection, byExtendingSelection: false)
    }

    // MARK: - NSTableViewDataSource
    func numberOfRows(in tableView: NSTableView) -> Int { folderStore.folders.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let folders = folderStore.folders
        guard folders.indices.contains(row) else { return nil }
        let folder = folders[row]

        let cell: FolderCellView
        if let existing = tableView.makeView(withIdentifier: folderCellID,
                                             owner: self) as? FolderCellView {
            cell = existing
        } else {
            cell = FolderCellView(identifier: folderCellID)
        }

        // Reachability comes from the cache the last rescan populated, never from a
        // live resolve() call. A data source is re-entered on every reload and runs
        // on the main thread; doing filesystem I/O here froze the window for the
        // duration of a dead mount's timeout, once per visible row.
        //
        // An unreachable folder is rendered in red with its last known path.
        // Showing it as normal would hide the single most common real-world
        // failure: an external drive that did not remount.
        let reachability = folderStore.isReachable(folder)
        let resolvedURL = folderStore.resolvedURLs[folder.id]
        let path = resolvedURL?.path(percentEncoded: false) ?? folder.lastKnownPath

        cell.setName(folder.displayName,
                     fileCount: folderStore.fileCounts[folder.id],
                     isDimmed: reachability == false)

        switch reachability {
        case .some(true):
            cell.pathField.stringValue = path
            cell.pathField.textColor = .secondaryLabelColor
        case .some(false):
            cell.pathField.stringValue = "\(path) — Not available"
            cell.pathField.textColor = .systemRed
        case .none:
            // Added since the last rescan, or the first scan has not finished.
            cell.pathField.stringValue = path
            cell.pathField.textColor = .secondaryLabelColor
        }

        if reachability == false {
            cell.iconView.image = NSImage(systemSymbolName: "questionmark.folder",
                                          accessibilityDescription: "Folder unavailable")
        } else if let resolvedURL {
            cell.iconView.image = NSWorkspace.shared.icon(
                forFile: resolvedURL.path(percentEncoded: false))
        } else {
            cell.iconView.image = NSImage(systemSymbolName: "folder",
                                          accessibilityDescription: "Folder")
        }
        return cell
    }

    // MARK: - NSTableViewDelegate
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButtonState()
    }

    // MARK: - Drag-and-drop
    func tableView(_ tableView: NSTableView,
                   validateDrop info: any NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation)
        -> NSDragOperation {
        guard !droppedDirectories(from: info).isEmpty else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .copy
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: any NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let directories = droppedDirectories(from: info)
        guard !directories.isEmpty else { return false }
        addFolders(directories)
        return true
    }

    private func droppedDirectories(from info: any NSDraggingInfo) -> [URL] {
        guard let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: nil) as? [URL] else { return [] }
        return urls.filter(\.isExistingDirectory)
    }

    // MARK: - Actions
    private func updateRemoveButtonState() {
        removeButton.isEnabled = foldersTable.selectedRow >= 0
    }

    @objc private func addFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.title = "Choose Folders to Share"
        panel.prompt = "Share"

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK else { return }
            self.addFolders(panel.urls)
        }

        if let window = unsafe view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    private func addFolders(_ urls: [URL]) {
        var rejections: [String] = []
        var addedCount = 0

        for url in urls {
            if let rejection = folderStore.add(url: url) {
                rejections.append(rejection.message)
            } else {
                addedCount += 1
            }
        }

        if addedCount > 0 {
            foldersTable.reloadData()
            // Select the rows just added so the result of the action is visible.
            let firstNewRow = folderStore.folders.count - addedCount
            let newRows = IndexSet(integersIn: firstNewRow..<folderStore.folders.count)
            foldersTable.selectRowIndexes(newRows, byExtendingSelection: false)
            foldersTable.scrollRowToVisible(folderStore.folders.count - 1)
            updateRemoveButtonState()
            refreshStatusLabel()
        }

        guard !rejections.isEmpty else { return }
        presentAlert(title: rejections.count == 1
                        ? "Folder Not Added"
                        : "\(rejections.count) Folders Not Added",
                     message: rejections.joined(separator: "\n\n"))
    }

    @objc private func removeFolder(_ sender: Any?) {
        let selected = foldersTable.selectedRowIndexes
        guard !selected.isEmpty else { return }

        let batch = selected.compactMap { index -> (index: Int, folder: SharedFolder)? in
            guard folderStore.folders.indices.contains(index) else { return nil }
            return (index, folderStore.folders[index])
        }
        guard !batch.isEmpty else { return }

        deletedBatchesStack.append(batch)
        _ = folderStore.remove(atOffsets: selected)

        foldersTable.reloadData()
        foldersTable.deselectAll(nil)
        updateRemoveButtonState()
        refreshStatusLabel()
    }

    @objc private func undoLastDeletion() {
        guard let batch = deletedBatchesStack.popLast() else { return }
        folderStore.reinsert(batch)
        foldersTable.reloadData()

        let restoredRows = IndexSet(batch.map(\.index)
            .filter { folderStore.folders.indices.contains($0) })
        foldersTable.selectRowIndexes(restoredRows, byExtendingSelection: false)
        if let first = restoredRows.first { foldersTable.scrollRowToVisible(first) }
        updateRemoveButtonState()
        refreshStatusLabel()
    }

    @objc private func copySelectedPaths(_ sender: Any?) {
        let rows = foldersTable.selectedRowIndexes
        guard !rows.isEmpty else { return }
        let paths = rows.compactMap { index -> String? in
            guard folderStore.folders.indices.contains(index) else { return nil }
            return folderStore.folders[index].lastKnownPath
        }
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        Self.log("Copied \(paths.count) shared folder path(s) to the pasteboard.")
    }

    @objc private func revealSelectedInFinder(_ sender: Any?) {
        let rows = foldersTable.selectedRowIndexes
        let urls = rows.compactMap { index -> URL? in
            guard folderStore.folders.indices.contains(index) else { return nil }
            return folderStore.resolvedURLs[folderStore.folders[index].id]
        }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - Keyboard shortcuts
    override func keyDown(with event: NSEvent) {
        let hasCommand = event.modifierFlags.contains(.command)
        let character = event.charactersIgnoringModifiers?.lowercased()

        switch (event.keyCode, hasCommand) {
        case (51, false):   // Delete
            if removeButton.isEnabled { removeFolder(nil) }
        case (_, true) where character == "z":
            undoLastDeletion()
        case (_, true) where character == "n":
            addFolder(nil)
        case (_, true) where character == "c":
            copySelectedPaths(nil)
        case (_, true) where character == "r":
            revealSelectedInFinder(nil)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Alerts
    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let window = unsafe view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - FolderCellView
// Two-line cell: folder icon, display name, and the full path beneath it. The path
// is shown because two folders can easily share a display name ("Movies" on each
// of two drives), and without it the list would be ambiguous exactly when it
// matters most.
private final class FolderCellView: NSTableCellView {

    let iconView = NSImageView()
    let nameField = NSTextField(labelWithString: "")
    let pathField = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameField.font = .systemFont(ofSize: NSFont.systemFontSize)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.cell?.usesSingleLineMode = true
        nameField.translatesAutoresizingMaskIntoConstraints = false

        pathField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathField.textColor = .secondaryLabelColor
        // Truncating the head keeps the meaningful tail of a long path visible,
        // which is the opposite of the right choice for a filename but correct here.
        pathField.lineBreakMode = .byTruncatingHead
        pathField.cell?.usesSingleLineMode = true
        pathField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(nameField)
        addSubview(pathField)
        unsafe self.textField = nameField
        unsafe self.imageView = iconView

        // Hard-clip backstop so no subview can render outside the row bounds.
        wantsLayer = true
        layer?.masksToBounds = true

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor,
                                               constant: 8),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            nameField.topAnchor.constraint(equalTo: topAnchor, constant: 4),

            pathField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            pathField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            pathField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 1)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // Name and file count as one attributed run rather than a second text field.
    //
    // A separate trailing label would need its own constraints against a name that
    // truncates, and the two would then compete for the same horizontal space: a
    // long folder name would either push the count off the row or be truncated in
    // favor of it depending on which priority won. In one string the count simply
    // travels with the name and the existing tail truncation applies to the whole
    // thing, which is the correct behavior — a name long enough to crowd out its
    // own count is a name the user needs to read more than the number.
    //
    // nil count means the folder has not been scanned yet, which is different from
    // a scanned folder containing nothing: the first shows no suffix at all, the
    // second says "no files" rather than leaving the user to wonder whether the
    // scan simply had not run.
    func setName(_ name: String, fileCount: Int?, isDimmed: Bool) {
        let nameColor: NSColor = isDimmed ? .disabledControlTextColor : .labelColor
        let line = NSMutableAttributedString(
            string: name,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                         .foregroundColor: nameColor])

        if let fileCount {
            let suffix: String
            switch fileCount {
            case 0:  suffix = "   (No files)"
            case 1:  suffix = "   (1 file)"
            default: suffix = "   (\(fileCount) files)"
            }
            line.append(NSAttributedString(
                string: suffix,
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                             .foregroundColor: NSColor.secondaryLabelColor]))
        }
        nameField.attributedStringValue = line
    }
}
