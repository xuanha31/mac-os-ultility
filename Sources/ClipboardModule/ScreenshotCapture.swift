import Foundation
import AppKit
import CoreGraphics

/// Chụp màn hình và quản lý clipboard.
public enum ScreenshotCapture {

    // MARK: - Screen Recording permission

    /// Kiểm tra app đã có quyền Screen Recording chưa (cần cho CGDisplayCreateImage).
    public static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Yêu cầu quyền Screen Recording — macOS hiện dialog mở System Settings.
    /// Trả về true nếu đã có quyền sẵn.
    @discardableResult
    public static func requestScreenRecordingPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        return false
    }

    // MARK: - Full screen

    /// Chụp màn hình chính, trả về PNG data. Trả nil nếu chưa có quyền Screen Recording.
    public static func captureMainDisplay() -> Data? {
        let displayID = CGMainDisplayID()
        guard let cgImage = CGDisplayCreateImage(displayID) else { return nil }
        return pngData(from: cgImage)
    }

    /// Chụp tất cả màn hình, trả về danh sách PNG data.
    public static func captureAllDisplays() -> [Data] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let cg = CGDisplayCreateImage(id) else { return nil }
            return pngData(from: cg)
        }
    }

    /// Chụp một cửa sổ cụ thể.
    public static func captureWindow(windowID: CGWindowID) -> Data? {
        guard let cg = CGWindowListCreateImage(
            .null, .optionIncludingWindow, windowID,
            [.boundsIgnoreFraming, .shouldBeOpaque]
        ) else { return nil }
        return pngData(from: cg)
    }

    // MARK: - Selection (dùng screencapture CLI)

    /// Mở selection tool — user kéo vùng muốn chụp.
    /// screencapture -i lưu file; callback trả PNG data.
    public static func captureSelection(completion: @escaping @Sendable (Data?) -> Void) {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macutil-ss-\(UInt32.random(in: 0...UInt32.max)).png")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-i", "-x", tmpURL.path]  // -x = no sound
        proc.terminationHandler = { p in
            DispatchQueue.main.async {
                guard p.terminationStatus == 0 else { completion(nil); return }
                let data = try? Data(contentsOf: tmpURL)
                try? FileManager.default.removeItem(at: tmpURL)
                completion(data)
            }
        }
        try? proc.run()
    }

    // MARK: - Capture + copy to clipboard

    /// Chụp toàn màn hình và copy vào clipboard. Trả về PNG data.
    @discardableResult
    public static func captureAndCopyToClipboard() -> Data? {
        guard let data = captureMainDisplay() else { return nil }
        copyImageToClipboard(data)
        return data
    }

    /// Chụp selection và copy vào clipboard.
    public static func captureSelectionToClipboard(completion: @escaping @Sendable (Bool) -> Void) {
        captureSelection { data in
            guard let d = data else { completion(false); return }
            copyImageToClipboard(d)
            completion(true)
        }
    }

    // MARK: - Clipboard write

    /// Ghi ảnh PNG vào clipboard đúng cách — dùng writeObjects([NSImage])
    /// để macOS tự ghi đủ loại (.tiff, .png, PDF...) mà các app đều đọc được.
    public static func copyImageToClipboard(_ pngData: Data) {
        guard let image = NSImage(data: pngData) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])  // NSImage tự khai báo đủ UTI types
    }

    public static func copyTextToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Private helper

    private static func pngData(from cgImage: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }
}
