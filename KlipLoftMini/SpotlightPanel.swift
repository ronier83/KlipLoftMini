import os
import AppKit
import SwiftUI

/// A borderless panel that takes typing without activating the app, so the app underneath stays
/// in front and a paste lands in it, like Spotlight.
final class SpotlightPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum SpotlightLayout {
    static let listWidth: CGFloat = 680
    /// Clear room on each side of the glass so its shadow fades out instead of being cut off at
    /// the window's edges.
    static let shadowMargin: CGFloat = 40
    static let windowWidth: CGFloat = listWidth + 2 * shadowMargin
    static let searchHeight: CGFloat = 62
    /// A row with one preview line; each extra line (Settings → Clips) adds one line of its text.
    static func rowHeight(lines: Int) -> CGFloat { 58 + CGFloat(lines - 1) * 15 }
    static var rowHeight: CGFloat { rowHeight(lines: Prefs.previewLineCount) }
    /// Room above the search for the match count chip; the panel sits that much higher, so the
    /// search stays where it was.
    static let chipRow: CGFloat = 42

    /// The list's height for the chosen row count (Settings → Clips), which the preview keeps too.
    static var listHeight: CGFloat { CGFloat(Prefs.rowCount) * (rowHeight + 2) + 16 }
    /// The window: the chip row, the search, the list, and room below for the glass's shadow
    /// (930 at the default 10 rows of 2 preview lines).
    static var height: CGFloat { chipRow + searchHeight + 12 + listHeight + 48 }
    /// How far below the top of the screen the search bar sits, as a share of the screen's height.
    static let topInset: CGFloat = 0.2
}

final class SpotlightPanelController {
    private let model: AppModel
    private let panel: SpotlightPanel
    private var resignObserver: NSObjectProtocol?
    private var eventMonitor: Any?
    private var pointerTimer: Timer?

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect? { panel.isVisible ? panel.frame : nil }
    var contentView: NSView? { panel.contentView }

    init(model: AppModel) {
        self.model = model
        let size = NSSize(width: SpotlightLayout.windowWidth, height: SpotlightLayout.height)
        panel = SpotlightPanel(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                               backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = NSHostingView(rootView: SpotlightView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        // Any key hands the selection back to the keyboard. (Mouse movement is noticed by the rows
        // themselves: a background app gets no mouse-moved events.)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            MainActor.assumeIsolated {
                let model = AppModel.shared
                if model.mouseActive {
                    model.mouseActive = false
                    model.lastMouseLocation = NSEvent.mouseLocation
                }
            }
            return event
        }
        // A click anywhere else closes it, like Spotlight.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.panel.hide() }
        }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        model.prepareForShow()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        // Rows and preview lines (Settings → Clips) set the list's height, so the window follows it
        panel.setContentSize(NSSize(width: SpotlightLayout.windowWidth, height: SpotlightLayout.height))
        if let frame = screen?.visibleFrame, let full = screen?.frame {
            let x = frame.midX - SpotlightLayout.windowWidth / 2
            let top = full.maxY - full.height * SpotlightLayout.topInset
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: min(top + SpotlightLayout.chipRow, frame.maxY)))
        }
        panel.makeKeyAndOrderFront(nil)
        pointerTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.panel.checkPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
        EventLog.drawer.notice("panel shown")
    }

    /// Where the pointer is, for the rows: on screen, and in the panel's top-left coordinates.
    func checkPointer() {
        guard panel.isVisible, let content = panel.contentView else { return }
        let screen = NSEvent.mouseLocation
        let inWindow = panel.convertPoint(fromScreen: screen)
        model.checkPointer(screenLocation: screen, point: CGPoint(x: inWindow.x, y: content.bounds.height - inWindow.y))
    }

    func hide() {
        guard panel.isVisible else { return }
        pointerTimer?.invalidate()
        pointerTimer = nil
        panel.orderOut(nil)
        model.previewItemID = nil
    }
}

/// A short note near the bottom of the screen ("Copied · press ⌘V to paste").
enum Toast {
    private static var window: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, symbol: String) {
        let view = Label(text, systemImage: symbol)
            .font(.system(size: 15, weight: .medium))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .padding(10)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let panel = window ?? {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.level = .popUpMenu
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            window = panel
            return panel
        }()
        panel.contentView = host
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 80, width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated { panel.orderOut(nil) }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }
}
