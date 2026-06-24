import Foundation
import AppKit

// RD-02: Giao diện chung cho một phiên remote (VNC/RDP).

public enum RemoteSessionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

/// Một phiên remote. Phiên **sở hữu NSView của nó** → nhúng trong app hoặc tách
/// ra cửa sổ riêng chỉ là chuyển superview, không phải kết nối lại.
@MainActor
public protocol RemoteSession: AnyObject {
    var id: UUID { get }
    var profile: RemoteProfile { get }

    /// View hiển thị framebuffer. Trả về **cùng một instance** qua các lần gọi.
    func makeView() -> NSView

    func connect()
    func disconnect()

    /// Đặt scale hiển thị remote theo % (100 = 1:1). Scale cao → UI to hơn (độ phân giải remote
    /// nhỏ lại, phóng lên khung). Chỉ áp dụng cho phiên hỗ trợ dynamic-resolution (RDP Auto).
    func setScale(_ percent: Int)

    /// RemoteState gán để nhận thay đổi trạng thái.
    var onStateChange: ((RemoteSessionState) -> Void)? { get set }
}

public extension RemoteSession {
    func setScale(_ percent: Int) {}   // mặc định: không hỗ trợ (vd VNC / RDP preset)
}

/// Phiên rỗng — hiển thị thông báo thay vì màn hình remote. Dùng cho Phase 0 và
/// làm fallback khi một giao thức chưa được biên dịch (vd RDP thiếu FreeRDP).
@MainActor
public final class PlaceholderSession: RemoteSession {
    public let id: UUID
    public let profile: RemoteProfile
    public var onStateChange: ((RemoteSessionState) -> Void)?

    private let message: String
    private var cachedView: NSView?

    public init(profile: RemoteProfile,
                message: String = "Phần kết nối sẽ được bổ sung ở bước sau.") {
        self.id = profile.id
        self.profile = profile
        self.message = message
    }

    public func makeView() -> NSView {
        if let v = cachedView { return v }

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        let label = NSTextField(labelWithString: "\(profile.displayName)\n\(message)")
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -32)
        ])

        cachedView = container
        return container
    }

    public func connect() { onStateChange?(.disconnected) }
    public func disconnect() {}
}
