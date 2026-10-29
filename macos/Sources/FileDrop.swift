import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// A file dropped on the notch, copied into a private temp folder in a form `claude -p` can Read.
struct DroppedFile {
    let url: URL
    let name: String
    /// Shown to the user above the answer, e.g. "only the beginning".
    let note: String?
    /// Extra instructions for Claude about this file.
    let hint: String
}

enum FileDrop {
    enum Kind { case text, pdf, image }

    private static let textLimit = 200_000
    private static let pdfPageLimit = 10
    private static let imagePixels = 1600
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]
    private static let folderPrefix = "ClawdFile-"

    /// Judged from the name only, while the file is still being dragged: opening it before the
    /// drop could trip macOS's folder-privacy prompts. Unknown extensions get the benefit of the doubt.
    static func looksSupported(_ url: URL) -> Bool {
        guard !url.hasDirectoryPath else { return false }
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty || imageExtensions.contains(ext) || ext == "pdf" { return true }
        guard let t = UTType(filenameExtension: ext), t.isDeclared else { return true }
        return t.conforms(to: .text) || t.conforms(to: .sourceCode)
    }

    static func kind(of url: URL) -> Kind? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if let t = UTType(filenameExtension: ext), t.conforms(to: .text) || t.conforms(to: .sourceCode) { return .text }
        // Unknown extensions (.vue, .tsx, no extension…): text if the start is valid UTF-8 without NULs.
        guard let h = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? h.close() }
        let head = h.readData(ofLength: 8192)
        return !head.contains(0) && String(data: head, encoding: .utf8) != nil ? .text : nil
    }

    /// "report.pdf · 2,4 MB", for the drop card.
    static func label(for url: URL) -> String {
        [url.lastPathComponent, sizeText(url)].compactMap { $0 }.joined(separator: " · ")
    }

    private static func sizeText(_ url: URL) -> String? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
        return size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
    }

    /// Makes the temp copy; nil if the file isn't something we read.
    static func prepare(_ url: URL) -> DroppedFile? {
        guard let kind = kind(of: url) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(folderPrefix + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = url.lastPathComponent
        let ru = L10n.lang == .ru

        switch kind {
        case .text:
            guard let h = FileHandle(forReadingAtPath: url.path) else { return nil }
            defer { try? h.close() }
            var data = h.readData(ofLength: textLimit + 1)
            var note: String?, hint = ""
            if data.count > textLimit {
                data = data.prefix(textLimit)
                // Cut at the last line break so we don't hand over half a line or half a character.
                if let nl = data.lastIndex(of: UInt8(ascii: "\n")) { data = data.prefix(upTo: nl) }
                let size = sizeText(url) ?? ""
                note = ru ? "Файл большой (\(size)), читаю только начало" : "Big file (\(size)), reading only the beginning"
                hint = " This is only the beginning of a larger file; say so if it matters."
            }
            let out = dir.appendingPathComponent(name)
            guard (try? data.write(to: out)) != nil else { return nil }
            return DroppedFile(url: out, name: name, note: note, hint: hint)

        case .pdf:
            let out = dir.appendingPathComponent(name)
            guard (try? FileManager.default.copyItem(at: url, to: out)) != nil else { return nil }
            let pages = PDFDocument(url: url)?.pageCount ?? 0
            guard pages > pdfPageLimit else { return DroppedFile(url: out, name: name, note: nil, hint: "") }
            return DroppedFile(
                url: out, name: name,
                note: ru ? "В PDF \(pages) стр., читаю первые \(pdfPageLimit)" : "\(pages)-page PDF, reading the first \(pdfPageLimit)",
                hint: " It has \(pages) pages: read only pages 1-\(pdfPageLimit) (Read's pages parameter) and say it's a partial read.")

        case .image:
            // Downscaled JPEG: plenty for reading, and quick to send.
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: imagePixels,
            ]
            let jpgName = (name as NSString).deletingPathExtension + ".jpg"
            let out = dir.appendingPathComponent(jpgName)
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
                  let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return nil }
            return DroppedFile(url: out, name: jpgName, note: nil, hint: "")
        }
    }

    static func discard(_ f: DroppedFile?) {
        guard let f else { return }
        try? FileManager.default.removeItem(at: f.url.deletingLastPathComponent())
    }

    /// Leftovers from a run that quit mid-chat.
    static func cleanUp() {
        let tmp = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix(folderPrefix) {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }
}
