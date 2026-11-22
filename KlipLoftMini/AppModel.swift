import os
import AppKit
import SwiftData
import SwiftUI

/// One line in the Spotlight list: a clip, or a pinboard while browsing pinboards.
enum Row: Identifiable {
    case clip(ClipItem)
    case pinboard(Pinboard, count: Int)

    var id: UUID {
        switch self {
        case .clip(let item): item.id
        case .pinboard(let board, _): board.id
        }
    }
}

/// What the list shows: the latest clips, every pinboard, or one pinboard's clips.
enum Mode: Equatable {
    case recent
    case pinboards
    case pinboard(UUID)
}

@Observable
final class AppModel {
    static let shared = AppModel()

    let container: ModelContainer
    let sync = CloudSync()

    var mode: Mode = .recent { didSet { if mode != oldValue { selectedIndex = 0; refresh() } } }
    /// Typing searches once it pauses (`searchDelay`), so keystrokes never wait for the database.
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            markedFilter = nil
            selectedIndex = 0
            searchTask?.cancel()
            // Clearing the search (Esc, reopening) shows the history at once.
            guard !query.isEmpty else { return refresh() }
            searchTask = Task { [weak self] in
                try? await Task.sleep(for: AppModel.searchDelay)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    private static let searchDelay = Duration.milliseconds(70)
    /// Type and app chips in the search; types match any of, apps match any of, and both must match.
    var searchFilters: [SearchFilter] = [] {
        didSet { if searchFilters != oldValue { markedFilter = nil; selectedIndex = 0; refresh() } }
    }
    /// The chip the first ⌫ on an empty search marked; the next ⌫ removes it.
    var markedFilter: SearchFilter?
    /// The apps clips came from, most frequent first, for the filter menu; refreshed on each open.
    private(set) var filterApps: [(bundleID: String, name: String)] = []
    private(set) var rows: [Row] = []
    /// How many clips (or pinboards) the search and filters match in all, for the chip above the
    /// search; nil while nothing is typed or filtered.
    private(set) var matchCount: Int?
    var selectedIndex = 0
    /// The clip shown in the preview beside the list (right-click or →).
    var previewItemID: UUID?
    /// Each pinboard's color and name by ID, for the pins on pinned clips.
    private(set) var pinboardColors: [UUID: Color] = [:]
    private(set) var pinboardNames: [UUID: String] = [:]
    /// Bumped each time the panel opens, so the search field takes focus again.
    var focusToken = 0
    /// The mouse is driving the selection: set when it actually moves over the panel, cleared by
    /// any key. Rows that slide under a still pointer (scrolling, opening) never take the selection.
    var mouseActive = false
    /// Where the pointer was on screen when it last counted, to tell a real move (the pointer's
    /// screen position changed) from rows sliding under a still pointer.
    @ObservationIgnored var lastMouseLocation = NSEvent.mouseLocation

    /// Each row on screen, by its clip's (or pinboard's) ID, in the panel's top-left coordinates; rows report their own
    /// frames as they appear and scroll. The panel finds the row under the pointer from these:
    /// it gets no hover or mouse-moved events while another app is in front.
    /// Keyed by ID, not position: as a search changes the list, a row leaving would otherwise
    /// clear the position a new row had just claimed.
    @ObservationIgnored var rowFrames: [UUID: CGRect] = [:]
    /// The list's visible area, same coordinates: rows scrolled out of view still report frames.
    var listFrame: CGRect {
        CGRect(x: SpotlightLayout.shadowMargin, y: SpotlightLayout.chipRow + SpotlightLayout.searchHeight + 12, width: SpotlightLayout.listWidth, height: SpotlightLayout.listHeight)
    }

    /// On a short timer while the panel is open. The mouse takes the selection only if the pointer
    /// itself moved on screen since it last counted; rows sliding under a still pointer don't.
    /// - Parameter point: the pointer in the panel's top-left coordinates.
    func checkPointer(screenLocation: NSPoint, point: CGPoint) {
        let id = listFrame.contains(point) ? rowFrames.first { $0.value.contains(point) }?.key : nil
        let index = id.flatMap { id in rows.firstIndex { $0.id == id } }
        if screenLocation != lastMouseLocation {
            lastMouseLocation = screenLocation
            if index != nil, !mouseActive { mouseActive = true }
        }
        if mouseActive, let index, selectedIndex != index, rows.indices.contains(index) { selectedIndex = index }
    }
    private(set) var accessibilityGranted = PasteService.isTrusted

    @ObservationIgnored private var monitor: ClipboardMonitor!
    @ObservationIgnored private(set) var screenshots: ScreenshotWatcher!
    @ObservationIgnored private(set) var panel: SpotlightPanelController!
    @ObservationIgnored private var pruneTimer: Timer?
    @ObservationIgnored private var permissionTimer: Timer?
    @ObservationIgnored private var publishedSourceApps: Set<String> = []
    @ObservationIgnored private var preferences: PreferencesWindowController?

    var context: ModelContext { container.mainContext }

    private init() {
        container = Self.makeContainer()
    }

    func start() {
        Prefs.registerDefaults()
        monitor = ClipboardMonitor { [weak self] draft in
            self?.store(draft)
            self?.playSound("Bottle")
        }
        monitor.start()
        screenshots = ScreenshotWatcher { [weak self] draft in self?.storeScreenshot(draft) }
        if UserDefaults.standard.bool(forKey: Prefs.captureScreenshots) { screenshots.setEnabled(true) }
        panel = SpotlightPanelController(model: self)
        HotKey.shared.onPress = { [weak self] in self?.panel.toggle() }
        HotKey.shared.registerSaved()
        let launch = Date.now
        sync.onImport = { [weak self] in
            self?.mergeDuplicates()
            self?.pruneHistory()
            self?.useStoredAppIcons()
            self?.rebuildTagIndex()
            self?.historyChanged()
            self?.addWelcomeClipsIfFreshInstall(since: launch)
        }
        sync.onCapacityChange = { [weak self] in self?.pruneHistory() }
        sync.onAccountUnavailable = { [weak self] in self?.addWelcomeClipsIfFreshInstall(since: launch) }
        sync.start(storeWasEmpty: ((try? context.fetchCount(FetchDescriptor<ClipItem>())) ?? 0) == 0)
        mergeDuplicates()
        removeOrphanedLocalImages()
        useStoredAppIcons()
        // With iCloud on, the welcome clips wait for the first download (onImport above).
        if CloudSync.canPrune { addWelcomeClipsIfFreshInstall(since: launch) }
        pruneHistory()
        // Off the launch path, so the first search doesn't pay for them: the keyword index, and one
        // throwaway text search that brings the clip store into the disk cache.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { AppModel.shared.warmUpSearch() }
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.pruneHistory() }
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.refreshPermissionStatus() }
        }
        refresh()
    }

    // MARK: Store

    /// Inside the sandbox container, so this never shares files with KlipLoft; the two apps
    /// meet only through iCloud.
    static let storeDirectory = URL.applicationSupportDirectory.appending(path: "Klip", directoryHint: .isDirectory)

    /// The same schema and CloudKit container as KlipLoft, so both apps sync one history.
    private static func makeContainer() -> ModelContainer {
        let directory = storeDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let synced = ModelConfiguration(
            schema: Schema([ClipItem.self, Pinboard.self, SourceApp.self]),
            url: directory.appending(path: "Klip.store"),
            cloudKitDatabase: CloudSync.isEnabled ? .private(CloudSync.containerID) : .none
        )
        let local = ModelConfiguration(
            "Local",
            schema: Schema([LocalImage.self, ClipEdit.self]),
            url: directory.appending(path: "KlipLocal.store"),
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: ClipItem.self, Pinboard.self, SourceApp.self, LocalImage.self, ClipEdit.self, configurations: synced, local)
        } catch {
            fatalError("Could not open the KlipLoft Mini store: \(error)")
        }
    }

    func store(_ draft: ClipDraft) {
        let hash = draft.contentHash
        var descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.contentHash == hash })
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            existing.createdAt = .now
            existing.sourceBundleID = draft.sourceBundleID
            existing.sourceAppName = draft.sourceAppName
            publishSourceApp(draft.sourceBundleID, name: draft.sourceAppName)
        } else {
            insertClip(from: draft)
        }
        try? context.save()
        historyChanged()
    }

    private func storeScreenshot(_ draft: ClipDraft) {
        store(draft)
        if let data = draft.imageData {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
            monitor.skipCurrentChange()
        }
        playSound("Bottle")
    }

    /// Inserts a new clip, keeping images too large to sync in this Mac's local store.
    @discardableResult
    func insertClip(from draft: ClipDraft, id: UUID? = nil) -> ClipItem {
        let item = ClipItem(draft: draft)
        if let id { item.id = id }
        if let data = draft.imageData, data.count > CloudSync.maxSyncedImageBytes {
            item.imageData = nil
            item.imageIsLocalOnly = true
            context.insert(LocalImage(clipID: item.id, data: data))
        }
        context.insert(item)
        addToTagIndex(item)
        publishSourceApp(draft.sourceBundleID, name: draft.sourceAppName)
        return item
    }

    /// Syncs a source app's icon and tint for devices without the app (the iPhone app draws
    /// card headers from these). Once per app per launch, and only for installed apps.
    private func publishSourceApp(_ bundleID: String?, name: String?) {
        guard CloudSync.isEnabled, let bundleID, publishedSourceApps.insert(bundleID).inserted,
              NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        else { return }
        var descriptor = FetchDescriptor<SourceApp>(predicate: #Predicate { $0.bundleID == bundleID })
        descriptor.fetchLimit = 1
        let tint = AppIcons.hex(for: bundleID)
        if let existing = try? context.fetch(descriptor).first {
            if existing.tintHex != tint { existing.tintHex = tint }
            if existing.iconData == nil { existing.iconData = AppIcons.pngData(for: bundleID) }
            if existing.name == nil, let name { existing.name = name }
        } else {
            context.insert(SourceApp(bundleID: bundleID, name: name, iconData: AppIcons.pngData(for: bundleID), tintHex: tint))
        }
    }

    /// Icons other Macs published, for apps that aren't installed here.
    private func useStoredAppIcons() {
        for app in (try? context.fetch(FetchDescriptor<SourceApp>())) ?? [] {
            AppIcons.useStoredIcon(for: app.bundleID, iconData: app.iconData, tintHex: app.tintHex)
        }
    }

    /// The same content copied on two devices (or by KlipLoft and KlipLoft Mini on one Mac) ends up as
    /// two clips. Keeps the newest of each, ties broken by ID so every device picks the same one,
    /// and folds the others' title, pinboard and keywords into it. Same rule as KlipLoft.
    func mergeDuplicates() {
        var descriptor = FetchDescriptor<ClipItem>()
        descriptor.propertiesToFetch = [\.contentHash, \.createdAt, \.id]
        guard let items = try? context.fetch(descriptor) else { return }
        let groups = Dictionary(grouping: items, by: \.contentHash).values.filter { $0.count > 1 }
        let ordered = groups.flatMap { group in
            group.map { ($0.createdAt, $0.id.uuidString, $0) }
                .sorted { ($0.0, $0.1) > ($1.0, $1.1) }
                .map(\.2)
        }
        var kept: [String: ClipItem] = [:]
        var merged = 0
        for item in ordered {
            guard let keeper = kept[item.contentHash] else {
                kept[item.contentHash] = item
                continue
            }
            if keeper.title == nil { keeper.title = item.title }
            if keeper.iconEmoji == nil { keeper.iconEmoji = item.iconEmoji }
            if keeper.pinboardID == nil, item.pinboardID != nil {
                keeper.pinboardID = item.pinboardID
                keeper.pinnedAt = item.pinnedAt
            }
            for keyword in item.keywords where !keeper.keywords.contains(keyword) {
                keeper.keywords.append(keyword)
            }
            if previewItemID == item.id { previewItemID = nil }
            context.delete(item)
            merged += 1
        }
        var keptApps: Set<String> = []
        let apps = ((try? context.fetch(FetchDescriptor<SourceApp>())) ?? []).sorted { $0.id.uuidString < $1.id.uuidString }
        for app in apps where !keptApps.insert(app.bundleID).inserted {
            context.delete(app)
            merged += 1
        }
        if merged > 0 { try? context.save() }
    }

    private func removeOrphanedLocalImages() {
        guard let images = try? context.fetch(FetchDescriptor<LocalImage>()), !images.isEmpty else { return }
        let ids = Set(((try? context.fetch(FetchDescriptor<ClipItem>(predicate: #Predicate { $0.imageIsLocalOnly }))) ?? []).map(\.id))
        let orphans = images.filter { !ids.contains($0.clipID) }
        guard !orphans.isEmpty else { return }
        let store = Self.storeDirectory.appending(path: "KlipLocal.store")
        SecureDelete.scrubLocalImages(orphans.map(\.clipID), store: store)
        for image in orphans { context.delete(image) }
        try? context.save()
        SecureDelete.checkpoint(store: store)
    }

    /// Overwrites the clips' content in the store before deleting them (see `SecureDelete`).
    private func deleteScrubbed(_ items: [ClipItem]) {
        try? context.save()
        let store = Self.storeDirectory.appending(path: "Klip.store")
        SecureDelete.scrubClips(items.map(\.id), store: store)
        for item in items {
            if previewItemID == item.id { previewItemID = nil }
            context.delete(item)
        }
        try? context.save()
        SecureDelete.checkpoint(store: store)
        removeOrphanedLocalImages()
        historyChanged()
    }

    func delete(_ item: ClipItem) { deleteScrubbed([item]) }

    /// Saves text edited in the preview; a link or color edited into plain text becomes text.
    func updateText(of item: ClipItem, to text: String) {
        guard item.text != text else { return }
        let draft = ClipDraft.text(text, rtf: nil, sourceBundleID: item.sourceBundleID, sourceAppName: item.sourceAppName)
        item.kindRaw = draft.kind.rawValue
        item.text = draft.text
        item.rtfData = nil
        item.contentHash = draft.contentHash
        try? context.save()
    }

    /// Saves the name given in the preview's title field; an empty one goes back to the automatic title.
    func updateTitle(of item: ClipItem, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle: String? = trimmed.isEmpty ? nil : trimmed
        guard item.title != newTitle else { return }
        item.title = newTitle
        try? context.save()
    }

    func item(withID id: UUID) -> ClipItem? {
        var descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func pruneHistory() {
        guard CloudSync.canPrune, let cutoff = HistoryCapacity.current.cutoff else { return }
        let predicate = #Predicate<ClipItem> { $0.pinboardID == nil && $0.createdAt < cutoff }
        guard let items = try? context.fetch(FetchDescriptor(predicate: predicate)), !items.isEmpty else { return }
        deleteScrubbed(items)
    }

    /// Unpinned clips a capacity would remove.
    func prunableCount(for capacity: HistoryCapacity) -> Int {
        guard let cutoff = capacity.cutoff else { return 0 }
        let descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.pinboardID == nil && $0.createdAt < cutoff })
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    /// Saves a new history capacity, asking first if it would delete clips.
    /// Returns false when the user cancels, leaving the capacity unchanged.
    func setHistoryCapacity(_ capacity: HistoryCapacity) -> Bool {
        let count = prunableCount(for: capacity)
        if count > 0 {
            let alert = NSAlert()
            alert.messageText = "Remove \(count.formatted()) clip\(count == 1 ? "" : "s")?"
            alert.informativeText = "Keeping history for a \(capacity.label.lowercased()) removes unpinned clips older than that, here and on your other devices. Pinned clips are kept. This can't be undone."
            alert.addButton(withTitle: "Remove Clips").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        UserDefaults.standard.set(capacity.rawValue, forKey: Prefs.historyCapacity)
        sync.pushCapacity(capacity)
        pruneHistory()
        return true
    }

    /// Direct paste on or off; turning it on asks for Accessibility.
    func setDirectPaste(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Prefs.directPaste)
        if enabled, !PasteService.isTrusted { PasteService.requestAccess() }
    }

    func refreshPermissionStatus() {
        let trusted = PasteService.isTrusted
        if trusted != accessibilityGranted { accessibilityGranted = trusted }
    }

    /// Unpinned clips copied since `cutoff`.
    private static func recentPredicate(since cutoff: Date) -> Predicate<ClipItem> {
        #Predicate { $0.pinboardID == nil && $0.createdAt >= cutoff }
    }

    func confirmClearRecentHistory() {
        panel.hide()
        NSApp.activate()
        let cutoff = Date.now.addingTimeInterval(-24 * 60 * 60)
        let items = (try? context.fetch(FetchDescriptor<ClipItem>(predicate: Self.recentPredicate(since: cutoff)))) ?? []
        let alert = NSAlert()
        guard !items.isEmpty else {
            alert.messageText = "Nothing to clear"
            alert.informativeText = "No unpinned items were copied in the last 24 hours."
            alert.runModal()
            return
        }
        let count = items.count
        alert.messageText = "Clear the last 24 hours?"
        alert.informativeText = "The \(count) \(count == 1 ? "item" : "items") copied in the last 24 hours will be removed. Pinned items and pinboards are kept."
        alert.addButton(withTitle: "Clear \(count) \(count == 1 ? "Item" : "Items")").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { deleteScrubbed(items) }
    }

    /// Unpinned image clips: all of them, or those copied since `cutoff`.
    private static func imagePredicate(since cutoff: Date?) -> Predicate<ClipItem> {
        let image = ClipKind.image.rawValue
        if let cutoff {
            return #Predicate { $0.pinboardID == nil && $0.kindRaw == image && $0.createdAt >= cutoff }
        }
        return #Predicate { $0.pinboardID == nil && $0.kindRaw == image }
    }

    /// Clear Images: removes only unpinned images, with the space they free.
    func confirmClearImages(lastDay: Bool) {
        panel.hide()
        NSApp.activate()
        let cutoff = lastDay ? Date.now.addingTimeInterval(-24 * 60 * 60) : nil
        let items = (try? context.fetch(FetchDescriptor<ClipItem>(predicate: Self.imagePredicate(since: cutoff)))) ?? []
        let alert = NSAlert()
        guard !items.isEmpty else {
            alert.messageText = "Nothing to clear"
            alert.informativeText = lastDay ? "No unpinned images were copied in the last 24 hours." : "There are no unpinned images in your history."
            alert.runModal()
            return
        }
        let bytes = items.reduce(0) { $0 + ($1.imagePayload?.count ?? 0) }
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let count = items.count
        alert.messageText = lastDay ? "Clear images from the last 24 hours?" : "Clear all images?"
        alert.informativeText = "The \(count) \(count == 1 ? "image" : "images") will be removed, freeing about \(size). Text, pinned items and pinboards are kept."
        alert.addButton(withTitle: "Clear \(count) \(count == 1 ? "Image" : "Images")").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { deleteScrubbed(items) }
    }

    func confirmClearHistory() {
        panel.hide()
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "Every clip that isn't pinned is removed here and on your other devices. Pinboards are kept."
        alert.addButton(withTitle: "Clear History").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let items = (try? context.fetch(FetchDescriptor<ClipItem>(predicate: #Predicate { $0.pinboardID == nil }))) ?? []
        deleteScrubbed(items)
    }

    func syncNow() { sync.syncNow(saving: context) }

    // MARK: List

    func pinboards() -> [Pinboard] {
        ((try? context.fetch(FetchDescriptor<Pinboard>(sortBy: [SortDescriptor(\.order)]))) ?? []).uniqueByID
    }

    func pinboard(withID id: UUID) -> Pinboard? {
        pinboards().first { $0.id == id }
    }

    /// Clips loaded per page of the list; more load as the list scrolls near its end.
    private static let pageSize = 60
    /// How many clips the list has loaded so far (one or more pages).
    @ObservationIgnored private var loadedLimit = pageSize
    /// The database has more clips past the loaded pages.
    @ObservationIgnored private var hasMoreRows = false
    /// The list went stale while the panel was closed; refreshed when it opens.
    @ObservationIgnored private var listIsStale = false
    /// Clips with keywords or files, which the database can't search inside (they're stored as
    /// arrays): their words, kept small, and searched in memory. Built on the first search after
    /// the panel opens or the history changes.
    @ObservationIgnored private var tagIndex: [(id: UUID, kindRaw: String, bundleID: String?, words: [String])]?

    /// Rebuilds `rows` for the current mode and search, from the first page. While the panel is
    /// closed nothing is read; the list is rebuilt when it opens (`force`).
    func refresh(force: Bool = false) {
        if !force, let panel, !panel.isVisible {
            listIsStale = true
            return
        }
        listIsStale = false
        loadedLimit = Self.pageSize
        reload()
    }

    /// The history changed (a copy, a delete): the list is out of date. The keyword index keeps
    /// up by itself (`addToTagIndex`); a deleted clip left in it simply isn't found.
    func historyChanged() {
        refresh()
    }

    /// Builds the keyword index now (at launch, after an iCloud import), so the first search
    /// after a copy doesn't pay for it.
    func rebuildTagIndex() {
        tagIndex = nil
        _ = tags()
    }

    func warmUpSearch() {
        rebuildTagIndex()
        let probe = "\u{1}"
        _ = try? context.fetchCount(FetchDescriptor<ClipItem>(predicate: #Predicate { $0.text?.localizedStandardContains(probe) == true }))
    }

    /// A new or changed clip with keywords or files joins the keyword index.
    func addToTagIndex(_ item: ClipItem) {
        guard tagIndex != nil else { return }
        let words = item.keywords + item.filePaths.map { ($0 as NSString).lastPathComponent }
        tagIndex?.removeAll { $0.id == item.id }
        if !words.isEmpty { tagIndex?.append((item.id, item.kindRaw, item.sourceBundleID, words)) }
    }

    /// A row near the end of the loaded pages appeared: load the next page.
    func rowAppeared(at index: Int) {
        guard hasMoreRows, index >= rows.count - 15 else { return }
        loadedLimit += Self.pageSize
        reload()
    }

    private func reload() {
        let text = query.trimmingCharacters(in: .whitespaces)
        let boards = pinboards()
        pinboardColors = Dictionary(boards.map { ($0.id, $0.color) }, uniquingKeysWith: { first, _ in first })
        pinboardNames = Dictionary(boards.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        switch mode {
        case .recent:
            rows = searchHistory(text).map(Row.clip)
        case .pinboards:
            hasMoreRows = false
            defer { matchCount = text.isEmpty ? nil : rows.count }
            var descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.pinboardID != nil })
            descriptor.propertiesToFetch = [\.pinboardID]
            let pinned = (try? context.fetch(descriptor)) ?? []
            let counts = Dictionary(grouping: pinned, by: \.pinboardID).mapValues(\.count)
            rows = boards
                .filter { text.isEmpty || $0.name.localizedStandardContains(text) }
                .map { Row.pinboard($0, count: counts[$0.id] ?? 0) }
        case .pinboard(let id):
            // A pinboard is small: read it whole and search it in memory.
            hasMoreRows = false
            defer { matchCount = text.isEmpty && searchFilters.isEmpty ? nil : rows.count }
            let boardID: UUID? = id
            let descriptor = FetchDescriptor<ClipItem>(
                predicate: #Predicate { $0.pinboardID == boardID },
                sortBy: [SortDescriptor(\.pinnedAt, order: .reverse)]
            )
            rows = ((try? context.fetch(descriptor)) ?? [])
                .filter { $0.matches(query: text, filters: searchFilters) }
                .map(Row.clip)
        }
        if selectedIndex >= rows.count { selectedIndex = max(0, rows.count - 1) }
        if let previewItemID, !rows.contains(where: { $0.id == previewItemID }) { self.previewItemID = nil }
    }

    /// The history, newest first, up to the loaded pages: everything, or what matches the search
    /// and filters. The database does the matching on titles, text and app names (only the rows
    /// that match are read); keywords and file names come from `tagIndex`.
    private func searchHistory(_ text: String) -> [ClipItem] {
        var kinds: [String] = []
        var apps: [String] = []
        for filter in searchFilters {
            switch filter {
            case .kind(let kind): kinds.append(kind.rawValue)
            case .app(let bundleID, _): apps.append(bundleID)
            }
        }
        let anyKind = kinds.isEmpty
        let anyApp = apps.isEmpty
        // Typing a type's name ("link") finds clips of that type, as in KlipLoft.
        let namedKinds = text.isEmpty ? [] : ClipKind.allCases.filter { $0.title.localizedStandardContains(text) }.map(\.rawValue)

        // In parts: one predicate is too much for the compiler. The database runs them as one query.
        let filterMatch = #Predicate<ClipItem> { item in
            (anyKind || kinds.contains(item.kindRaw)) && (anyApp || item.sourceBundleID.flatMap { apps.contains($0) } == true)
        }
        let textMatch = #Predicate<ClipItem> { item in
            item.title?.localizedStandardContains(text) == true || item.text?.localizedStandardContains(text) == true
        }
        let otherMatch = #Predicate<ClipItem> { item in
            item.sourceAppName?.localizedStandardContains(text) == true || namedKinds.contains(item.kindRaw)
        }
        let predicate = text.isEmpty ? filterMatch : #Predicate<ClipItem> { item in
            filterMatch.evaluate(item) && (textMatch.evaluate(item) || otherMatch.evaluate(item))
        }
        var descriptor = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = loadedLimit + 1
        var items = (try? context.fetch(descriptor)) ?? []
        hasMoreRows = items.count > loadedLimit
        items = Array(items.prefix(loadedLimit))
        // The total for the chip: counted in the database only when there's more than one page.
        let searching = !text.isEmpty || !searchFilters.isEmpty
        var total = !searching ? nil : hasMoreRows ? ((try? context.fetchCount(FetchDescriptor(predicate: predicate))) ?? items.count) : items.count
        defer { matchCount = total }
        guard !text.isEmpty else { return items }

        // Keyword and file-name matches the database couldn't see.
        let found = Set(items.map(\.id))
        let extra = tags().filter { entry in
            !found.contains(entry.id)
                && (anyKind || kinds.contains(entry.kindRaw)) && (anyApp || apps.contains(entry.bundleID ?? ""))
                && entry.words.contains { $0.localizedStandardContains(text) }
        }.map(\.id)
        guard !extra.isEmpty else { return items }
        total = (total ?? 0) + extra.count
        let extraItems = (try? context.fetch(FetchDescriptor<ClipItem>(predicate: #Predicate { extra.contains($0.id) }))) ?? []
        return Array((items + extraItems).sorted { $0.createdAt > $1.createdAt }.prefix(loadedLimit))
    }

    /// Builds `tagIndex` if needed: only clips with keywords or files, and only those columns.
    private func tags() -> [(id: UUID, kindRaw: String, bundleID: String?, words: [String])] {
        if let tagIndex { return tagIndex }
        var descriptor = FetchDescriptor<ClipItem>()
        descriptor.propertiesToFetch = [\.id, \.kindRaw, \.sourceBundleID, \.keywords, \.filePaths]
        let index = ((try? context.fetch(descriptor)) ?? []).compactMap { item -> (id: UUID, kindRaw: String, bundleID: String?, words: [String])? in
            let words = item.keywords + item.filePaths.map { ($0 as NSString).lastPathComponent }
            return words.isEmpty ? nil : (item.id, item.kindRaw, item.sourceBundleID, words)
        }
        tagIndex = index
        return index
    }

    /// Adds a filter chip, or takes it out if it's there.
    func toggleFilter(_ filter: SearchFilter) {
        if let index = searchFilters.firstIndex(of: filter) {
            searchFilters.remove(at: index)
        } else {
            searchFilters.append(filter)
        }
        focusToken += 1
    }

    /// ⌫ on an empty search: the first marks the last chip, the next removes it. A held-down ⌫
    /// stops at the mark. Returns false when there's no chip, so ⌫ can do its other jobs.
    func deleteBackwardOverChips(isRepeat: Bool) -> Bool {
        guard query.isEmpty, let last = searchFilters.last else { return false }
        if markedFilter == last {
            if !isRepeat { searchFilters.removeLast() }
        } else {
            markedFilter = last
        }
        return true
    }

    /// The apps clips came from, most frequent first.
    func sourceApps(limit: Int = 15) -> [(bundleID: String, name: String)] {
        var descriptor = FetchDescriptor<ClipItem>()
        descriptor.propertiesToFetch = [\.sourceBundleID, \.sourceAppName]
        let items = (try? context.fetch(descriptor)) ?? []
        var counts: [String: Int] = [:]
        var names: [String: String] = [:]
        for item in items {
            guard let bundleID = item.sourceBundleID else { continue }
            counts[bundleID, default: 0] += 1
            if names[bundleID] == nil, let name = item.sourceAppName { names[bundleID] = name }
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map { bundleID, _ in
            let name = names[bundleID]
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                    .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
                ?? bundleID
            return (bundleID, name)
        }
    }

    var selectedRow: Row? { rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil }

    func moveSelection(_ offset: Int) {
        guard !rows.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + offset), rows.count - 1)
        // The preview follows the selection while it's open.
        if previewItemID != nil, case .clip(let item) = selectedRow { previewItemID = item.id }
    }

    /// The pin button: recent ⇄ pinboards; inside a pinboard it goes back to the list of pinboards.
    func togglePinboards() {
        previewItemID = nil
        query = ""
        mode = mode == .recent ? .pinboards : .recent
    }

    /// Esc steps back: preview, then search text, then out of a pinboard, then closes.
    func escape() {
        if previewItemID != nil {
            previewItemID = nil
        } else if !query.isEmpty {
            query = ""
        } else if !searchFilters.isEmpty {
            searchFilters = []
        } else if case .pinboard = mode {
            mode = .pinboards
        } else if mode == .pinboards {
            mode = .recent
        } else {
            panel.hide()
        }
    }

    /// Return or a click: pastes a clip, opens a pinboard.
    func activate(_ row: Row) {
        switch row {
        case .clip(let item): paste(item)
        case .pinboard(let board, _):
            query = ""
            mode = .pinboard(board.id)
        }
    }

    func togglePreview(_ item: ClipItem) {
        if let index = rows.firstIndex(where: { $0.id == item.id }) { selectedIndex = index }
        previewItemID = previewItemID == item.id ? nil : item.id
    }

    func prepareForShow() {
        mouseActive = false
        lastMouseLocation = NSEvent.mouseLocation
        previewItemID = nil
        query = ""
        searchFilters = []
        // After the panel is on screen: it reads every clip's app.
        DispatchQueue.main.async { self.filterApps = self.sourceApps() }
        mode = .recent
        selectedIndex = 0
        refresh(force: true)
        focusToken += 1
    }

    // MARK: Paste

    func paste(_ item: ClipItem, plainText: Bool = false) {
        writeToPasteboard(item, plainText: plainText || UserDefaults.standard.bool(forKey: Prefs.alwaysPlainText))
        panel.hide()
        guard UserDefaults.standard.bool(forKey: Prefs.directPaste), PasteService.isTrusted else {
            if UserDefaults.standard.bool(forKey: Prefs.directPaste) { PasteService.requestAccess() }
            showToast("Copied · press ⌘V to paste", symbol: "doc.on.clipboard")
            return
        }
        playSound("Pop")
        // The panel never activates the app, so the app underneath is still in front.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            PasteService.sendPasteKeystroke()
        }
    }

    func copy(_ item: ClipItem) {
        writeToPasteboard(item, plainText: false)
        panel.hide()
        showToast("Copied", symbol: "doc.on.clipboard")
    }

    /// Opens a link clip in the default browser; a bare "example.com" is opened as https.
    func openInBrowser(_ item: ClipItem) {
        guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              let parsed = URL(string: text) else { return }
        guard let url = parsed.scheme == nil ? URL(string: "https://" + text) : parsed else { return }
        panel.hide()
        NSWorkspace.shared.open(url)
    }

    private func writeToPasteboard(_ item: ClipItem, plainText: Bool) {
        PasteService.write(item, plainText: plainText)
        monitor.skipCurrentChange()
        item.createdAt = .now
        try? context.save()
    }

    // MARK: Pinboards

    func pin(_ item: ClipItem, to board: Pinboard) {
        item.pinboardID = board.id
        item.pinnedAt = .now
        try? context.save()
        refresh()
    }

    func unpin(_ item: ClipItem) {
        item.pinboardID = nil
        item.pinnedAt = nil
        try? context.save()
        refresh()
    }

    @discardableResult
    func createPinboard(named name: String) -> Pinboard {
        let existing = pinboards()
        let board = Pinboard(name: name, colorIndex: existing.count % Pinboard.palette.count, order: (existing.last?.order ?? -1) + 1)
        context.insert(board)
        try? context.save()
        refresh()
        return board
    }

    /// Records that a clip's title, keywords or icon changed now (see `ClipEdit`).
    func noteEdited(_ item: ClipItem, at date: Date = .now) {
        let id = item.id
        var descriptor = FetchDescriptor<ClipEdit>(predicate: #Predicate { $0.clipID == id })
        descriptor.fetchLimit = 1
        if let edit = try? context.fetch(descriptor).first {
            edit.editedAt = date
        } else {
            context.insert(ClipEdit(clipID: id, editedAt: date))
        }
    }

    // MARK: Windows

    func showToast(_ text: String, symbol: String) {
        Toast.show(text, symbol: symbol)
    }

    /// Opens Settings, on `page` if given (else wherever it was left). The app has no Dock icon,
    /// so it's activated past other apps and the window ordered front regardless, as in KlipLoft.
    func showSettings(page: SettingsPage? = nil) {
        panel.hide()
        if preferences == nil {
            preferences = PreferencesWindowController(model: self)
            preferences?.window?.center()
        }
        if let page { preferences?.navigation.page = page }
        NSApp.activate(ignoringOtherApps: true)
        preferences?.showWindow(nil)
        preferences?.window?.orderFrontRegardless()
        preferences?.window?.makeKey()
    }

    /// The standard About panel, brought in front like Settings.
    func showAbout() {
        panel.hide()
        NSApp.activate(ignoringOtherApps: true)
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "KlipLoft Mini"
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: name])
    }

    private func playSound(_ name: NSSound.Name) {
        guard UserDefaults.standard.bool(forKey: Prefs.soundEffects) else { return }
        NSSound(named: name)?.play()
    }
}
