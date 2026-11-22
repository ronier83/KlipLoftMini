import AppKit
import ImageIO
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Source-app icons and the header tint derived from each icon, cached per bundle ID.
enum AppIcons {
    private static var icons: [String: NSImage] = [:]
    private static var colors: [String: Color] = [:]
    /// Apps whose icon has no clear color, so it isn't measured again.
    private static var colorless: Set<String> = []
    private static let fallbackColor = Color(red: 0.52, green: 0.53, blue: 0.56)

    /// Brand colors for apps whose icons average out to something muddy.
    private static let brandColors: [String: Color] = {
        let googleBlue = Color(red: 0x42 / 255, green: 0x85 / 255, blue: 0xF4 / 255) // #4285F4
        return [
            "com.google.Chrome": googleBlue,
            "com.google.Chrome.beta": googleBlue,
            "com.google.Chrome.dev": googleBlue,
            "com.google.Chrome.canary": googleBlue,
        ]
    }()

    static func icon(for bundleID: String?) -> NSImage {
        let generic = NSWorkspace.shared.icon(for: .application)
        guard let bundleID else { return generic }
        // Clips from the iPhone carry Klip's own icon, which sits on the same icon grid as other
        // apps. (The icon iPhone builds publish for their per-kind IDs can have a wider margin,
        // so it showed smaller, ringed by more glass.)
        if ClipDraft.isIPhone(bundleID) { return NSApp.applicationIconImage }
        if let cached = icons[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? generic
        icons[bundleID] = icon
        return icon
    }

    /// Uses an icon and tint that came from another Mac or a .klip file, for an app that isn't
    /// installed here. Installed apps keep their own icon.
    static func useStoredIcon(for bundleID: String, iconData: Data?, tintHex: String) {
        guard !ClipDraft.isIPhone(bundleID),
              NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) == nil
        else { return }
        if let iconData, let image = NSImage(data: iconData) {
            icons[bundleID] = image
            menuIcons[bundleID] = nil
        }
        if brandColors[bundleID] == nil, let tint = Color(hex: tintHex) {
            colors[bundleID] = tint
        }
    }

    private static var menuIcons: [String: NSImage] = [:]

    /// A 16-point copy of the app icon; menus draw full-size icons huge.
    static func menuIcon(for bundleID: String) -> NSImage {
        if let cached = menuIcons[bundleID] { return cached }
        let source = icon(for: bundleID)
        let small = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        menuIcons[bundleID] = small
        return small
    }

    static func color(for bundleID: String?) -> Color {
        knownColor(for: bundleID) ?? fallbackColor
    }

    /// The app's color, or nil when the clip has no source app or its icon has no clear color.
    static func knownColor(for bundleID: String?) -> Color? {
        guard let bundleID else { return nil }
        if let brand = brandColors[bundleID] { return brand }
        if let cached = colors[bundleID] { return cached }
        guard !colorless.contains(bundleID) else { return nil }
        guard let color = dominantColor(of: icon(for: bundleID)).map(Color.init(nsColor:)) else {
            colorless.insert(bundleID)
            return nil
        }
        colors[bundleID] = color
        return color
    }

    /// The app's icon as a PNG `side` pixels square, for syncing to devices without the app.
    static func pngData(for bundleID: String, side: Int = 256) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        icon(for: bundleID).draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    /// The header tint as "#RRGGBB".
    static func hex(for bundleID: String) -> String {
        guard let color = NSColor(color(for: bundleID)).usingColorSpace(.sRGB) else { return "" }
        let channels = [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
    }

    private static func dominantColor(of image: NSImage) -> NSColor? {
        let side = 24
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var red = 0.0, green = 0.0, blue = 0.0, total = 0.0
        for x in 0..<side {
            for y in 0..<side {
                guard let pixel = bitmap.colorAt(x: x, y: y), pixel.alphaComponent > 0.5 else { continue }
                // Favor saturated pixels so a brand color wins over white and grey chrome.
                let weight = 0.15 + pixel.saturationComponent
                red += pixel.redComponent * weight
                green += pixel.greenComponent * weight
                blue += pixel.blueComponent * weight
                total += weight
            }
        }
        guard total > 0 else { return nil }
        let average = NSColor(deviceRed: red / total, green: green / total, blue: blue / total, alpha: 1)
        // Keep it dark enough for the white header text.
        return NSColor(
            deviceHue: average.hueComponent,
            saturation: min(average.saturationComponent * 1.25, 0.85),
            brightness: min(max(average.brightnessComponent, 0.42), 0.7),
            alpha: 1
        )
    }
}

/// Downsampled image previews, so the strip never decodes full-size screenshots.
enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for item: ClipItem, maxPixelSize: Int) -> NSImage? {
        guard isAttached(item) else { return nil }
        return image(from: item.imagePayload, key: "\(item.id.uuidString)-\(maxPixelSize)", maxPixelSize: maxPixelSize)
    }

    /// The link preview image fetched for a link clip.
    static func linkImage(for item: ClipItem, maxPixelSize: Int) -> NSImage? {
        guard isAttached(item) else { return nil }
        return image(from: item.linkImageData, key: "\(item.id.uuidString)-link-\(maxPixelSize)", maxPixelSize: maxPixelSize)
    }

    /// A clip deleted here or by an iCloud import can still be drawn for one more frame, and
    /// reading its not-yet-loaded external data then is a SwiftData fatal error, not nil.
    private static func isAttached(_ item: ClipItem) -> Bool {
        !item.isDeleted && item.modelContext != nil
    }

    /// `data` is only read on a cache miss, so cached cards never touch the external storage.
    private static func image(from data: @autoclosure () -> Data?, key: String, maxPixelSize: Int) -> NSImage? {
        let key = key as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = data(),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary)
        else { return nil }
        let thumbnail = NSImage(cgImage: image, size: .zero)
        cache.setObject(thumbnail, forKey: key)
        return thumbnail
    }
}

extension Color {
    init?(hex: String) {
        guard let components = HexColor.components(hex) else { return nil }
        self.init(red: components.red, green: components.green, blue: components.blue)
    }
}
