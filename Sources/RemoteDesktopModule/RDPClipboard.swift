#if HAS_FREERDP
import Foundation
import AppKit
import Core
import CFreeRDP

private let clipLog = Log.make("remote")

// Định danh clipboard chuẩn của Windows.
private let kCF_UNICODETEXT: UInt32 = 13   // text UTF-16LE (kết NUL)
private let kCF_DIB: UInt32 = 8            // ảnh DIB (BITMAPINFOHEADER + pixel, không file header)

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
    private var lastImage: Data?          // DIB ảnh đã đồng bộ gần nhất (chống lặp ảnh)
    private var pendingFormat: UInt32 = 0 // format ta vừa xin từ server (để giải mã response đúng)

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

    /// Remote đổi clipboard → ưu tiên xin text, không thì xin ảnh (DIB), để bỏ vào NSPasteboard.
    func onServerFormatList(_ list: UnsafePointer<CLIPRDR_FORMAT_LIST>) {
        let n = Int(list.pointee.numFormats)
        var hasText = false, hasImage = false
        if let formats = list.pointee.formats {
            for i in 0..<n {
                if formats[i].formatId == kCF_UNICODETEXT { hasText = true }
                if formats[i].formatId == kCF_DIB { hasImage = true }
            }
        }
        let want: UInt32
        if hasText { want = kCF_UNICODETEXT } else if hasImage { want = kCF_DIB } else { return }
        pendingFormat = want
        var req = CLIPRDR_FORMAT_DATA_REQUEST()
        req.requestedFormatId = want
        _ = cliprdr.pointee.ClientFormatDataRequest?(cliprdr, &req)
    }

    /// Remote trả dữ liệu cho yêu cầu của ta → ghi vào NSPasteboard (text hoặc ảnh).
    func onServerFormatDataResponse(_ resp: UnsafePointer<CLIPRDR_FORMAT_DATA_RESPONSE>) {
        guard (resp.pointee.common.msgFlags & UInt16(CB_RESPONSE_OK)) != 0,
              let data = resp.pointee.requestedFormatData else { return }
        let len = Int(resp.pointee.common.dataLen)
        guard len > 0 else { return }

        if pendingFormat == kCF_DIB {
            let dib = Data(bytes: data, count: len)
            guard let bmp = bmpFromDIB(dib), let img = NSImage(data: bmp) else { return }
            DispatchQueue.main.async {
                guard dib != self.lastImage else { return }   // chống lặp ảnh
                self.lastImage = dib
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([img])
                self.lastChangeCount = pb.changeCount
            }
            return
        }

        // Mặc định: text UTF-16LE (có thể kèm NUL cuối) → String.
        guard len >= 2 else { return }
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
            // Chống lặp: đã đồng bộ rồi (server gửi lại cái ta đang có) → bỏ qua.
            guard text != self.lastText, text != pb.string(forType: .string) else { return }
            self.lastText = text
            pb.clearContents()
            pb.setString(text, forType: .string)
            self.lastChangeCount = pb.changeCount
        }
    }

    // MARK: - Mac → Remote

    /// Remote xin clipboard của ta để paste → trả text (UTF-16LE) hoặc ảnh (DIB).
    func onServerFormatDataRequest(_ req: UnsafePointer<CLIPRDR_FORMAT_DATA_REQUEST>) {
        let fmt = req.pointee.requestedFormatId
        var payload: [UInt8]?
        if fmt == kCF_UNICODETEXT, let s = NSPasteboard.general.string(forType: .string) {
            var bytes = [UInt8](); bytes.reserveCapacity(s.utf16.count * 2 + 2)
            for u in s.utf16 { bytes.append(UInt8(u & 0xFF)); bytes.append(UInt8(u >> 8)) }
            bytes.append(0); bytes.append(0)   // NUL UTF-16
            payload = bytes
        } else if fmt == kCF_DIB, let dib = dibFromPasteboardImage() {
            payload = [UInt8](dib)
        }

        var resp = CLIPRDR_FORMAT_DATA_RESPONSE()
        if let bytes = payload {
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

    // MARK: - Chuyển đổi ảnh DIB ↔ BMP (mượn NSBitmapImageRep, chỉ phẫu thuật 14 byte header)

    /// NSPasteboard có ảnh → DIB (BMP bỏ 14 byte BITMAPFILEHEADER).
    private func dibFromPasteboardImage() -> Data? {
        let pb = NSPasteboard.general
        guard let raw = pb.data(forType: .tiff) ?? pb.data(forType: .png),
              let rep = NSBitmapImageRep(data: raw),
              let bmp = rep.representation(using: .bmp, properties: [:]),
              bmp.count > 14 else { return nil }
        return bmp.subdata(in: 14..<bmp.count)
    }

    /// DIB từ remote → BMP (thêm 14 byte BITMAPFILEHEADER) để NSImage đọc được.
    private func bmpFromDIB(_ dib: Data) -> Data? {
        guard dib.count >= 40 else { return nil }
        func u16(_ o: Int) -> Int { Int(dib[dib.startIndex+o]) | (Int(dib[dib.startIndex+o+1]) << 8) }
        func u32(_ o: Int) -> Int {
            Int(dib[dib.startIndex+o]) | (Int(dib[dib.startIndex+o+1]) << 8)
                | (Int(dib[dib.startIndex+o+2]) << 16) | (Int(dib[dib.startIndex+o+3]) << 24)
        }
        let biSize = u32(0), biBitCount = u16(14), biClrUsed = u32(32)
        var palette = biClrUsed
        if palette == 0 && biBitCount <= 8 { palette = 1 << biBitCount }
        let offBits = 14 + biSize + palette * 4
        let fileSize = 14 + dib.count
        var bmp = Data(capacity: fileSize)
        bmp.append(0x42); bmp.append(0x4D)                 // 'BM'
        appendLE32(&bmp, UInt32(fileSize))
        appendLE32(&bmp, 0)                                 // reserved
        appendLE32(&bmp, UInt32(offBits))
        bmp.append(dib)
        return bmp
    }

    private func appendLE32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF)); d.append(UInt8((v >> 24) & 0xFF))
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

    /// Quảng bá các format hiện có trên NSPasteboard (text và/hoặc ảnh).
    func advertiseLocalClipboard() {
        let pb = NSPasteboard.general
        var ids: [UInt32] = []
        if pb.string(forType: .string) != nil { ids.append(kCF_UNICODETEXT) }
        if pb.data(forType: .tiff) != nil || pb.data(forType: .png) != nil { ids.append(kCF_DIB) }

        var cFormats = ids.map { id -> CLIPRDR_FORMAT in
            var f = CLIPRDR_FORMAT(); f.formatId = id; f.formatName = nil; return f
        }
        cFormats.withUnsafeMutableBufferPointer { buf in
            var list = CLIPRDR_FORMAT_LIST()
            list.numFormats = UInt32(buf.count)
            list.formats = buf.baseAddress   // nil khi rỗng → numFormats=0
            _ = cliprdr.pointee.ClientFormatList?(cliprdr, &list)
        }
    }

    private func startPolling() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            // Chỉ đổi do bên ngoài (ghi của ta đã cập nhật lastChangeCount) → quảng bá.
            let cc = NSPasteboard.general.changeCount
            guard cc != self.lastChangeCount else { return }
            self.lastChangeCount = cc
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

/// Handler "channel connected": tra RDPClient qua registry rồi gắn cầu nối theo tên kênh —
/// cliprdr (clipboard) hoặc disp (dynamic resolution).
func rdpChannelConnected(_ context: UnsafeMutableRawPointer?,
                         _ e: UnsafePointer<ChannelConnectedEventArgs>?) {
    guard let context, let e, let namePtr = e.pointee.name, let iface = e.pointee.pInterface else { return }
    let name = String(cString: namePtr)
    guard let client = RDPClientRegistry.shared.get(context) else { return }
    if name == CLIPRDR_SVC_CHANNEL_NAME {
        client.attachClipboard(iface.assumingMemoryBound(to: CliprdrClientContext.self))
    } else if name == DISP_DVC_CHANNEL_NAME {
        client.attachDisp(iface.assumingMemoryBound(to: DispClientContext.self))
    }
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
