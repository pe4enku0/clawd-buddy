import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Gets a picture of the screen for "What's on my screen?".
/// With Screen Recording allowed: a silent `screencapture` of the screen under the mouse.
/// Without it (or if Jamf forbids it): the user takes an area screenshot to the clipboard
/// with ⌘⌃⇧4 and we pick it up — the clipboard needs no permission.
enum ScreenGrab {
    private static let askedKey = "screenAccessAsked"
    private static let filePrefix = "ClawdScreen-"
    /// Big enough to read code and error text, small enough to send quickly.
    private static let maxPixels = 1600

    static var hasAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt at most once, ever; after that the user decides in System Settings.
    static func requestAccessOnce() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: askedKey) else { return }
        d.set(true, forKey: askedKey)
        CGRequestScreenCaptureAccess()
    }

    /// Does this chat message ask about the screen?
    /// Whole words only, so "экранировать" (to escape) or "SwiftUI screen" don't grab the screen.
    static func mentionsScreen(_ text: String) -> Bool {
        text.range(of: screenWords, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let screenWords = [
        #"\bэкран(е|а|у|ом)?\b"#, #"\bскрин"#, #"\bчто (ты )?видишь"#,
        #"\b(my|the|on) screen\b"#, #"\bscreenshot"#, #"\bwhat (do )?you see\b"#,
    ].joined(separator: "|")

    /// Captures the screen under the mouse as a downscaled JPEG. Completion on main; nil on failure.
    static func capture(_ completion: @escaping (URL?) -> Void) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            completion(nil)
            return
        }
        // screencapture -R takes points from the top-left of the primary display.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let f = screen.frame
        let rect = "\(Int(f.minX)),\(Int(primaryHeight - f.maxY)),\(Int(f.width)),\(Int(f.height))"
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("\(filePrefix)\(UUID().uuidString).png")
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-t", "png", "-R", rect, png.path]
            try? p.run()
            p.waitUntilExit()
            let out = CGImageSourceCreateWithURL(png as CFURL, nil).flatMap(saveJPEG)
            try? FileManager.default.removeItem(at: png)
            DispatchQueue.main.async { completion(out) }
        }
    }

    /// An image someone just copied (e.g. ⌘⌃⇧4), as a downscaled JPEG; nil if the clipboard holds no image.
    static func fromPasteboard(_ pb: NSPasteboard = .general) -> URL? {
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return saveJPEG(src)
    }

    /// Removes leftovers from a previous run that quit mid-question.
    static func cleanUp() {
        let tmp = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix(filePrefix) {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    private static func saveJPEG(_ src: CGImageSource) -> URL? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(filePrefix)\(UUID().uuidString).jpg")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? url : nil
    }
}
