import AppKit
import BrookCore
import SwiftUI
import Testing
@testable import BrookClient

/// Hosts the settings view at small and typical window sizes and checks that no control is laid
/// out wider than its window, which is how the window used to clip on the left and right.
/// Saves a PNG per size to $SNAPSHOT_DIR when it is set, so CI can upload them for viewing.
@MainActor
@Suite struct SettingsWindowLayoutTests {
    static let sizes: [CGSize] = [
        CGSize(width: 480, height: 320),  // smallest the window may shrink to
        CGSize(width: 560, height: 420),
        CGSize(width: 640, height: 700),  // the previous fixed size
        CGSize(width: 1280, height: 800),
    ]

    @Test func controlsFitInsideWindowWidth() throws {
        for size in Self.sizes {
            let name = "settings-\(Int(size.width))x\(Int(size.height))"
            let window = makeWindow(size: size)
            defer { window.close() }

            let view = try #require(window.contentView)
            view.layoutSubtreeIfNeeded()

            let overflowing = Self.overflowingViews(in: view)
            #expect(overflowing.isEmpty, "\(name): \(overflowing.joined(separator: "; "))")
            try Self.savePNG(view, name: name)
        }
    }

    private func makeWindow(size: CGSize) -> NSWindow {
        let view = SettingsView(
            model: SettingsModel(AppConfig()),
            onSave: { _ in },
            onCancel: {},
            onInstallHelper: {}
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(size)
        window.layoutIfNeeded()
        return window
    }

    /// Views whose horizontal extent falls outside the root. The form scrolls vertically only,
    /// so anything wider than the window is clipped and unreachable.
    private static func overflowingViews(in root: NSView) -> [String] {
        var result: [String] = []
        func visit(_ parent: NSView) {
            for child in parent.subviews where !child.isHidden && child.frame.width > 0 {
                let frame = root.convert(child.bounds, from: child)
                if frame.minX < -0.5 || frame.maxX > root.bounds.maxX + 0.5 {
                    result.append("\(type(of: child)) spans \(Int(frame.minX))…\(Int(frame.maxX)) in \(Int(root.bounds.width))pt")
                }
                visit(child)
            }
        }
        visit(root)
        return result
    }

    private static func savePNG(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = rep.representation(using: .png, properties: [:])
        try data?.write(to: folder.appendingPathComponent("\(name).png"))
    }
}
