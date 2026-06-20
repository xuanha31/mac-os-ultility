#if HAS_FREERDP
import Foundation
import AppKit
import CoreGraphics
import Core
import CFreeRDP

// RD Phase 2: phiên RDP dùng FreeRDP 3.x (C interop qua CFreeRDP).
// - RDPClient chạy event loop FreeRDP trên thread nền, render GDI framebuffer → CGImage.
// - Callback C (@convention(c), không capture) tra ngược RDPClient qua registry theo con
//   trỏ rdpContext.
// - RDPFramebufferNSView vẽ ảnh + forward chuột/bàn phím.
//
// ⚠️ Cần kiểm thử với máy Windows thật (bật Remote Desktop). Cert đang auto-accept
//    (FreeRDP_AutoAcceptCertificate) — nên thêm xác nhận người dùng về sau.

// MARK: - Registry: rdpContext* → RDPClient

final class RDPClientRegistry: @unchecked Sendable {
    static let shared = RDPClientRegistry()
    private var map: [UnsafeMutableRawPointer: RDPClient] = [:]
    private let lock = NSLock()
    func set(_ key: UnsafeMutableRawPointer, _ client: RDPClient) { lock.lock(); map[key] = client; lock.unlock() }
    func remove(_ key: UnsafeMutableRawPointer) { lock.lock(); map[key] = nil; lock.unlock() }
    func get(_ key: UnsafeMutableRawPointer) -> RDPClient? { lock.lock(); defer { lock.unlock() }; return map[key] }
}

// MARK: - C callbacks

private func rdpPreConnect(_ instance: UnsafeMutablePointer<freerdp>?) -> ObjCBool {
    guard let instance, let ctx = instance.pointee.context, let settings = ctx.pointee.settings else { return false }
    freerdp_settings_set_bool(settings, FreeRDP_SoftwareGdi, true)
    return true
}

private func rdpPostConnect(_ instance: UnsafeMutablePointer<freerdp>?) -> ObjCBool {
    guard let instance, let ctx = instance.pointee.context else { return false }
    if !gdi_init(instance, cfreerdp_pixel_format_bgra32()) { return false }
    ctx.pointee.update?.pointee.EndPaint = rdpEndPaint
    return true
}

private func rdpEndPaint(_ context: UnsafeMutablePointer<rdpContext>?) -> ObjCBool {
    guard let context else { return false }
    RDPClientRegistry.shared.get(UnsafeMutableRawPointer(context))?.renderFrame()
    return true
}

// MARK: - RDPClient (thread nền)

final class RDPClient: @unchecked Sendable {
    var onState: ((RemoteSessionState) -> Void)?
    var onImage: ((CGImage) -> Void)?

    private let host: String
    private let port: UInt16
    private let username: String
    private let password: String
    private let domain: String

    private var instance: UnsafeMutablePointer<freerdp>?
    private var thread: Thread?
    private var running = false

    init(host: String, port: UInt16, username: String, password: String, domain: String) {
        self.host = host; self.port = port
        self.username = username; self.password = password; self.domain = domain
    }

    func start() {
        let t = Thread { [weak self] in self?.run() }
        t.stackSize = 4 << 20
        thread = t
        running = true
        t.start()
    }

    func stop() {
        running = false
        if let inst = instance, let ctx = inst.pointee.context {
            freerdp_abort_connect_context(ctx)
        }
    }

    private func run() {
        guard let inst = freerdp_new() else { onState?(.failed("freerdp_new lỗi")); return }
        instance = inst
        inst.pointee.PreConnect = rdpPreConnect
        inst.pointee.PostConnect = rdpPostConnect

        guard freerdp_context_new(inst),
              let ctx = inst.pointee.context,
              let settings = ctx.pointee.settings else {
            onState?(.failed("freerdp_context_new lỗi")); cleanup(); return
        }

        freerdp_settings_set_string(settings, FreeRDP_ServerHostname, host)
        freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, UInt32(port))
        if !username.isEmpty { freerdp_settings_set_string(settings, FreeRDP_Username, username) }
        if !password.isEmpty { freerdp_settings_set_string(settings, FreeRDP_Password, password) }
        if !domain.isEmpty   { freerdp_settings_set_string(settings, FreeRDP_Domain, domain) }
        freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, 1280)
        freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, 800)
        freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32)
        freerdp_settings_set_bool(settings, FreeRDP_AutoAcceptCertificate, true)

        RDPClientRegistry.shared.set(UnsafeMutableRawPointer(ctx), self)

        onState?(.connecting)
        if !freerdp_connect(inst) {
            onState?(.failed("Kết nối RDP thất bại (kiểm tra host/credentials)."))
            cleanup(); return
        }
        onState?(.connected)

        var handles = [HANDLE?](repeating: nil, count: 64)
        while running && !freerdp_shall_disconnect_context(ctx) {
            let count = handles.withUnsafeMutableBufferPointer {
                freerdp_get_event_handles(ctx, $0.baseAddress, UInt32($0.count))
            }
            if count == 0 { break }
            let wait = handles.withUnsafeMutableBufferPointer {
                WaitForMultipleObjects(count, $0.baseAddress, false, 100)
            }
            if wait == 0xFFFF_FFFF { break } // WAIT_FAILED
            if !freerdp_check_event_handles(ctx) { break }
        }

        freerdp_disconnect(inst)
        onState?(.disconnected)
        cleanup()
    }

    func renderFrame() {
        guard let inst = instance, let ctx = inst.pointee.context,
              let gdi = ctx.pointee.gdi, let buf = gdi.pointee.primary_buffer else { return }
        let w = Int(gdi.pointee.width), h = Int(gdi.pointee.height), stride = Int(gdi.pointee.stride)
        guard w > 0, h > 0, stride > 0 else { return }
        let data = Data(bytes: buf, count: stride * h)
        guard let provider = CGDataProvider(data: data as CFData) else { return }
        let bmp = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                               | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: bmp, provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent) else { return }
        onImage?(img)
    }

    func sendMouse(flags: UInt16, x: UInt16, y: UInt16) {
        guard let inst = instance, let ctx = inst.pointee.context, let input = ctx.pointee.input else { return }
        _ = freerdp_input_send_mouse_event(input, flags, x, y)
    }

    func sendUnicode(_ code: UInt16, down: Bool) {
        guard let inst = instance, let ctx = inst.pointee.context, let input = ctx.pointee.input else { return }
        _ = freerdp_input_send_unicode_keyboard_event(input, down ? 0 : 0x8000, code) // 0x8000 = KBD_FLAGS_RELEASE
    }

    private func cleanup() {
        if let inst = instance {
            if let ctx = inst.pointee.context {
                RDPClientRegistry.shared.remove(UnsafeMutableRawPointer(ctx))
            }
            freerdp_context_free(inst)
            freerdp_free(inst)
        }
        instance = nil
    }
}

// MARK: - NSView vẽ framebuffer + input

final class RDPFramebufferNSView: NSView {
    var onMouse: ((UInt16, UInt16, UInt16) -> Void)?
    var onKey: ((UInt16, Bool) -> Void)?

    private var image: CGImage?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }   // gốc tọa độ trên-trái như RDP

    func setImage(_ img: CGImage) { image = img; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.setFillColor(NSColor.black.cgColor)
        cg.fill(bounds)
        if let image { cg.draw(image, in: bounds) }
    }

    private func remotePoint(_ event: NSEvent) -> (UInt16, UInt16) {
        let p = convert(event.locationInWindow, from: nil)
        guard let image, bounds.width > 0, bounds.height > 0 else { return (0, 0) }
        let rx = max(0, min(CGFloat(image.width) - 1, p.x / bounds.width * CGFloat(image.width)))
        let ry = max(0, min(CGFloat(image.height) - 1, p.y / bounds.height * CGFloat(image.height)))
        return (UInt16(rx), UInt16(ry))
    }

    // PTR_FLAGS: MOVE=0x0800, DOWN=0x8000, BUTTON1=0x1000, BUTTON2=0x2000, WHEEL=0x0200
    override func mouseMoved(with e: NSEvent)    { let (x, y) = remotePoint(e); onMouse?(0x0800, x, y) }
    override func mouseDragged(with e: NSEvent)  { let (x, y) = remotePoint(e); onMouse?(0x0800, x, y) }
    override func mouseDown(with e: NSEvent)     { window?.makeFirstResponder(self); let (x, y) = remotePoint(e); onMouse?(0x8000 | 0x1000, x, y) }
    override func mouseUp(with e: NSEvent)       { let (x, y) = remotePoint(e); onMouse?(0x1000, x, y) }
    override func rightMouseDown(with e: NSEvent){ let (x, y) = remotePoint(e); onMouse?(0x8000 | 0x2000, x, y) }
    override func rightMouseUp(with e: NSEvent)  { let (x, y) = remotePoint(e); onMouse?(0x2000, x, y) }

    override func scrollWheel(with e: NSEvent) {
        let (x, y) = remotePoint(e)
        let delta = Int(e.scrollingDeltaY)
        guard delta != 0 else { return }
        // WHEEL=0x0200; bit thấp = step; âm dùng WHEEL_NEGATIVE=0x0100
        let magnitude = UInt16(min(0xFF, abs(delta) * 30))
        let flags: UInt16 = delta > 0 ? (0x0200 | magnitude) : (0x0200 | 0x0100 | magnitude)
        onMouse?(flags, x, y)
    }

    override func keyDown(with e: NSEvent) {
        for u in (e.characters ?? "").utf16 { onKey?(u, true); onKey?(u, false) }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                       owner: self))
        super.updateTrackingAreas()
    }
}

// MARK: - RDPSession

@MainActor
final class RDPSession: RemoteSession {
    let id: Foundation.UUID
    let profile: RemoteProfile
    var onStateChange: ((RemoteSessionState) -> Void)?

    private let view = RDPFramebufferNSView()
    private let client: RDPClient

    init(profile: RemoteProfile, store: RemoteProfileStore) {
        self.id = profile.id
        self.profile = profile
        self.client = RDPClient(host: profile.host,
                                port: UInt16(clamping: profile.port),
                                username: profile.username,
                                password: store.password(for: profile) ?? "",
                                domain: "")
        view.wantsLayer = true
        view.onMouse = { [weak client] f, x, y in client?.sendMouse(flags: f, x: x, y: y) }
        view.onKey   = { [weak client] code, down in client?.sendUnicode(code, down: down) }
        client.onState = { [weak self] st in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onStateChange?(st) } }
        }
        client.onImage = { [weak self] img in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.view.setImage(img) } }
        }
    }

    func makeView() -> NSView { view }
    func connect() { onStateChange?(.connecting); client.start() }
    func disconnect() { client.stop() }
}
#endif
