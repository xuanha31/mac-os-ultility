import Foundation
import AppKit

/// Một mục trong lịch sử clipboard.
public struct ClipboardItem: Identifiable, Hashable, Sendable {
    public static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public let id: UUID
    public let timestamp: Date
    public let content: Content
    public let source: String?  // tên app đã copy (nếu biết)

    public enum Content: Sendable {
        case text(String)
        case image(Data)  // PNG data
        case fileURL([String])  // đường dẫn file
        case other(String)  // mô tả loại không hỗ trợ

        public var displayTitle: String {
            switch self {
            case .text(let s):
                let preview = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return preview.isEmpty ? "(text trống)" : String(preview.prefix(120))
            case .image:         return "Ảnh"
            case .fileURL(let u): return u.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
            case .other(let t):  return "[\(t)]"
            }
        }

        public var isText: Bool {
            if case .text = self { return true }
            return false
        }

        public var isImage: Bool {
            if case .image = self { return true }
            return false
        }

        public var textValue: String? {
            if case .text(let s) = self { return s }
            return nil
        }

        public var imageData: Data? {
            if case .image(let d) = self { return d }
            return nil
        }
    }

    public init(id: UUID = UUID(), timestamp: Date = Date(), content: Content, source: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.content = content
        self.source = source
    }

    /// Tạo từ NSPasteboard hiện tại. Trả nil nếu không có nội dung hữu ích.
    public static func fromPasteboard(_ pb: NSPasteboard) -> ClipboardItem? {
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName

        // 1. Text
        if let str = pb.string(forType: .string), !str.isEmpty {
            return ClipboardItem(content: .text(str), source: appName)
        }

        // 2. Image — đọc qua NSImage để nhận mọi loại ảnh (TIFF, PNG, PDF...)
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let first = images.first {
            let tiff = first.tiffRepresentation
            let bmp = tiff.flatMap { NSBitmapImageRep(data: $0) }
            let png = bmp?.representation(using: .png, properties: [:])
            return ClipboardItem(content: .image(png ?? tiff ?? Data()), source: appName)
        }

        // 3. File URLs
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            let paths = urls.map(\.path)
            return ClipboardItem(content: .fileURL(paths), source: appName)
        }

        // 4. RTF → extract text
        if let rtf = pb.data(forType: .rtf),
           let attr = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            let text = attr.string
            if !text.isEmpty { return ClipboardItem(content: .text(text), source: appName) }
        }

        return nil
    }

    /// Đẩy item này trở lại clipboard.
    public func writeToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch content {
        case .text(let s):
            pb.setString(s, forType: .string)
        case .image(let d):
            // Dùng NSImage.writeObjects để ghi đủ loại (TIFF + PNG + PDF)
            if let img = NSImage(data: d) {
                pb.writeObjects([img])
            } else {
                pb.setData(d, forType: .tiff)
            }
        case .fileURL(let paths):
            pb.writeObjects(paths.map { NSURL(fileURLWithPath: $0) })
        case .other:
            break
        }
    }
}
