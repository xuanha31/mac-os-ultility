#if HAS_FREERDP
import Foundation
import AppKit
import Core
import CFreeRDP

private let clipLog = Log.make("remote")

// CF_UNICODETEXT — định danh clipboard chuẩn của Windows cho text UTF-16LE (kết NUL).
private let kCF_UNICODETEXT: UInt32 = 13

/// Cầu nối clipboard RDP (kênh cliprdr) ↔ NSPasteboard của macOS — TEXT 2 chiều (Phase A).
/// FreeRDP chỉ cấp kênh; phần đồng bộ dữ liệu do lớp này tự lo.
/// Callback cliprdr chạy trên thread kênh (nền); ghi NSPasteboard đẩy về main.
final class RDPClipboard: @unchecked Sendable {
    private let cliprdr: UnsafeMutablePointer<CliprdrClientContext>
    private var pollTimer: DispatchSourceTimer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    // Text đã đồng bộ gần nhất (cả 2 chiều). Dùng để CHỐNG LẶP theo nội dung: server có thể
    // gửi format list định kỳ → nếu cứ ghi lại pasteboard mỗi giây sẽ tạo nhiễu liên tục
    // (đụng clipboard app → re-render → giật focus). Chỉ ghi/quảng bá khi text THỰC SỰ khác.
    private var lastText: String?

    init(_ ctx: UnsafeMutablePointer<CliprdrClientContext>) {
        self.cliprdr = ctx
        ctx.pointee.custom = Unmanaged.passUnretained(self).toOpaque()
        ctx.pointee.MonitorReady = rdpCliprdrMonitorReady
        ctx.pointee.ServerFormatList = rdpCliprdrServerFormatList
        ctx.pointee.ServerFormatDataRequest = rdpCliprdrServerFormatDataRequest
        ctx.pointee.ServerFormatDataResponse = rdpCliprdrServerFormatDataResponse
        clipLog.info("cliprdr attached")
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    // MARK: - Remote → Mac

    /// Remote "sẵn sàng" → gửi capabilities + quảng bá clipboard hiện tại của Mac, bật poll.
    func onMonitorReady() {
        sendCapabilities()
        advertiseLocalClipboard()
        startPolling()
    }

    /// Remote đổi clipboard → nếu có text thì xin dữ liệu để bỏ vào NSPasteboard.
    func onServerFormatList(_ list: UnsafePointer<CLIPRDR_FORMAT_LIST>) {
        let n = Int(list.pointee.numFormats)
        var hasText = false
        if let formats = list.pointee.formats {
            for i in 0..<n where formats[i].formatId == kCF_UNICODETEXT { hasText = true }
        }
        guard hasText else { return }
        var req = CLIPRDR_FORMAT_DATA_REQUEST()
        req.requestedFormatId = kCF_UNICODETEXT
        _ = cliprdr.pointee.ClientFormatDataRequest?(cliprdr, &req)
    }

    /// Remote trả dữ liệu cho yêu cầu của ta (text remote) → ghi vào NSPasteboard.
    func onServerFormatDataResponse(_ resp: UnsafePointer<CLIPRDR_FORMAT_DATA_RESPONSE>) {
        guard (resp.pointee.common.msgFlags & UInt16(CB_RESPONSE_OK)) != 0,
              let data = resp.pointee.requestedFormatData else { return }
        let len = Int(resp.pointee.common.dataLen)
        guard len >= 2 else { return }
        // UTF-16LE (có thể kèm NUL cuối) → String.
        var units = [UInt16]()
        var i = 0
        while i + 1 < len {
            let u = UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
            if u == 0 { break }
            units.append(u); i += 2
        }
        let text = String(decoding: units, as: UTF16.self)
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            // Chống lặp: đã đồng bộ rồi (server gửi lại cái ta đang có) → bỏ qua, đừng
            // ghi lại (tránh đụng changeCount mỗi giây → giật focus).
            guard text != self.lastText, text != pb.string(forType: .string) else { return }
            self.lastText = text
            pb.clearContents()
            pb.setString(text, forType: .string)
            self.lastChangeCount = pb.changeCount
        }
    }

    // MARK: - Mac → Remote

    /// Remote xin clipboard của ta để paste → trả text NSPasteboard dạng UTF-16LE.
    func onServerFormatDataRequest(_ req: UnsafePointer<CLIPRDR_FORMAT_DATA_REQUEST>) {
        var resp = CLIPRDR_FORMAT_DATA_RESPONSE()
        if req.pointee.requestedFormatId == kCF_UNICODETEXT,
           let s = NSPasteboard.general.string(forType: .string) {
            var bytes = [UInt8]()
            bytes.reserveCapacity(s.utf16.count * 2 + 2)
            for u in s.utf16 { bytes.append(UInt8(u & 0xFF)); bytes.append(UInt8(u >> 8)) }
            bytes.append(0); bytes.append(0)   // NUL UTF-16
            resp.common.msgFlags = UInt16(CB_RESPONSE_OK)
            resp.common.dataLen = UInt32(bytes.count)
            bytes.withUnsafeBufferPointer { p in
                resp.requestedFormatData = p.baseAddress
                _ = cliprdr.pointee.ClientFormatDataResponse?(cliprdr, &resp)
            }
        } else {
            resp.common.msgFlags = UInt16(CB_RESPONSE_FAIL)
            _ = cliprdr.pointee.ClientFormatDataResponse?(cliprdr, &resp)
        }
    }

    // MARK: - Helpers

    private func sendCapabilities() {
        var general = CLIPRDR_GENERAL_CAPABILITY_SET()
        general.capabilitySetType = UInt16(CB_CAPSTYPE_GENERAL)
        general.capabilitySetLength = UInt16(CB_CAPSTYPE_GENERAL_LEN)
        general.version = UInt32(CB_CAPS_VERSION_2)
        general.generalFlags = UInt32(CB_USE_LONG_FORMAT_NAMES)
        withUnsafeMutablePointer(to: &general) { gp in
            var caps = CLIPRDR_CAPABILITIES()
            caps.cCapabilitiesSets = 1
            caps.capabilitySets = UnsafeMutableRawPointer(gp).assumingMemoryBound(to: CLIPRDR_CAPABILITY_SET.self)
            _ = cliprdr.pointee.ClientCapabilities?(cliprdr, &caps)
        }
    }

    /// Quảng bá format list: NSPasteboard có text → quảng bá CF_UNICODETEXT (rỗng nếu không).
    func advertiseLocalClipboard() {
        let hasText = NSPasteboard.general.string(forType: .string) != nil
        var fmt = CLIPRDR_FORMAT()
        fmt.formatId = kCF_UNICODETEXT
        fmt.formatName = nil
        withUnsafeMutablePointer(to: &fmt) { fp in
            var list = CLIPRDR_FORMAT_LIST()
            list.numFormats = hasText ? 1 : 0
            list.formats = hasText ? fp : nil
            _ = cliprdr.pointee.ClientFormatList?(cliprdr, &list)
        }
    }

    private func startPolling() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let cc = NSPasteboard.general.changeCount
            guard cc != self.lastChangeCount else { return }
            self.lastChangeCount = cc
            let text = NSPasteboard.general.string(forType: .string)
            // Chỉ quảng bá khi nội dung khác lần đồng bộ trước (không phải do chính ta vừa ghi).
            guard text != self.lastText else { return }
            self.lastText = text
            self.advertiseLocalClipboard()
        }
        pollTimer = t
        t.resume()
    }
}

// MARK: - C callbacks (@convention(c), không capture)

private func clip(_ ctx: UnsafeMutablePointer<CliprdrClientContext>?) -> RDPClipboard? {
    guard let custom = ctx?.pointee.custom else { return nil }
    return Unmanaged<RDPClipboard>.fromOpaque(custom).takeUnretainedValue()
}

/// Handler "channel connected": khi kênh cliprdr nối → tra RDPClient qua registry để gắn cầu nối.
func rdpCliprdrChannelConnected(_ context: UnsafeMutableRawPointer?,
                                _ e: UnsafePointer<ChannelConnectedEventArgs>?) {
    guard let context, let e, let namePtr = e.pointee.name else { return }
    guard String(cString: namePtr) == CLIPRDR_SVC_CHANNEL_NAME, let iface = e.pointee.pInterface else { return }
    let cliprdr = iface.assumingMemoryBound(to: CliprdrClientContext.self)
    RDPClientRegistry.shared.get(context)?.attachClipboard(cliprdr)
}

private func rdpCliprdrMonitorReady(_ ctx: UnsafeMutablePointer<CliprdrClientContext>?,
                                    _ m: UnsafePointer<CLIPRDR_MONITOR_READY>?) -> UInt32 {
    clip(ctx)?.onMonitorReady(); return 0
}
private func rdpCliprdrServerFormatList(_ ctx: UnsafeMutablePointer<CliprdrClientContext>?,
                                        _ list: UnsafePointer<CLIPRDR_FORMAT_LIST>?) -> UInt32 {
    if let list { clip(ctx)?.onServerFormatList(list) }
    return 0
}
private func rdpCliprdrServerFormatDataRequest(_ ctx: UnsafeMutablePointer<CliprdrClientContext>?,
                                               _ req: UnsafePointer<CLIPRDR_FORMAT_DATA_REQUEST>?) -> UInt32 {
    if let req { clip(ctx)?.onServerFormatDataRequest(req) }
    return 0
}
private func rdpCliprdrServerFormatDataResponse(_ ctx: UnsafeMutablePointer<CliprdrClientContext>?,
                                                _ resp: UnsafePointer<CLIPRDR_FORMAT_DATA_RESPONSE>?) -> UInt32 {
    if let resp { clip(ctx)?.onServerFormatDataResponse(resp) }
    return 0
}
#endif
