// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import WebKit

// WebKit preserves SVG text/path rendering without third-party raster dependencies.
final class Renderer: NSObject, WKNavigationDelegate {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1440, height: 980))
    var files: [URL] = []
    var index = 0
    var timeout: Timer?

    func start() {
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("design/screens"),
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "svg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            let artwork = try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("design/artwork"), includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "svg" && ["moss", "signal", "tide"].contains($0.deletingPathExtension().lastPathComponent) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            files += artwork
            guard !files.isEmpty else { throw NSError(domain: "Render", code: 1) }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("design/previews"),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/XodusPreview/Resources/Artwork"),
                                                    withIntermediateDirectories: true)
            view.navigationDelegate = self
            next()
        } catch { fail(error.localizedDescription) }
    }

    func next() {
        guard index < files.count else {
            print("Rendered \(files.count) PNG previews.")
            exit(0)
        }
        timeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { _ in
            self.fail("Timed out rendering \(self.files[self.index].lastPathComponent)")
        }
        let isArtwork = files[index].deletingLastPathComponent().lastPathComponent == "artwork"
        view.window?.setContentSize(NSSize(width: isArtwork ? 1600 : 1440, height: isArtwork ? 900 : 980))
        view.loadFileURL(files[index], allowingReadAccessTo: files[index].deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let config = WKSnapshotConfiguration()
            config.rect = self.view.bounds
            let isArtwork = self.files[self.index].deletingLastPathComponent().lastPathComponent == "artwork"
            config.snapshotWidth = isArtwork ? 800 : 1440
            self.view.takeSnapshot(with: config) { image, error in
                guard let image, let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    self.fail(error?.localizedDescription ?? "Snapshot produced no PNG")
                }
                do {
                    let name = self.files[self.index].deletingPathExtension().lastPathComponent
                    let folder = isArtwork ? "Sources/XodusPreview/Resources/Artwork" : "design/previews"
                    try png.write(to: self.root.appendingPathComponent("\(folder)/\(name).png"))
                    print("\(folder)/\(name).png")
                    self.timeout?.invalidate()
                    self.index += 1
                    self.next()
                } catch { self.fail(error.localizedDescription) }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        fail(error.localizedDescription)
    }

    func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Render failed: \(message)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = Renderer()
let window = NSWindow(contentRect: renderer.view.bounds, styleMask: [.borderless],
                      backing: .buffered, defer: false)
window.contentView = renderer.view
window.orderBack(nil)
renderer.start()
app.run()
