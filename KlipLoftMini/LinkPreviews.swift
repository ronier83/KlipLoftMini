import AppKit
import ImageIO
import LinkPresentation
import SwiftData
import UniformTypeIdentifiers

/// Fetches a link clip's page title and preview image (the page's og:image) the first time
/// its card is shown, and stores them on the clip. Like Paste, this contacts the linked site,
/// so it can be turned off in Settings.
enum LinkPreviews {
    private static var inFlight: Set<UUID> = []

    static func fetchIfNeeded(for item: ClipItem, in context: ModelContext) async {
        guard item.kind == .link, !item.linkPreviewFetched,
              UserDefaults.standard.bool(forKey: Prefs.linkPreviews),
              let text = item.text, let url = URL(string: text),
              inFlight.insert(item.id).inserted
        else { return }
        defer { inFlight.remove(item.id) }

        let provider = LPMetadataProvider()
        provider.timeout = 10
        let metadata = try? await provider.startFetchingMetadata(for: url)
        var imageData: Data?
        if let imageProvider = metadata?.imageProvider,
           let raw = await loadImageData(from: imageProvider) {
            imageData = await Task.detached(priority: .utility) { downsampledJPEG(raw, maxPixelSize: 1200) }.value
        }

        item.linkTitle = metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        item.linkImageData = imageData
        // Marked even on failure, so unreachable pages aren't retried on every redraw.
        item.linkPreviewFetched = true
        try? context.save()
    }

    private static func loadImageData(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: .image) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// Re-encodes the page image small enough to keep the store light.
    nonisolated private static func downsampledJPEG(_ data: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
