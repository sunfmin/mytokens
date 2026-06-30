import AppKit
import XCTest

/// Reusable glue (rule 2): build a real view, rasterize it offscreen to
/// `out/<name>.png`, and hand the view back so the test can assert on the
/// rendered tree (rule 4). New render tests just pass a different builder.
///
/// No app launch and no server: the view is hosted in an offscreen window only
/// to get a real backing store and the screen's scale factor, then snapshotted
/// with `cacheDisplay`. `SecretPromptView` paints its fills in `draw(_:)` rather
/// than via CALayer, so every background survives the capture.
@discardableResult
func renderToImage(_ name: String,
                   file: StaticString = #filePath,
                   _ build: () -> NSView) -> (path: URL, view: NSView) {
    let view = build()

    let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()

    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        fatalError("could not allocate bitmap for \(name)")
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode PNG for \(name)")
    }

    let outDir = URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("out")
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let path = outDir.appendingPathComponent("\(name).png")
    try! png.write(to: path)
    return (path, view)
}

extension NSView {
    /// Depth-first descendants — the query surface for content asserts.
    var allSubviews: [NSView] { subviews + subviews.flatMap { $0.allSubviews } }
}
