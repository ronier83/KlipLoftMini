import AppKit
import CryptoKit
import Foundation
import ImageIO
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

nonisolated enum ClipKind: String, CaseIterable, Sendable {
    case text, link, image, file, color

    var title: String {
        switch self {
        case .text: "Text"
        case .link: "Link"
        case .image: "Image"
        case .file: "File"
        case .color: "Color"
        }
    }

    /// Kinds backed by a string, which can be pasted as plain text and edited.
    var isTextual: Bool { self == .text || self == .link || self == .color }

    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .color: "paintpalette"
        }
    }
}

extension Array where Element == Pinboard {
    /// iCloud can import one pinboard twice: two copies with the same ID. Deleting either copy
    /// isn't safe (another device may delete the other one, and then both are gone), so the
    /// copies are kept, edited together, and listed once.
    var uniqueByID: [Pinboard] {
        var seen: Set<UUID> = []
        return filter { seen.insert($0.id).inserted }
    }
}

extension Array where Element == UUID {
    /// The IDs from `start` through `end` in either direction, for a ⇧ range selection;
    /// just `end` when `start` is no longer listed.
    func span(from start: UUID, to end: UUID) -> Set<UUID> {
        guard let first = firstIndex(of: start), let last = firstIndex(of: end) else { return [end] }
        return Set(self[Swift.min(first, last)...Swift.max(first, last)])
    }
}

/// A filter chip in the search bar: a clip type or a source app.
enum SearchFilter: Hashable {
    case kind(ClipKind)
    case app(bundleID: String, name: String)

    var title: String {
        switch self {
        case .kind(let kind): kind.title
        case .app(_, let name): name
        }
    }
}

extension ClipItem {
    /// Whether the clip matches a search: any of the chosen types, from any of the chosen apps,
    /// and containing the query in its title, keywords, text, file names, app or type.
    /// Shared by the panel and the menu bar so both find the same clips.
    func matches(query: String, filters: [SearchFilter]) -> Bool {
        var kinds: [ClipKind] = []
        var apps: [String] = []
        for filter in filters {
            switch filter {
            case .kind(let kind): kinds.append(kind)
            case .app(let bundleID, _): apps.append(bundleID)
            }
        }
        guard kinds.isEmpty || kinds.contains(kind),
              apps.isEmpty || apps.contains(sourceBundleID ?? "")
        else { return false }
        guard !query.isEmpty else { return true }
        return (title?.localizedStandardContains(query) ?? false)
            || keywords.contains { $0.localizedStandardContains(query) }
            || (text?.localizedStandardContains(query) ?? false)
            || filePaths.contains { ($0 as NSString).lastPathComponent.localizedStandardContains(query) }
            || (sourceAppName?.localizedStandardContains(query) ?? false)
            || kind.title.localizedStandardContains(query)
    }
}

@Model
final class ClipItem {
    #Index<ClipItem>([\.createdAt], [\.contentHash], [\.pinboardID])

    // CloudKit sync needs every property to be optional or have a default, and no unique
    // constraints; duplicates from other devices are merged by AppModel.mergeDuplicates().
    var id: UUID = UUID()
    var createdAt: Date = Date.now
    var kindRaw: String = ClipKind.text.rawValue
    var text: String?
    @Attribute(.externalStorage) var rtfData: Data?
    @Attribute(.externalStorage) var imageData: Data?
    var imageWidth: Int = 0
    var imageHeight: Int = 0
    var filePaths: [String] = []
    var sourceBundleID: String?
    var sourceAppName: String?
    var contentHash: String = ""
    /// Pinned items live on one pinboard and are never pruned from history.
    var pinboardID: UUID?
    var pinnedAt: Date?
    /// A name the user gave the clip (e.g. "SendBox"), shown in place of the clip type.
    var title: String?
    /// Link previews: the page's title and image, fetched once when the card is first shown.
    var linkTitle: String?
    @Attribute(.externalStorage) var linkImageData: Data?
    var linkPreviewFetched: Bool = false
    /// Extra words the clip can be found by in search; shown and edited only in the preview.
    var keywords: [String] = []
    /// An emoji the user chose to show in place of the source app's icon (pinned clips only).
    var iconEmoji: String?

    /// The emoji to draw instead of the app icon: only while the clip is pinned (it can be
    /// unpinned on a device that doesn't know about emoji), and only a single emoji, since
    /// the value can come from a .klip file or another device.
    var shownIconEmoji: String? {
        guard pinboardID != nil, let emoji = iconEmoji, ClipItem.isValidIcon(emoji) else { return nil }
        return emoji
    }

    /// One character that renders as an emoji.
    static func isValidIcon(_ value: String) -> Bool {
        guard value.count == 1, let scalar = value.unicodeScalars.first else { return false }
        return scalar.properties.isEmojiPresentation || value.unicodeScalars.count > 1 && scalar.properties.isEmoji
    }
    /// The image was too large to sync, so its data lives in a `LocalImage` on the Mac that copied it.
    var imageIsLocalOnly: Bool = false

    init(draft: ClipDraft) {
        id = UUID()
        createdAt = .now
        kindRaw = draft.kind.rawValue
        text = draft.text
        rtfData = draft.rtfData
        imageData = draft.imageData
        imageWidth = draft.imageWidth
        imageHeight = draft.imageHeight
        filePaths = draft.filePaths
        sourceBundleID = draft.sourceBundleID
        sourceAppName = draft.sourceAppName
        contentHash = draft.contentHash
    }
}

extension ClipItem {
    var kind: ClipKind { ClipKind(rawValue: kindRaw) ?? .text }

    /// The custom title if there is one, otherwise the clip type ("Text", "3 Files").
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if kind == .file, filePaths.count > 1 { return "\(filePaths.count) Files" }
        return kind.title
    }

    var fileURLs: [URL] { filePaths.map { URL(fileURLWithPath: $0) } }

    /// The image bytes, whether synced on the clip or kept in this Mac's local store.
    var imagePayload: Data? {
        if let imageData { return imageData }
        guard imageIsLocalOnly, let context = modelContext else { return nil }
        let id = id
        var descriptor = FetchDescriptor<LocalImage>(predicate: #Predicate { $0.clipID == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first)?.data
    }

    var footerText: String {
        switch kind {
        case .link:
            return (text ?? "").replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        case .text:
            let count = text?.count ?? 0
            return "\(count.formatted()) character\(count == 1 ? "" : "s")"
        case .image:
            return "\(imageWidth) × \(imageHeight) pixels" + (imageIsLocalOnly ? " · not synced" : "")
        case .file:
            return filePaths.count == 1 ? "1 file" : "\(filePaths.count) files"
        case .color:
            return text?.uppercased() ?? ""
        }
    }
}

/// Image bytes too large to sync (over `CloudSync.maxSyncedImageBytes`). Lives in a
/// separate store that never leaves this Mac.
@Model
final class LocalImage {
    var clipID: UUID = UUID()
    @Attribute(.externalStorage) var data: Data?

    init(clipID: UUID, data: Data) {
        self.clipID = clipID
        self.data = data
    }
}

/// When a clip's title, keywords or icon were last changed on this Mac. Saved in .klip files,
/// so importing one again can tell whose version is newer. Kept in the local store: a new
/// field on `ClipItem` would need deploying to the production CloudKit schema first.
@Model
final class ClipEdit {
    var clipID: UUID = UUID()
    var editedAt: Date = Date.now

    init(clipID: UUID, editedAt: Date) {
        self.clipID = clipID
        self.editedAt = editedAt
    }
}

/// A source app's icon and header color, published for devices that can't look the app up
/// themselves: the iPhone app draws card headers from these.
@Model
final class SourceApp {
    var id: UUID = UUID()
    var bundleID: String = ""
    var name: String?
    @Attribute(.externalStorage) var iconData: Data?
    /// The header tint as "#RRGGBB".
    var tintHex: String = ""

    init(bundleID: String, name: String?, iconData: Data?, tintHex: String) {
        id = UUID()
        self.bundleID = bundleID
        self.name = name
        self.iconData = iconData
        self.tintHex = tintHex
    }
}

@Model
final class Pinboard {
    var id: UUID = UUID()
    var name: String = ""
    var colorIndex: Int = 0
    var order: Int = 0

    init(name: String, colorIndex: Int, order: Int) {
        id = UUID()
        self.name = name
        self.colorIndex = colorIndex
        self.order = order
    }
}

extension Pinboard {
    static let palette: [(name: String, color: Color)] = [
        ("Blue", .blue), ("Gray", .gray), ("Purple", .purple), ("Yellow", .yellow),
        ("Green", .green), ("Red", .red), ("Orange", .orange), ("Pink", .pink), ("Teal", .teal),
    ]

    var color: Color { Self.palette[colorIndex % Self.palette.count].color }

    /// One colored dot per palette entry for menus, which otherwise draw every icon as a gray template.
    private static let menuDots: [NSImage] = palette.map { entry in
        let dot = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(entry.color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        dot.isTemplate = false
        return dot
    }

    var menuDot: NSImage { Self.menuDots[colorIndex % Self.menuDots.count] }

    /// The palette entry closest to an sRGB color, used when importing pinboards.
    static func nearestPaletteIndex(to rgb: [Double]) -> Int {
        let distances = palette.map { entry -> Double in
            guard let color = NSColor(entry.color).usingColorSpace(.sRGB) else { return .infinity }
            let components = [color.redComponent, color.greenComponent, color.blueComponent].map(Double.init)
            return zip(components, rgb).reduce(0) { $0 + pow($1.0 - $1.1, 2) }
        }
        return distances.indices.min { distances[$0] < distances[$1] } ?? 0
    }
}

/// A clipboard capture that hasn't been stored yet. Built off the main actor for images.
nonisolated struct ClipDraft: Sendable {
    /// The source of clips copied on an iPhone: the iOS app's own, and Universal Clipboard's.
    static let iPhoneBundleID = "com.ronerez.Klip-iOS"
    static let iPhoneAppName = "iPhone"

    /// The iPhone app's clips: the plain ID, and since late 2026 one per kind
    /// ("com.ronerez.Klip-iOS.text", ".link", …), each with a tint of its own.
    static func isIPhone(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleID == iPhoneBundleID || bundleID.hasPrefix(iPhoneBundleID + ".")
    }

    let kind: ClipKind
    var text: String?
    var rtfData: Data?
    var imageData: Data?
    var imageWidth = 0
    var imageHeight = 0
    var filePaths: [String] = []
    var sourceBundleID: String?
    var sourceAppName: String?

    var contentHash: String {
        Self.hash(kind: kind, text: text, imageData: imageData, filePaths: filePaths)
    }

    static func hash(kind: ClipKind, text: String?, imageData: Data?, filePaths: [String]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        if let text { hasher.update(data: Data(text.utf8)) }
        if let imageData { hasher.update(data: imageData) }
        for path in filePaths { hasher.update(data: Data(path.utf8)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func text(_ string: String, rtf: Data?, sourceBundleID: String?, sourceAppName: String?) -> ClipDraft {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        var draft = ClipDraft(kind: .text, text: string, rtfData: rtf, sourceBundleID: sourceBundleID, sourceAppName: sourceAppName)
        if trimmed.hasPrefix("#"), HexColor.components(trimmed) != nil {
            draft = ClipDraft(kind: .color, text: trimmed, sourceBundleID: sourceBundleID, sourceAppName: sourceAppName)
        } else if !trimmed.contains(where: \.isWhitespace),
                  let url = URL(string: trimmed), url.host() != nil,
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            draft = ClipDraft(kind: .link, text: trimmed, sourceBundleID: sourceBundleID, sourceAppName: sourceAppName)
        }
        return draft
    }

    /// Reads pixel size and re-encodes non-PNG data (usually huge TIFFs) as PNG.
    static func image(from data: Data, sourceBundleID: String?, sourceAppName: String?) -> ClipDraft? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        var png = data
        if (CGImageSourceGetType(source) as String?) != UTType.png.identifier,
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let output = NSMutableData()
            if let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                if CGImageDestinationFinalize(destination) { png = output as Data }
            }
        }

        return ClipDraft(
            kind: .image,
            imageData: png,
            imageWidth: properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
            imageHeight: properties[kCGImagePropertyPixelHeight] as? Int ?? 0,
            sourceBundleID: sourceBundleID,
            sourceAppName: sourceAppName
        )
    }
}

nonisolated enum HexColor {
    static func components(_ string: String) -> (red: Double, green: Double, blue: Double)? {
        var hex = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 3 || hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard let value = UInt32(hex, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}

enum HistoryCapacity: Int, CaseIterable {
    case day, week, month, unlimited

    var label: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .unlimited: "Unlimited"
        }
    }

    var cutoff: Date? {
        let calendar = Calendar.current
        switch self {
        case .day: return calendar.date(byAdding: .day, value: -1, to: .now)
        case .week: return calendar.date(byAdding: .day, value: -7, to: .now)
        case .month: return calendar.date(byAdding: .month, value: -1, to: .now)
        case .unlimited: return nil
        }
    }

    static var current: HistoryCapacity {
        HistoryCapacity(rawValue: UserDefaults.standard.integer(forKey: Prefs.historyCapacity)) ?? .month
    }
}

enum Prefs {
    static let alwaysPlainText = "alwaysPlainText"
    static let soundEffects = "soundEffects"
    static let historyCapacity = "historyCapacity"
    static let hotKeyCode = "hotKeyCode"
    static let hotKeyModifiers = "hotKeyModifiers"
    static let hotKeyDisplay = "hotKeyDisplay"
    static let linkPreviews = "linkPreviews"
    /// Picking a clip also presses ⌘V in the app underneath (needs Accessibility). Off by default.
    static let directPaste = "directPaste"
    static let captureScreenshots = "captureScreenshots"
    /// A security-scoped bookmark to the folder screenshots are saved in (the sandbox needs the
    /// user to pick it once).
    static let screenshotFolderBookmark = "screenshotFolderBookmark"
    static let iCloudSync = "iCloudSync"
    /// Set once this Mac has finished its first download from iCloud; history isn't pruned before
    /// then, so a new Mac can't delete clips it hasn't seen yet.
    static let iCloudImportedOnce = "iCloudImportedOnce"
    static let iCloudLastSynced = "iCloudLastSynced"
    /// Bundle IDs of apps whose copies are never saved.
    static let ignoredApps = "ignoredApps"
    /// Copies that contain an access token, API key or private key aren't saved. Off by default.
    static let skipSecrets = "skipSecrets"
    /// Copies apps mark as made by themselves (copy-on-select in terminals) are saved too. Off by default.
    static let saveAutomaticCopies = "saveAutomaticCopies"
    static let defaultIgnoredApps = ["com.apple.keychainaccess", "com.apple.Passwords"]
    /// How many rows the panel shows: the recent clips listed before anything is typed, and the
    /// height the list and the preview keep. 10, 7 or 5 (Settings → Clips).
    static let recentCount = "recentCount"
    static let rowChoices = [10, 7, 5]
    /// How many lines of the clip each row shows under its title: 1, 2 or 3 (Settings → Clips),
    /// 2 by default. Rows, and the pictures in them, grow to fit.
    static let previewLines = "previewLines"
    static let previewLineChoices = [1, 2, 3]
    static let defaultPreviewLines = 2
    /// The glass behind the panel, from frosted to see-through (Settings → Clips). 0 is the usual
    /// glass; KlipLoft's slider runs 0…0.3, Mini's goes 10% further each way.
    static let panelTransparency = "panelTransparency"
    static let panelTransparencyRange = -0.1...0.4

    /// How opaque the glass layer is: fades from 1 toward 0.6 on the glass side.
    static func glassOpacity(_ transparency: Double) -> Double {
        1 - min(max(transparency, 0), panelTransparencyRange.upperBound)
    }

    /// How strong the frost wash over the glass is: 0 at the usual glass, up to 0.4 on the frosted side.
    static func frostOpacity(_ transparency: Double) -> Double {
        min(max(-transparency, 0), -panelTransparencyRange.lowerBound) * 4
    }

    /// The saved row count, or 10 when it isn't one of the choices.
    static var rowCount: Int {
        let value = UserDefaults.standard.integer(forKey: recentCount)
        return rowChoices.contains(value) ? value : 10
    }

    /// The saved preview line count, or the default when it isn't one of the choices.
    static var previewLineCount: Int { validPreviewLines(UserDefaults.standard.integer(forKey: previewLines)) }

    static func validPreviewLines(_ value: Int) -> Int {
        previewLineChoices.contains(value) ? value : defaultPreviewLines
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            soundEffects: false,
            historyCapacity: HistoryCapacity.month.rawValue,
            hotKeyCode: 49, // kVK_Space
            hotKeyModifiers: 2048, // optionKey
            hotKeyDisplay: "⌥Space",
            linkPreviews: true,
            directPaste: false,
            iCloudSync: true,
            ignoredApps: defaultIgnoredApps,
            skipSecrets: false,
            saveAutomaticCopies: false,
            recentCount: 10,
            previewLines: defaultPreviewLines,
        ])
    }
}
