import CoreGraphics
import Foundation
import os

/// What KlipLoft Mini did, for the support report's events.log: drawer opens, pastes, shortcuts,
/// Snap, screenshots, clears and AI apps. App names, bundle IDs, counts and frames only,
/// never what a clip says. Notice level, so macOS keeps them for the report's 3 days.
enum EventLog {
    static let subsystem = "com.ronerez.KlipLoftMini"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let drawer = Logger(subsystem: subsystem, category: "drawer")
    static let paste = Logger(subsystem: subsystem, category: "paste")
    static let shortcuts = Logger(subsystem: subsystem, category: "shortcuts")
    static let snap = Logger(subsystem: subsystem, category: "snap")
    static let screenshots = Logger(subsystem: subsystem, category: "screenshots")
    static let history = Logger(subsystem: subsystem, category: "history")
    /// A frame as "x,y w×h" in whole points.
    static func frame(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))"
    }
}
