import Foundation
import ImageIO
import SwiftData
import Vision

/// Text read from an image clip (screenshots, copied pictures), shown under Text Found in the
/// preview, copied with Copy Text, and found by search. An empty `text` means the image was read
/// and has none, so it isn't read again.
@Model
final class ImageText {
    var clipID: UUID = UUID()
    var text: String = ""

    init(clipID: UUID, text: String) {
        self.clipID = clipID
        self.text = text
    }
}

/// Reads the text in image clips with Vision, one image at a time off the main thread, and keeps
/// it in its own store, KlipText.store, on this Mac only. Each Mac reads its own images, including
/// the ones iCloud brings in.
///
/// The store has a container of its own, apart from `AppModel.container`: every store in a container
/// records the whole model, so a new type there would change Klip.store and KlipLocal.store, and an
/// older KlipLoft (or KlipLoft Go and Mini through iCloud) couldn't open or sync them. Here they stay
/// as they were: an older version installed on top simply never opens KlipText.store, and after
/// updating again the images it added are read and the clips it deleted are dropped (`scanHistory`,
/// `removeOrphans`).
@Observable
final class ImageTextIndex {
    /// Text found in each image clip, by clip ID; images without text aren't listed. Kept in memory
    /// for search and the card menu.
    private(set) var texts: [UUID: String] = [:]

    @ObservationIgnored private let container: ModelContainer?
    @ObservationIgnored private let storeURL: URL
    /// Every image already read, with or without text.
    @ObservationIgnored private var read: Set<UUID> = []
    /// Images Vision failed on this launch (as it does in a virtual machine, or under memory
    /// pressure). Nothing is saved for them, so the next launch tries again.
    @ObservationIgnored private var failed: Set<UUID> = []
    /// Images waiting to be read, next first, with their bytes when already at hand. Urgent ones
    /// (just copied, or opened in the preview) are read even while the backfill is paused.
    @ObservationIgnored private var queue: [(id: UUID, data: Data?, urgent: Bool)] = []
    @ObservationIgnored private var queued: Set<UUID> = []
    /// The image being read right now, and whether its clip was deleted meanwhile.
    @ObservationIgnored private var reading: UUID?
    @ObservationIgnored private var readingDeleted = false
    /// Results not saved yet: a backfill saves every few images, not after each one.
    @ObservationIgnored private var unsaved = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Called with each clip whose text was found, so an open search can take it in.
    @ObservationIgnored var onFound: ((UUID) -> Void)?
    /// Reads a clip's image bytes (synced or local-only) when it's its turn.
    @ObservationIgnored var imageData: ((UUID) -> Data?)?

    /// The image being read and how many launches have tried it ("<uuid> <attempts>"), saved before
    /// each read. Still set at launch means the app quit or crashed while reading it.
    private static let readingKey = "imageTextReading"
    /// After this many launches that ended while reading the same image, it's given up on, so an
    /// image that crashes Vision can't crash KlipLoft at every launch. Two, because quitting during
    /// the backfill also leaves the mark.
    private static let maxAttempts = 2
    /// Larger images are scaled down to this many pixels before reading, which keeps Vision's memory
    /// in check; Vision gains nothing from more, and screenshots of even a 6K display (20 MP) are
    /// read at full size.
    nonisolated private static let maxPixels = 30_000_000.0

    private var context: ModelContext? { container?.mainContext }

    /// The backfill waits while the Mac saves power or runs hot; new copies are still read.
    private var backfillPaused: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    init(directory: URL) {
        storeURL = directory.appending(path: "KlipText.store")
        // Opened before AppModel's container, which otherwise makes the folder on a new install.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        container = Self.openContainer(at: storeURL)
        for entry in (try? container?.mainContext.fetch(FetchDescriptor<ImageText>())) ?? [] {
            read.insert(entry.clipID)
            if !entry.text.isEmpty { texts[entry.clipID] = entry.text }
        }
        giveUpOnCrashedImage()
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.readNext() }
            })
        }
    }

    /// The store, or a new empty one when it can't be opened (say, one a newer KlipLoft changed and
    /// this one can't read): everything in it can be read from the images again. Nil only if even
    /// a new store fails, which turns the feature off; KlipLoft still runs.
    private static func openContainer(at url: URL) -> ModelContainer? {
        let configuration = ModelConfiguration("Text", schema: Schema([ImageText.self]), url: url, cloudKitDatabase: .none)
        if let container = try? ModelContainer(for: ImageText.self, configurations: configuration) { return container }
        let folder = url.deletingLastPathComponent()
        for name in ["KlipText.store", "KlipText.store-wal", "KlipText.store-shm", ".KlipText_SUPPORT"] {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
        return try? ModelContainer(for: ImageText.self, configurations: configuration)
    }

    /// Counts for the support report, never the text itself.
    var status: String {
        guard container != nil else { return "store couldn't be opened" }
        let waiting = "\(queue.count + (reading == nil ? 0 : 1)) waiting"
        let failures = failed.isEmpty ? "" : ", \(failed.count) failed"
        return "\(read.count) read, \(texts.count) with text, \(waiting)\(failures)" + (backfillPaused ? " (paused: Low Power Mode or heat)" : "")
    }

    func text(for id: UUID) -> String? {
        texts[id]
    }

    /// Clip IDs whose image text contains `query`.
    func matches(_ query: String) -> [UUID] {
        texts.compactMap { $0.value.localizedStandardContains(query) ? $0.key : nil }
    }

    /// Queues an image. `first` reads it next, ahead of the backfill, even while that's paused.
    func enqueue(_ id: UUID, data: Data?, first: Bool = false) {
        guard container != nil, !read.contains(id), !failed.contains(id) else { return }
        if queued.contains(id) {
            guard first, let index = queue.firstIndex(where: { $0.id == id }) else { return }
            let entry = queue.remove(at: index)
            queue.insert((id, data ?? entry.data, true), at: 0)
        } else {
            queued.insert(id)
            if first { queue.insert((id, data, true), at: 0) } else { queue.append((id, data, false)) }
        }
        readNext()
    }

    /// Queues every image clip not read yet, newest first: images from before this feature, from
    /// iCloud, and from an older KlipLoft that ran in between.
    func scanHistory(in clips: ModelContext) {
        guard container != nil else { return }
        let image = ClipKind.image.rawValue
        var descriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.kindRaw == image },
                                                   sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.propertiesToFetch = [\.id]
        for item in (try? clips.fetch(descriptor)) ?? [] where !read.contains(item.id) {
            enqueue(item.id, data: nil)
        }
    }

    /// Blanks and deletes the text of deleted clips (see `SecureDelete`).
    func remove(_ ids: [UUID]) {
        guard let context else { return }
        if let reading, ids.contains(reading) { readingDeleted = true }
        let gone = ids.filter { read.contains($0) || queued.contains($0) }
        guard !gone.isEmpty else { return }
        queue.removeAll { gone.contains($0.id) }
        for id in gone {
            texts[id] = nil
            read.remove(id)
            queued.remove(id)
        }
        let set = Set(gone)
        let entries = ((try? context.fetch(FetchDescriptor<ImageText>())) ?? []).filter { set.contains($0.clipID) }
        guard !entries.isEmpty else { return }
        try? context.save()
        SecureDelete.scrubImageTexts(entries.map(\.clipID), store: storeURL)
        for entry in entries { context.delete(entry) }
        try? context.save()
        unsaved = 0
        SecureDelete.checkpoint(store: storeURL)
    }

    /// Text whose clip is gone, deleted here, on another device, or by an older KlipLoft.
    func removeOrphans(keeping clipIDs: Set<UUID>) {
        remove(Array(read.subtracting(clipIDs)))
    }

    // MARK: -

    /// The mark left by the last launch, if it ended while reading an image.
    private static func crashMark() -> (id: UUID, attempts: Int)? {
        let parts = UserDefaults.standard.string(forKey: readingKey)?.split(separator: " ") ?? []
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])), let attempts = Int(parts[1]) else { return nil }
        return (id, attempts)
    }

    /// An image that was being read when the last launches ended too often is saved as having no
    /// text, so it's never read again.
    private func giveUpOnCrashedImage() {
        guard let mark = Self.crashMark(), mark.attempts >= Self.maxAttempts else { return }
        UserDefaults.standard.removeObject(forKey: Self.readingKey)
        guard let context, !read.contains(mark.id) else { return }
        read.insert(mark.id)
        context.insert(ImageText(clipID: mark.id, text: ""))
        try? context.save()
    }

    private func readNext() {
        guard reading == nil else { return }
        // Skips images with no bytes on this Mac (still downloading, or too large to sync from
        // another Mac); they're tried again on the next scan.
        var next: (id: UUID, data: Data?, urgent: Bool)?
        var data: Data?
        while data == nil, let first = queue.first, first.urgent || !backfillPaused {
            queue.removeFirst()
            queued.remove(first.id)
            next = first
            data = first.data ?? imageData?(first.id)
        }
        guard let next, let data else {
            if unsaved > 0 { save() }
            return
        }
        reading = next.id
        readingDeleted = false
        let attempts = Self.crashMark().flatMap { $0.id == next.id ? $0.attempts : nil } ?? 0
        UserDefaults.standard.set("\(next.id.uuidString) \(attempts + 1)", forKey: Self.readingKey)
        // The backfill yields to everything else; a new copy is read sooner.
        Task(priority: next.urgent ? .userInitiated : .utility) {
            let text = try? await Self.recognize(data)
            finish(next.id, text: text)
        }
    }

    /// `text` is nil when Vision failed: the image isn't marked read, so it isn't taken for one
    /// without text.
    private func finish(_ id: UUID, text: String?) {
        UserDefaults.standard.removeObject(forKey: Self.readingKey)
        let deleted = readingDeleted
        reading = nil
        readingDeleted = false
        if text == nil, !deleted { failed.insert(id) }
        if let context, let text, !deleted, !read.contains(id) {
            read.insert(id)
            context.insert(ImageText(clipID: id, text: text))
            unsaved += 1
            if !text.isEmpty {
                texts[id] = text
                onFound?(id)
            }
        }
        if unsaved >= 20 { save() }
        readNext()
    }

    private func save() {
        try? context?.save()
        unsaved = 0
    }

    /// The image's text, paragraph by paragraph, with Vision's document reader (macOS 26), which
    /// keeps the lines of a paragraph together rather than listing each line on its own; then what
    /// any QR codes or barcodes in it hold (a link, Wi-Fi details), unless the text already says it.
    /// `@concurrent` so it runs off the main actor, not on the caller's.
    @concurrent nonisolated static func recognize(_ data: Data) async throws -> String {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        request.textRecognitionOptions.useLanguageCorrection = true
        request.barcodeDetectionOptions.enabled = true
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return "" }
        // Most images go to Vision as they are, which decodes them more frugally than a bitmap made
        // here, with their orientation tag: a photo taken upright is stored on its side, and read
        // sideways Vision finds little in it. A scaled-down image is already turned upright.
        let observations = if let image = scaledDownImage(source, properties: properties) {
            try await request.perform(on: image)
        } else {
            try await request.perform(on: data, orientation: orientation(properties))
        }
        var lines = observations.flatMap { observation in
            let document = observation.document
            let found = document.paragraphs.map(\.transcript)
            return found.isEmpty ? [document.text.transcript] : found
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        let text = lines.joined(separator: "\n")
        for observation in observations {
            for barcode in observation.document.barcodes {
                guard let payload = barcode.payloadString?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !payload.isEmpty, !text.contains(payload), !lines.contains(payload)
                else { continue }
                lines.append(payload)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The image's EXIF orientation, or nil when it has none (read as upright).
    nonisolated private static func orientation(_ properties: [CFString: Any]) -> CGImagePropertyOrientation? {
        (properties[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init(rawValue:))
    }

    /// An image over `maxPixels` scaled down to it (keeping its shape, so a long scrolling screenshot
    /// stays readable), upright per its orientation; nil for any image small enough to read as is.
    nonisolated private static func scaledDownImage(_ source: CGImageSource, properties: [CFString: Any]) -> CGImage? {
        guard let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width * height > maxPixels
        else { return nil }
        let scale = (maxPixels / (width * height)).squareRoot()
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int((max(width, height) * scale).rounded()),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
