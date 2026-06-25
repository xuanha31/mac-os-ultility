#if HAS_FREERDP
import Foundation
import AppKit
import CoreGraphics
import IOSurface
import CoreVideo
import Core
import CFreeRDP

// Logger riêng cho remote (chẩn đoán render/kết nối). Xem qua Console.app, subsystem
// com.macutil.app, category "remote".
private let rdpLog = Log.make("remote")

// RD Phase 2: phiên RDP dùng FreeRDP 3.x (C interop qua CFreeRDP).
// - Dùng API CLIENT đầy đủ (freerdp_client_context_new + RDP_CLIENT_ENTRY_POINTS) thay
//   vì freerdp_new() trần — để FreeRDP dựng đủ tầng client common (kênh, thương lượng
//   bảo mật) GIỐNG sdl-freerdp. Bản trần thiếu các callback chứng chỉ/đăng nhập nên NLA
//   thường rớt → connect fail, đúng lỗi "không kết nối được" gặp phải.
// - ClientNew đăng ký callback: PreConnect/PostConnect + VerifyCertificateEx /
//   VerifyChangedCertificateEx (auto-accept = /cert:ignore) + AuthenticateEx (dùng
//   credentials đã set sẵn) + LogonErrorInfo.
// - RDPClient chạy event loop trên thread nền, render GDI framebuffer → CGImage.
// - Callback C (@convention(c), không capture) tra ngược RDPClient qua registry theo
//   con trỏ rdpContext. RDPFramebufferNSView vẽ ảnh + forward chuột/bàn phím.
// - Connect fail → đọc freerdp_get_last_error_string để hiện lý do THẬT (NLA/TLS/cert…).

// MARK: - Registry: rdpContext* → RDPClient

final class RDPClientRegistry: @unchecked Sendable {
    static let shared = RDPClientRegistry()
    private var map: [UnsafeMutableRawPointer: RDPClient] = [:]
    private let lock = NSLock()
    func set(_ key: UnsafeMutableRawPointer, _ client: RDPClient) { lock.lock(); map[key] = client; lock.unlock() }
    func remove(_ key: UnsafeMutableRawPointer) { lock.lock(); map[key] = nil; lock.unlock() }
    func get(_ key: UnsafeMutableRawPointer) -> RDPClient? { lock.lock(); defer { lock.unlock() }; return map[key] }
}

// MARK: - C callbacks (@convention(c), không capture)

/// Entry point ClientNew: nơi chuẩn để gắn callback lên instance (chạy bên trong
/// freerdp_client_context_new, sau khi client common đã set default — ta ghi đè để
/// KHÔNG prompt stdin như client CLI mà tự động chấp nhận, dùng credentials đã set sẵn).
private func rdpClientNew(_ instance: UnsafeMutablePointer<freerdp>?,
                          _ context: UnsafeMutablePointer<rdpContext>?) -> ObjCBool {
    guard let instance else { return false }
    instance.pointee.PreConnect = rdpPreConnect
    instance.pointee.PostConnect = rdpPostConnect
    instance.pointee.AuthenticateEx = rdpAuthenticateEx
    instance.pointee.VerifyCertificateEx = rdpVerifyCertificateEx
    instance.pointee.VerifyChangedCertificateEx = rdpVerifyChangedCertificateEx
    instance.pointee.LogonErrorInfo = rdpLogonErrorInfo
    // Đăng ký handler kênh: khi GFX nối → gdi_graphics_pipeline_init đổ GFX vào primary_buffer.
    // Thêm handler riêng để bắt kênh cliprdr (clipboard) → gắn cầu nối NSPasteboard.
    if let context {
        cfreerdp_subscribe_channel_handlers(context)
        cfreerdp_subscribe_channel_connected(context, rdpChannelConnected)
    }
    return true
}

private func rdpClientFree(_ instance: UnsafeMutablePointer<freerdp>?,
                           _ context: UnsafeMutablePointer<rdpContext>?) {
    // gdi do FreeRDP tự giải phóng khi free context; không cần làm gì thêm ở đây.
}

private func rdpPreConnect(_ instance: UnsafeMutablePointer<freerdp>?) -> ObjCBool {
    guard let instance, let ctx = instance.pointee.context, let settings = ctx.pointee.settings else { return false }
    freerdp_settings_set_bool(settings, FreeRDP_SoftwareGdi, true)
    return true
}

private func rdpPostConnect(_ instance: UnsafeMutablePointer<freerdp>?) -> ObjCBool {
    guard let instance, let ctx = instance.pointee.context else { return false }
    if !gdi_init(instance, cfreerdp_pixel_format_bgra32()) { return false }
    ctx.pointee.update?.pointee.EndPaint = rdpEndPaint
    // BẮT BUỘC khi dùng GFX: ResetGraphics gọi update->DesktopResize, NULL → assert/abort
    // (crash gdi_ResetGraphics). gdi_ResetGraphics đã tự gdi_resize buffer; timer đọc lại
    // gdi.width/height/stride mỗi tick nên callback chỉ cần trả true.
    ctx.pointee.update?.pointee.DesktopResize = rdpDesktopResize
    return true
}

private func rdpDesktopResize(_ context: UnsafeMutablePointer<rdpContext>?) -> ObjCBool {
    return true
}

private func rdpEndPaint(_ context: UnsafeMutablePointer<rdpContext>?) -> ObjCBool {
    guard let context else { return false }
    RDPClientRegistry.shared.get(UnsafeMutableRawPointer(context))?.renderFrame()
    return true
}

/// Credentials đã set sẵn trong settings → chấp nhận, không hỏi (tránh prompt stdin).
private func rdpAuthenticateEx(_ instance: UnsafeMutablePointer<freerdp>?,
                               _ username: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                               _ password: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                               _ domain: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                               _ reason: rdp_auth_reason) -> ObjCBool {
    return true
}

/// Auto-accept chứng chỉ (tương đương /cert:ignore). 1 = chấp nhận cho phiên này.
private func rdpVerifyCertificateEx(_ instance: UnsafeMutablePointer<freerdp>?,
                                    _ host: UnsafePointer<CChar>?, _ port: UInt16,
                                    _ commonName: UnsafePointer<CChar>?,
                                    _ subject: UnsafePointer<CChar>?,
                                    _ issuer: UnsafePointer<CChar>?,
                                    _ fingerprint: UnsafePointer<CChar>?,
                                    _ flags: UInt32) -> UInt32 {
    return 1
}

private func rdpVerifyChangedCertificateEx(_ instance: UnsafeMutablePointer<freerdp>?,
                                           _ host: UnsafePointer<CChar>?, _ port: UInt16,
                                           _ commonName: UnsafePointer<CChar>?,
                                           _ subject: UnsafePointer<CChar>?,
                                           _ issuer: UnsafePointer<CChar>?,
                                           _ newFingerprint: UnsafePointer<CChar>?,
                                           _ oldSubject: UnsafePointer<CChar>?,
                                           _ oldIssuer: UnsafePointer<CChar>?,
                                           _ oldFingerprint: UnsafePointer<CChar>?,
                                           _ flags: UInt32) -> UInt32 {
    return 1
}

private func rdpLogonErrorInfo(_ instance: UnsafeMutablePointer<freerdp>?,
                               _ data: UInt32, _ type: UInt32) -> Int32 {
    return 1
}

// MARK: - RDPClient (thread nền)

final class RDPClient: @unchecked Sendable {
    var onState: ((RemoteSessionState) -> Void)?
    /// Cấp khung dưới dạng IOSurface (GPU-shared) thay cho CGImage → CA dùng trực tiếp làm
    /// texture, không alloc/copy CGImage mỗi khung → mượt ở 2.5K/3K.
    var onSurface: ((IOSurfaceRef) -> Void)?

    // Pool IOSurface luân phiên: ghi vào surface khác với surface CA đang hiển thị (tránh
    // tearing/đè), và đổi object mỗi khung để CA chịu cập nhật (tránh cache → đơ).
    private var surfacePool: [IOSurfaceRef] = []
    private var surfaceIndex = 0
    private var surfaceW = 0
    private var surfaceH = 0

    private let host: String
    private let port: UInt16
    private let username: String
    private let password: String
    private let domain: String
    private let width: Int
    private let height: Int

    private var context: UnsafeMutablePointer<rdpContext>?
    private var thread: Thread?
    private var running = false
    private var framesRendered = 0
    private var clipboard: RDPClipboard?
    private var dispContext: UnsafeMutablePointer<DispClientContext>?
    private var lastLayoutW = 0
    private var lastLayoutH = 0
    // Bảo vệ vòng đời context/dispContext: hàm gọi từ main (chuột/phím/resize/render) có thể
    // chạy trong khi thread nền cleanup() giải phóng context → use-after-free. Khoá để không
    // dùng con trỏ đã free (cleanup nil hoá + free dưới cùng khoá này).
    private let ctxLock = NSLock()

    /// Gọi từ handler "channel connected" khi kênh cliprdr nối.
    func attachClipboard(_ ctx: UnsafeMutablePointer<CliprdrClientContext>) {
        clipboard = RDPClipboard(ctx)
    }

    /// Gọi từ handler "channel connected" khi kênh disp (Display Control) nối.
    func attachDisp(_ ctx: UnsafeMutablePointer<DispClientContext>) {
        ctxLock.lock(); defer { ctxLock.unlock() }
        dispContext = ctx
        rdpLog.info("disp attached (dynamic resolution sẵn sàng)")
    }

    /// Yêu cầu server đổi độ phân giải desktop khớp kích thước cửa sổ (dynamic-resolution).
    /// Gọi từ main khi cửa sổ resize. Bỏ qua nếu kênh chưa sẵn / kích thước không đổi.
    func sendMonitorLayout(width: Int, height: Int) {
        ctxLock.lock(); defer { ctxLock.unlock() }
        guard let disp = dispContext else { return }
        var w = max(min(width, 8192), 200)
        var h = max(min(height, 8192), 200)
        if w % 2 != 0 { w -= 1 }
        if h % 2 != 0 { h -= 1 }
        guard w != lastLayoutW || h != lastLayoutH else { return }
        lastLayoutW = w; lastLayoutH = h
        var mon = DISPLAY_CONTROL_MONITOR_LAYOUT()
        mon.Flags = UInt32(DISPLAY_CONTROL_MONITOR_PRIMARY)
        mon.Left = 0; mon.Top = 0
        mon.Width = UInt32(w); mon.Height = UInt32(h)
        mon.Orientation = 0
        mon.DesktopScaleFactor = 100
        mon.DeviceScaleFactor = 100
        _ = disp.pointee.SendMonitorLayout?(disp, 1, &mon)
    }

    init(host: String, port: UInt16, username: String, password: String, domain: String,
         width: Int = 0, height: Int = 0) {
        self.host = host; self.port = port
        self.username = username; self.password = password; self.domain = domain
        self.width = width; self.height = height
    }

    func start() {
        let t = Thread { [weak self] in self?.run() }
        t.stackSize = 4 << 20
        thread = t
        running = true
        t.start()
    }

    /// Chuyển [String] → (argc, char**) tạm thời cho hàm parse C; tự free sau khi dùng.
    private static func withCStringArray<R>(_ strings: [String],
                                            _ body: (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var cStrings: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        cStrings.append(nil) // argv kết thúc bằng NULL
        defer { for p in cStrings where p != nil { free(p) } }
        return cStrings.withUnsafeMutableBufferPointer { buf in
            body(Int32(strings.count), buf.baseAddress!)
        }
    }

    func stop() {
        running = false
        ctxLock.lock(); defer { ctxLock.unlock() }
        if let ctx = context { freerdp_abort_connect_context(ctx) }
    }

    private func run() {
        // Reset state để tái sử dụng client cho reconnect (run() có thể chạy lại nhiều lần).
        ctxLock.lock()
        framesRendered = 0
        lastLayoutW = 0; lastLayoutH = 0
        ctxLock.unlock()

        // Dựng entry points cho client API. ClientNew sẽ gắn các callback lên instance.
        var entry = RDP_CLIENT_ENTRY_POINTS()
        entry.Size = UInt32(MemoryLayout<RDP_CLIENT_ENTRY_POINTS>.size)
        entry.Version = cfreerdp_client_interface_version()
        entry.ContextSize = cfreerdp_context_size()
        entry.ClientNew = rdpClientNew
        entry.ClientFree = rdpClientFree

        guard let ctx = freerdp_client_context_new(&entry) else {
            onState?(.failed("freerdp_client_context_new lỗi")); return
        }
        context = ctx
        guard let inst = ctx.pointee.instance, let settings = ctx.pointee.settings else {
            onState?(.failed("context.instance/settings lỗi")); cleanup(); return
        }

        // Cấu hình QUA parse command-line như sdl-freerdp — KHÔNG set tay từng setting.
        // Set tay thiếu các mặc định về capabilities/codecs/order-support → server gửi
        // DEACTIVATE_ALL ở bước activation → freerdp_post_connect failed. parse_command_line
        // dựng đủ bộ mặc định nhất quán nên kết nối được.
        // Password KHÔNG đưa vào argv (tránh lộ qua ps) → set riêng qua API sau khi parse.
        var args = ["MacUtil", "/cert:ignore", "/dynamic-resolution", "/clipboard"]
        if width > 0, height > 0 { args.append("/size:\(width)x\(height)") }
        args.append("/v:\(host):\(port)")
        if !username.isEmpty { args.append("/u:\(username)") }
        if !domain.isEmpty   { args.append("/d:\(domain)") }
        let parseRC = Self.withCStringArray(args) { argc, argv in
            freerdp_client_settings_parse_command_line_arguments(settings, argc, argv, false)
        }
        guard parseRC == 0 else {
            onState?(.failed("Cấu hình RDP lỗi (parse_command_line rc=\(parseRC))")); cleanup(); return
        }
        if !password.isEmpty { freerdp_settings_set_string(settings, FreeRDP_Password, password) }
        // Chẩn đoán auth: log USER + ĐỘ DÀI password (không log password). passLen=0 → chưa lưu
        // mật khẩu (bẫy "để trống khi sửa"); passLen khác độ dài thật → sai mật khẩu.
        rdpLog.info("RDP auth user=\(self.username.isEmpty ? "(empty)" : self.username, privacy: .public) passLen=\(self.password.count)")
        // GFX giữ BẬT (server này yêu cầu — tắt là từ chối kết nối). Việc đổ GFX vào
        // gdi.primary_buffer do handler kênh (đăng ký ở rdpClientNew) tự lo qua
        // gdi_graphics_pipeline_init.

        RDPClientRegistry.shared.set(UnsafeMutableRawPointer(ctx), self)

        onState?(.connecting)
        if !freerdp_connect(inst) {
            let code = freerdp_get_last_error(ctx)
            let name = freerdp_get_last_error_name(code).map { String(cString: $0) } ?? "?"
            let detail = freerdp_get_last_error_string(code).map { String(cString: $0) } ?? ""
            let hex = String(code, radix: 16)
            onState?(.failed("RDP thất bại: \(detail) [\(name), 0x\(hex)]"))
            cleanup(); return
        }
        let gfxOn = freerdp_settings_get_bool(settings, FreeRDP_SupportGraphicsPipeline)
        rdpLog.info("RDP connected \(self.host):\(self.port) GFX=\(gfxOn)")
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
        ctxLock.lock(); defer { ctxLock.unlock() }
        guard let ctx = context,
              let gdi = ctx.pointee.gdi, let buf = gdi.pointee.primary_buffer else { return }
        let w = Int(gdi.pointee.width), h = Int(gdi.pointee.height), stride = Int(gdi.pointee.stride)
        guard w > 0, h > 0, stride > 0 else { return }

        if framesRendered == 0 {
            var nonZero = false
            for i in 0..<min(stride * h, 4096) where buf[i] != 0 { nonZero = true; break }
            rdpLog.info("RDP first frame \(w)x\(h) stride=\(stride) nonZeroPixels=\(nonZero)")
        }
        framesRendered += 1

        // (Re)tạo pool nếu kích thước đổi (dynamic-resolution).
        if surfaceW != w || surfaceH != h || surfacePool.isEmpty { rebuildSurfacePool(w: w, h: h) }
        guard !surfacePool.isEmpty else { return }

        let surf = surfacePool[surfaceIndex]
        surfaceIndex = (surfaceIndex + 1) % surfacePool.count

        IOSurfaceLock(surf, [], nil)
        let dst = IOSurfaceGetBaseAddress(surf)
        let dstStride = IOSurfaceGetBytesPerRow(surf)
        let rowBytes = min(w * 4, stride, dstStride)
        for row in 0..<h {
            memcpy(dst.advanced(by: row * dstStride), buf.advanced(by: row * stride), rowBytes)
        }
        IOSurfaceUnlock(surf, [], nil)
        onSurface?(surf)
    }

    private func rebuildSurfacePool(w: Int, h: Int) {
        surfacePool.removeAll()
        let props: [CFString: Any] = [
            kIOSurfaceWidth: w,
            kIOSurfaceHeight: h,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: Int(kCVPixelFormatType_32BGRA)
        ]
        for _ in 0..<3 {
            if let s = IOSurfaceCreate(props as CFDictionary) { surfacePool.append(s) }
        }
        surfaceIndex = 0
        surfaceW = w; surfaceH = h
    }

    func sendMouse(flags: UInt16, x: UInt16, y: UInt16) {
        ctxLock.lock(); defer { ctxLock.unlock() }
        guard let ctx = context, let input = ctx.pointee.input else {
            if flags & 0x8000 != 0 { rdpLog.info("sendMouse DROPPED (ctx/input nil)") }
            return
        }
        _ = freerdp_input_send_mouse_event(input, flags, x, y)
        if flags & 0x8000 != 0 { rdpLog.info("sendMouse click flags=0x\(String(flags, radix: 16)) at \(x),\(y)") }
    }

    func sendUnicode(_ code: UInt16, down: Bool) {
        ctxLock.lock(); defer { ctxLock.unlock() }
        guard let ctx = context, let input = ctx.pointee.input else { return }
        _ = freerdp_input_send_unicode_keyboard_event(input, down ? 0 : 0x8000, code) // 0x8000 = KBD_FLAGS_RELEASE
    }

    /// Gửi phím theo SCANCODE (PC/AT set 1). Server Linux (gnome-remote-desktop/xrdp)
    /// thường bỏ qua unicode keyboard nên dùng scancode mới gõ được.
    func sendScancode(_ rdpScancode: UInt16, down: Bool) {
        ctxLock.lock(); defer { ctxLock.unlock() }
        guard let ctx = context, let input = ctx.pointee.input else {
            if down { rdpLog.info("sendScancode 0x\(String(rdpScancode, radix: 16)) DROPPED (ctx/input nil)") }
            return
        }
        _ = freerdp_input_send_keyboard_event_ex(input, down, false, UInt32(rdpScancode))
        if down { rdpLog.info("sendScancode 0x\(String(rdpScancode, radix: 16)) sent") }
    }

    private func cleanup() {
        clipboard?.stop()
        clipboard = nil
        // Nil hoá con trỏ DƯỚI khoá để hàm trên main (chuột/phím/resize/render) đang/đợi khoá
        // không dùng context đã free. Sau khi nil + mở khoá mới free (an toàn vì không ai
        // còn lấy được con trỏ hợp lệ).
        ctxLock.lock()
        let ctx = context
        context = nil
        dispContext = nil
        ctxLock.unlock()
        if let ctx {
            RDPClientRegistry.shared.remove(UnsafeMutableRawPointer(ctx))
            freerdp_client_context_free(ctx)
        }
    }
}

// MARK: - NSView vẽ framebuffer + input

final class RDPFramebufferNSView: NSView {
    var onMouse: ((UInt16, UInt16, UInt16) -> Void)?
    var onKey: ((UInt16, Bool) -> Void)?     // scancode (mac keyCode → session ánh xạ)

    private var surface: IOSurfaceRef?

    override var acceptsFirstResponder: Bool { true }
    // Không override isFlipped (mặc định false, gốc dưới-trái). Render bằng layer.contents =
    // IOSurface (GPU-shared): CA dùng trực tiếp làm texture, vẽ ĐÚNG CHIỀU + co giãn theo
    // contentsGravity, chạy cả khi tách cửa sổ. Pool đổi object mỗi khung → CA không cache.
    func setSurface(_ s: IOSurfaceRef) {
        surface = s
        // Chuyển cửa sổ (tách/gộp) có thể tắt layer-backing → tự bật lại để khỏi đen.
        if !wantsLayer { wantsLayer = true }
        layer?.contents = s
    }

    private func remotePoint(_ event: NSEvent) -> (UInt16, UInt16) {
        var p = convert(event.locationInWindow, from: nil)
        guard let surface, bounds.width > 0, bounds.height > 0 else { return (0, 0) }
        let iw = CGFloat(IOSurfaceGetWidth(surface)), ih = CGFloat(IOSurfaceGetHeight(surface))
        p.y = bounds.height - p.y   // view không flip → đổi gốc về trên-trái như RDP
        let rx = max(0, min(iw - 1, p.x / bounds.width * iw))
        let ry = max(0, min(ih - 1, p.y / bounds.height * ih))
        return (UInt16(rx), UInt16(ry))
    }

    // PTR_FLAGS: MOVE=0x0800, DOWN=0x8000, BUTTON1=0x1000, BUTTON2=0x2000, WHEEL=0x0200
    override func mouseMoved(with e: NSEvent)    { let (x, y) = remotePoint(e); onMouse?(0x0800, x, y) }
    override func mouseDragged(with e: NSEvent)  { let (x, y) = remotePoint(e); onMouse?(0x0800, x, y) }
    override func mouseDown(with e: NSEvent)     {
        window?.makeFirstResponder(self)
        rdpLog.info("view mouseDown keyWin=\(self.window?.isKeyWindow == true) firstResp=\(self.window?.firstResponder === self) onMouse=\(self.onMouse != nil)")
        let (x, y) = remotePoint(e); onMouse?(0x8000 | 0x1000, x, y)
    }
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

    // Bàn phím: gửi theo macOS keyCode → scancode (down/up riêng để giữ phím, lặp đúng).
    // Ổn định cho gõ ASCII/phím tắt/phím đặc biệt. Gõ tiếng Việt (IME) dùng clipboard paste.
    override func keyDown(with e: NSEvent) {
        rdpLog.info("view keyDown code=\(e.keyCode) keyWin=\(self.window?.isKeyWindow == true) firstResp=\(self.window?.firstResponder === self) onKey=\(self.onKey != nil)")
        onKey?(e.keyCode, true)
    }
    override func keyUp(with e: NSEvent) { onKey?(e.keyCode, false) }

    private var lastFlags: NSEvent.ModifierFlags = []
    override func flagsChanged(with e: NSEvent) {
        let f = e.modifierFlags
        // mac keyCode của modifier trái → onKey ánh xạ sang RDP scancode.
        func sync(_ flag: NSEvent.ModifierFlags, _ macKeyCode: UInt16) {
            let now = f.contains(flag), was = lastFlags.contains(flag)
            if now != was { onKey?(macKeyCode, now) }
        }
        sync(.shift,   0x38)   // Left Shift
        sync(.control, 0x3B)   // Left Control
        sync(.option,  0x3A)   // Left Option/Alt
        sync(.command, 0x37)   // Left Command → Super
        lastFlags = f
    }

    // Nhận phím ngay khi tab hiện ra (không cần click trước). Đồng thời khôi phục layer
    // khi chuyển cửa sổ (tách/gộp): AppKit có thể tạo lại backing layer → mất
    // contents/gravity/backgroundColor (→ màn đen). Đặt lại + vẽ ngay khung gần nhất.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.backgroundColor = NSColor.black.cgColor
        if let surface { layer?.contents = surface }
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                       owner: self))
        super.updateTrackingAreas()
    }

    // MARK: - Resize (dynamic resolution)

    /// Báo kích thước PIXEL mới (debounce) để session gửi monitor layout cho server.
    var onResize: ((Int, Int) -> Void)?
    private var resizeWork: DispatchWorkItem?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleResizeReport()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        scheduleResizeReport()
    }

    private func scheduleResizeReport() {
        guard onResize != nil, bounds.width > 1, bounds.height > 1 else { return }
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Kích thước pixel thực (Retina) → desktop khớp 1:1, nét, không kéo căng.
            let px = self.convertToBacking(NSRect(origin: .zero, size: self.bounds.size)).size
            let w = Int(px.width.rounded()), h = Int(px.height.rounded())
            if w > 1, h > 1 { self.onResize?(w, h) }
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}

// MARK: - Bảng phím

/// macOS virtual keyCode (kVK_*) → RDP scancode (PC/AT set 1 make code).
/// Đủ cho bàn phím US-ANSI: chữ, số, ký hiệu, Enter/Tab/Space/Backspace/Esc, modifier.
private let macKeyToRDPScancode: [UInt16: UInt16] = [
    0x00: 0x1E, 0x0B: 0x30, 0x08: 0x2E, 0x02: 0x20, 0x0E: 0x12, 0x03: 0x21, // A B C D E F
    0x05: 0x22, 0x04: 0x23, 0x22: 0x17, 0x26: 0x24, 0x28: 0x25, 0x25: 0x26, // G H I J K L
    0x2E: 0x32, 0x2D: 0x31, 0x1F: 0x18, 0x23: 0x19, 0x0C: 0x10, 0x0F: 0x13, // M N O P Q R
    0x01: 0x1F, 0x11: 0x14, 0x20: 0x16, 0x09: 0x2F, 0x0D: 0x11, 0x07: 0x2D, // S T U V W X
    0x10: 0x15, 0x06: 0x2C,                                                 // Y Z
    0x12: 0x02, 0x13: 0x03, 0x14: 0x04, 0x15: 0x05, 0x17: 0x06,             // 1 2 3 4 5
    0x16: 0x07, 0x1A: 0x08, 0x1C: 0x09, 0x19: 0x0A, 0x1D: 0x0B,             // 6 7 8 9 0
    0x24: 0x1C, // Return        0x30: Tab     0x31: Space   0x33: Backspace  0x35: Esc
    0x30: 0x0F, 0x31: 0x39, 0x33: 0x0E, 0x35: 0x01,
    0x1B: 0x0C, 0x18: 0x0D, // - =
    0x21: 0x1A, 0x1E: 0x1B, // [ ]
    0x2A: 0x2B, 0x29: 0x27, 0x27: 0x28, 0x32: 0x29, // backslash ; ' `
    0x2B: 0x33, 0x2F: 0x34, 0x2C: 0x35, // , . /
    // Modifiers (trái)
    0x38: 0x2A, // Left Shift
    0x3B: 0x1D, // Left Control
    0x3A: 0x38, // Left Option/Alt
    0x37: 0x5B, // Left Command → Super/Win
    // Phím MỞ RỘNG: scancode | KBDEXT(0x100). Thiếu bit này → phím mũi tên/điều hướng
    // không ăn trên remote.
    0x7B: 0x14B, // ← Left      (0x4B | 0x100)
    0x7C: 0x14D, // → Right     (0x4D | 0x100)
    0x7D: 0x150, // ↓ Down      (0x50 | 0x100)
    0x7E: 0x148, // ↑ Up        (0x48 | 0x100)
    0x73: 0x147, // Home        (0x47 | 0x100)
    0x77: 0x14F, // End         (0x4F | 0x100)
    0x74: 0x149, // Page Up     (0x49 | 0x100)
    0x79: 0x151, // Page Down   (0x51 | 0x100)
    0x75: 0x153, // Forward Delete (0x53 | 0x100)
]

// MARK: - RDPSession

@MainActor
final class RDPSession: RemoteSession {
    let id: Foundation.UUID
    let profile: RemoteProfile
    var onStateChange: ((RemoteSessionState) -> Void)?

    private let view = RDPFramebufferNSView()
    private let client: RDPClient
    // Render bằng timer đọc gdi.primary_buffer (~30fps khi đã kết nối). GFX không gọi EndPaint
    // nên không thể dựa vào callback; primary_buffer luôn được mọi đường update ghi vào.
    private var renderTimer: Timer?

    // Auto-reconnect: chỉ thử lại khi rớt mạng/đứt kết nối (KHÔNG khi user tự đóng).
    private var userClosed = false
    private var reconnectAttempt = 0
    private var reconnectWork: DispatchWorkItem?

    // Scale hiển thị (dynamic-resolution): độ phân giải remote = pixel cửa sổ × 100/scale.
    private var dynamicResize = false
    private var scalePercent = 100
    private var lastViewPxW = 0
    private var lastViewPxH = 0

    init(profile: RemoteProfile, store: RemoteProfileStore) {
        self.id = profile.id
        self.profile = profile
        let (w, h) = Self.resolveSize(profile.resolution ?? .auto)
        self.client = RDPClient(host: profile.host,
                                port: UInt16(clamping: profile.port),
                                username: profile.username,
                                password: store.password(for: profile) ?? "",
                                domain: "",
                                width: w, height: h)
        view.wantsLayer = true
        view.layer?.contentsGravity = .resize   // kéo đầy khung (khớp cách map toạ độ chuột)
        view.layer?.backgroundColor = NSColor.black.cgColor
        // KHÔNG live dynamic-resolution: Desktop Sharing không đổi được độ phân giải tuỳ ý của
        // phiên đang chia sẻ (monitor vật lý/headless cố định mode) → gửi monitor layout làm
        // lệch độ phân giải/surface → mờ + map chuột sai. Giữ độ phân giải gốc của phiên,
        // IOSurface co giãn lấp cửa sổ. Muốn nét/to hơn: đổi độ phân giải MÀN HÌNH bên Ubuntu.
        view.onMouse = { [weak client] f, x, y in client?.sendMouse(flags: f, x: x, y: y) }
        view.onKey   = { [weak client] macKeyCode, down in
            guard let rdp = macKeyToRDPScancode[macKeyCode] else { return }
            client?.sendScancode(rdp, down: down)
        }
        client.onState = { [weak self] st in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self else { return }
                switch st {
                case .connected:
                    self.reconnectAttempt = 0
                    self.onStateChange?(.connected)
                    self.startRenderTimer(); self.reclaimFocusSoon()
                case .disconnected:
                    self.stopRenderTimer()
                    if self.userClosed { self.onStateChange?(.disconnected) }
                    else { self.scheduleReconnect(reason: nil) }
                case .failed(let msg):
                    self.stopRenderTimer()
                    if self.userClosed { self.onStateChange?(.failed(msg)) }
                    else { self.scheduleReconnect(reason: msg) }   // giữ lý do thật để hiển thị
                case .connecting:
                    self.onStateChange?(.connecting)
                }
            } }
        }
        client.onSurface = { [weak self] surf in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.view.setSurface(surf) } }
        }
    }

    deinit { renderTimer?.invalidate() }

    /// Quy đổi RemoteResolution → (rộng, cao) cho FreeRDP. (0,0) = KHÔNG gửi /size.
    /// Auto = để SERVER tự quyết: Desktop Sharing dùng đúng độ phân giải phiên đang chạy
    /// (ép /size lớn hơn sẽ làm desktop nằm góc + viền trắng/vỡ hình). Muốn ép độ phân giải
    /// cao (vd Remote Login) thì chọn preset. Preset cap 3840×2160, làm tròn chẵn.
    private static func resolveSize(_ res: RemoteResolution) -> (Int, Int) {
        guard let s = res.size else { return (0, 0) }   // Auto → không ép /size
        return s
    }

    /// Sau khi kết nối, một loạt re-render đôi lúc kéo cửa sổ chính lên key → "bay" khỏi màn
    /// remote. Giành lại key + first responder cho cửa sổ chứa view remote (nhúng hoặc tách),
    /// thử vài nhịp đầu để bắt mọi thời điểm bị giật.
    private func reclaimFocusSoon() {
        for delay in [0.3, 0.8, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let win = self.view.window else { return }
                win.makeKey()
                win.makeFirstResponder(self.view)
            }
        }
    }

    private func startRenderTimer() {
        stopRenderTimer()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.client.renderFrame()
        }
        // .common để vẫn vẽ khi đang kéo/resize cửa sổ.
        RunLoop.main.add(t, forMode: .common)
        renderTimer = t
    }

    private func stopRenderTimer() {
        renderTimer?.invalidate()
        renderTimer = nil
    }

    /// Lên lịch kết nối lại sau khi rớt mạng/đứt kết nối, backoff tăng dần (tối đa 20s), thử
    /// vô hạn cho tới khi có mạng/thành công hoặc user đóng tab.
    private func scheduleReconnect(reason: String?) {
        guard !userClosed else { return }
        reconnectWork?.cancel()
        reconnectAttempt += 1
        let delay = min(Double(reconnectAttempt) * 2.0, 20.0)
        let why = (reason?.isEmpty == false) ? reason! : "Mất kết nối"
        onStateChange?(.failed("\(why)\nTự kết nối lại sau \(Int(delay))s (lần \(reconnectAttempt))…"))
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.userClosed else { return }
            self.onStateChange?(.connecting)
            self.client.start()   // tái sử dụng client: run() mở context mới
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Scale / dynamic resolution

    private func handleResize(pxW: Int, pxH: Int) {
        lastViewPxW = pxW; lastViewPxH = pxH
        sendScaledLayout()
    }

    /// Đặt scale (%). 100 = 1:1; cao hơn → UI to hơn (độ phân giải remote nhỏ lại, phóng lên khung).
    func setScale(_ percent: Int) {
        guard dynamicResize else { return }
        scalePercent = max(50, min(300, percent))
        sendScaledLayout()
    }

    private func sendScaledLayout() {
        guard dynamicResize, lastViewPxW > 0, lastViewPxH > 0 else { return }
        client.sendMonitorLayout(width: lastViewPxW * 100 / scalePercent,
                                 height: lastViewPxH * 100 / scalePercent)
    }

    func makeView() -> NSView { view }
    func connect() { userClosed = false; onStateChange?(.connecting); client.start() }
    func disconnect() {
        userClosed = true                 // user chủ động đóng → không auto-reconnect
        reconnectWork?.cancel(); reconnectWork = nil
        stopRenderTimer(); client.stop()
    }
}
#endif
