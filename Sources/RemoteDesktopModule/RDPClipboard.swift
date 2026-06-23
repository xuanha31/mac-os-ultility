#if HAS_FREERDP
import Foundation
import AppKit
import Core
import CFreeRDP

private let clipLog = Log.make("remote")

// Định danh clipboard chuẩn của Windows.
private let kCF_UNICODETEXT: UInt32 = 13   // text UTF-16LE (kết NUL)
private let kCF_DIB: UInt32 = 8            // ảnh DIB (BITMAPINFOHEADER + pixel, không file header)

// File clipboard (MS-RDPECLIP): format "FileGroupDescriptorW" (đặt tên dài) + PDU FileContents.
private let kFileGroupName = "FileGroupDescriptorW"
private let kFileGroupId: UInt32 = 49562   // id ta tự gán khi quảng bá (peer ánh xạ theo TÊN)
private let kFD_FILESIZE_ATTRIBUTES: UInt32 = 0x44   // FD_FILESIZE(0x40) | FD_ATTRIBUTES(0x04)
private let kFILE_ATTRIBUTE_ARCHIVE: UInt32 = 0x20
private let kFILE_ATTRIBUTE_DIRECTORY: UInt32 = 0x10

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
    private var providedFiles: [URL] = [] // snapshot file URL ta đang cấp cho remote (theo listIndex)

    // Nhận file (remote → Mac): id file group do server quảng bá + máy trạng thái kéo tuần tự.
    private var serverFileGroupId: UInt32 = 0
    private var inFiles: [(String, UInt64)] = []
    private var inDir: URL?
    private var inIndex = 0
    private var inOffset: UInt64 = 0
    private var inHandle: FileHandle?
    private var inURLs: [URL] = []
    private var streamCounter: UInt32 = 0

    init(_ ctx: UnsafeMutablePointer<CliprdrClientContext>) {
        self.cliprdr = ctx
        ctx.pointee.custom = Unmanaged.passUnretained(self).toOpaque()
        ctx.pointee.MonitorReady = rdpCliprdrMonitorReady
        ctx.pointee.ServerFormatList = rdpCliprdrServerFormatList
        ctx.pointee.ServerFormatDataRequest = rdpCliprdrServerFormatDataRequest
        ctx.pointee.ServerFormatDataResponse = rdpCliprdrServerFormatDataResponse
        ctx.pointee.ServerFileContentsRequest = rdpCliprdrServerFileContentsRequest
        ctx.pointee.ServerFileContentsResponse = rdpCliprdrServerFileContentsResponse
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

    /// Remote đổi clipboard → ưu tiên FILE > ẢNH > TEXT (đúng cái vừa copy), xin dữ liệu về.
    func onServerFormatList(_ list: UnsafePointer<CLIPRDR_FORMAT_LIST>) {
        let n = Int(list.pointee.numFormats)
        var hasText = false, hasImage = false, fileId: UInt32?
        if let formats = list.pointee.formats {
            for i in 0..<n {
                let id = formats[i].formatId
                if id == kCF_UNICODETEXT { hasText = true }
                if id == kCF_DIB { hasImage = true }
                if let np = formats[i].formatName, String(cString: np) == kFileGroupName { fileId = id }
            }
        }
        serverFileGroupId = fileId ?? 0
        let want: UInt32
        if let fid = fileId { want = fid } else if hasImage { want = kCF_DIB }
        else if hasText { want = kCF_UNICODETEXT } else { return }
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

        if serverFileGroupId != 0, pendingFormat == serverFileGroupId {
            startReceivingFiles(parseFileGroupDescriptor(Data(bytes: data, count: len)))
            return
        }

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

    /// Remote xin clipboard của ta để paste → trả text (UTF-16LE) hoặc ảnh (DIB) hoặc file.
    func onServerFormatDataRequest(_ req: UnsafePointer<CLIPRDR_FORMAT_DATA_REQUEST>) {
        let fmt = req.pointee.requestedFormatId
        // Đọc pasteboard PHẢI trên MAIN (không thread-safe) → lấy payload qua main.sync rồi gửi
        // response trên thread kênh. Callback này luôn chạy ở thread kênh nên sync an toàn.
        let payload: [UInt8]? = DispatchQueue.main.sync {
            if fmt == kCF_UNICODETEXT, let s = NSPasteboard.general.string(forType: .string) {
                var bytes = [UInt8](); bytes.reserveCapacity(s.utf16.count * 2 + 2)
                for u in s.utf16 { bytes.append(UInt8(u & 0xFF)); bytes.append(UInt8(u >> 8)) }
                bytes.append(0); bytes.append(0)   // NUL UTF-16
                return bytes
            } else if fmt == kCF_DIB, let dib = dibFromPasteboardImage() {
                return [UInt8](dib)
            } else if fmt == kFileGroupId {
                providedFiles = pasteboardFileURLs()   // snapshot để map listIndex cho FileContents
                if !providedFiles.isEmpty { return [UInt8](buildFileGroupDescriptor(providedFiles)) }
            }
            return nil
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

    // MARK: - File: Mac → remote

    private func fileSize(_ url: URL) -> UInt64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64($0) } ?? 0
    }

    /// Dựng FILEGROUPDESCRIPTORW: cItems(4) + N × FILEDESCRIPTORW(592 byte).
    private func buildFileGroupDescriptor(_ urls: [URL]) -> Data {
        var d = Data()
        appendLE32(&d, UInt32(urls.count))
        for url in urls {
            var fd = [UInt8](repeating: 0, count: 592)
            func put32(_ off: Int, _ v: UInt32) {
                fd[off] = UInt8(v & 0xFF); fd[off+1] = UInt8((v >> 8) & 0xFF)
                fd[off+2] = UInt8((v >> 16) & 0xFF); fd[off+3] = UInt8((v >> 24) & 0xFF)
            }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let size = fileSize(url)
            put32(0, kFD_FILESIZE_ATTRIBUTES)                                   // dwFlags
            put32(36, isDir == true ? kFILE_ATTRIBUTE_DIRECTORY : kFILE_ATTRIBUTE_ARCHIVE) // dwFileAttributes
            put32(64, UInt32(size >> 32))                                       // nFileSizeHigh
            put32(68, UInt32(size & 0xFFFF_FFFF))                               // nFileSizeLow
            var off = 72                                                        // cFileName[260] UTF-16
            for u in url.lastPathComponent.utf16.prefix(259) {
                fd[off] = UInt8(u & 0xFF); fd[off+1] = UInt8(u >> 8); off += 2
            }
            d.append(contentsOf: fd)
        }
        return d
    }

    /// Remote xin nội dung file (SIZE hoặc RANGE) → đọc từ file Mac và trả về.
    func onServerFileContentsRequest(_ req: UnsafePointer<CLIPRDR_FILE_CONTENTS_REQUEST>) {
        let r = req.pointee
        let idx = Int(r.listIndex)
        guard idx >= 0, idx < providedFiles.count else { sendFileContents(r.streamId, nil); return }
        let url = providedFiles[idx]

        if (r.dwFlags & UInt32(FILECONTENTS_SIZE)) != 0 {
            let size = fileSize(url)
            var bytes = [UInt8]()
            for i in 0..<8 { bytes.append(UInt8((size >> (8 * i)) & 0xFF)) }   // UInt64 LE
            sendFileContents(r.streamId, bytes)
        } else if (r.dwFlags & UInt32(FILECONTENTS_RANGE)) != 0 {
            let pos = UInt64(r.nPositionLow) | (UInt64(r.nPositionHigh) << 32)
            sendFileContents(r.streamId, readFileRange(url, pos, Int(r.cbRequested)))
        } else {
            sendFileContents(r.streamId, nil)
        }
    }

    private func readFileRange(_ url: URL, _ pos: UInt64, _ count: Int) -> [UInt8] {
        guard count > 0, let fh = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }
        try? fh.seek(toOffset: pos)
        let data = (try? fh.read(upToCount: count)) ?? Data()
        return [UInt8](data)
    }

    /// Gửi FileContentsResponse. bytes == nil → báo lỗi (CB_RESPONSE_FAIL).
    private func sendFileContents(_ streamId: UInt32, _ bytes: [UInt8]?) {
        var resp = CLIPRDR_FILE_CONTENTS_RESPONSE()
        resp.streamId = streamId
        guard let bytes else {
            resp.common.msgFlags = UInt16(CB_RESPONSE_FAIL)
            _ = cliprdr.pointee.ClientFileContentsResponse?(cliprdr, &resp)
            return
        }
        resp.common.msgFlags = UInt16(CB_RESPONSE_OK)
        resp.common.dataLen = UInt32(4 + bytes.count)   // streamId(4) + data
        resp.cbRequested = UInt32(bytes.count)
        bytes.withUnsafeBufferPointer { p in
            resp.requestedData = p.baseAddress
            _ = cliprdr.pointee.ClientFileContentsResponse?(cliprdr, &resp)
        }
    }

    // MARK: - File: remote → Mac (kéo tuần tự, 1 yêu cầu/lúc)

    /// Đọc FILEGROUPDESCRIPTORW → [(tên, kích thước)].
    private func parseFileGroupDescriptor(_ d: Data) -> [(String, UInt64)] {
        guard d.count >= 4 else { return [] }
        func u32(_ o: Int) -> UInt64 {
            UInt64(d[d.startIndex+o]) | (UInt64(d[d.startIndex+o+1]) << 8)
                | (UInt64(d[d.startIndex+o+2]) << 16) | (UInt64(d[d.startIndex+o+3]) << 24)
        }
        let count = Int(u32(0))
        var out: [(String, UInt64)] = []
        var base = 4
        for _ in 0..<count {
            guard base + 592 <= d.count else { break }
            let size = (u32(base + 64) << 32) | u32(base + 68)            // high<<32 | low
            var units: [UInt16] = []
            var o = base + 72
            for _ in 0..<260 {
                let u = UInt16(d[d.startIndex+o]) | (UInt16(d[d.startIndex+o+1]) << 8)
                if u == 0 { break }
                units.append(u); o += 2
            }
            out.append((String(decoding: units, as: UTF16.self), size))
            base += 592
        }
        return out
    }

    private func startReceivingFiles(_ files: [(String, UInt64)]) {
        guard !files.isEmpty, inHandle == nil else { return }   // bỏ qua nếu đang nhận dở
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macutil-rdp-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        inDir = dir; inFiles = files; inURLs = []; inIndex = 0; inOffset = 0
        openCurrentIncomingFile()
        requestNextChunk()
    }

    private func openCurrentIncomingFile() {
        guard let dir = inDir, inIndex < inFiles.count else { return }
        // Chỉ lấy tên file (chống path traversal từ remote).
        let raw = (inFiles[inIndex].0 as NSString).lastPathComponent
        let name = raw.isEmpty ? "file-\(inIndex)" : raw
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        inHandle = try? FileHandle(forWritingTo: url)
        inURLs.append(url)
        inOffset = 0
    }

    private func requestNextChunk() {
        while inIndex < inFiles.count, inOffset >= inFiles[inIndex].1 {
            try? inHandle?.close(); inHandle = nil       // file hiện tại xong
            inIndex += 1
            if inIndex < inFiles.count { openCurrentIncomingFile() }
        }
        guard inIndex < inFiles.count else { finishReceiving(); return }
        let chunk = UInt32(min(inFiles[inIndex].1 - inOffset, 1 << 20))   // ≤1MB/lần
        streamCounter += 1
        var req = CLIPRDR_FILE_CONTENTS_REQUEST()
        req.streamId = streamCounter
        req.listIndex = UInt32(inIndex)
        req.dwFlags = UInt32(FILECONTENTS_RANGE)
        req.nPositionLow = UInt32(inOffset & 0xFFFF_FFFF)
        req.nPositionHigh = UInt32(inOffset >> 32)
        req.cbRequested = chunk
        _ = cliprdr.pointee.ClientFileContentsRequest?(cliprdr, &req)
    }

    /// Server trả 1 chunk nội dung file → ghi vào file tạm rồi xin chunk tiếp.
    func onServerFileContentsResponse(_ resp: UnsafePointer<CLIPRDR_FILE_CONTENTS_RESPONSE>) {
        guard inHandle != nil else { return }
        let r = resp.pointee
        guard (r.common.msgFlags & UInt16(CB_RESPONSE_OK)) != 0, let data = r.requestedData else {
            abortReceiving(); return
        }
        let len = Int(r.cbRequested)
        if len > 0 {
            try? inHandle?.write(contentsOf: Data(bytes: data, count: len))
            inOffset += UInt64(len)
        } else {
            inOffset = inFiles[inIndex].1   // không còn dữ liệu → coi file xong
        }
        requestNextChunk()
    }

    private func finishReceiving() {
        try? inHandle?.close(); inHandle = nil
        let urls = inURLs
        inFiles = []; inURLs = []
        guard !urls.isEmpty else { return }
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(urls.map { $0 as NSURL })
            self.lastChangeCount = pb.changeCount
        }
    }

    private func abortReceiving() {
        try? inHandle?.close(); inHandle = nil
        inFiles = []; inURLs = []
    }

    // MARK: - Helpers

    private func sendCapabilities() {
        var general = CLIPRDR_GENERAL_CAPABILITY_SET()
        general.capabilitySetType = UInt16(CB_CAPSTYPE_GENERAL)
        general.capabilitySetLength = UInt16(CB_CAPSTYPE_GENERAL_LEN)
        general.version = UInt32(CB_CAPS_VERSION_2)
        // Long format names (cho "FileGroupDescriptorW") + bật luồng file clipboard.
        general.generalFlags = UInt32(CB_USE_LONG_FORMAT_NAMES)
            | UInt32(CB_STREAM_FILECLIP_ENABLED) | UInt32(CB_FILECLIP_NO_FILE_PATHS)
        withUnsafeMutablePointer(to: &general) { gp in
            var caps = CLIPRDR_CAPABILITIES()
            caps.cCapabilitiesSets = 1
            caps.capabilitySets = UnsafeMutableRawPointer(gp).assumingMemoryBound(to: CLIPRDR_CAPABILITY_SET.self)
            _ = cliprdr.pointee.ClientCapabilities?(cliprdr, &caps)
        }
    }

    /// Quảng bá các format hiện có trên NSPasteboard (text, ảnh, file).
    /// NSPasteboard chỉ được chạm trên MAIN (không thread-safe) → tránh đua với ClipboardMonitor.
    func advertiseLocalClipboard() {
        let build = { [self] in
            let pb = NSPasteboard.general
            var items: [(UInt32, String?)] = []
            if pb.string(forType: .string) != nil { items.append((kCF_UNICODETEXT, nil)) }
            if pb.data(forType: .tiff) != nil || pb.data(forType: .png) != nil { items.append((kCF_DIB, nil)) }
            if !pasteboardFileURLs().isEmpty { items.append((kFileGroupId, kFileGroupName)) }
            sendFormatList(items)
        }
        if Thread.isMainThread { build() } else { DispatchQueue.main.async(execute: build) }
    }

    /// Gửi format list. Mỗi item có id + tên tuỳ chọn (tên cần cho format dài như file group).
    private func sendFormatList(_ items: [(UInt32, String?)]) {
        var names: [UnsafeMutablePointer<CChar>?] = []
        defer { for p in names { free(p) } }
        var cFormats = items.map { item -> CLIPRDR_FORMAT in
            var f = CLIPRDR_FORMAT()
            f.formatId = item.0
            if let n = item.1 { let p = strdup(n); names.append(p); f.formatName = p } else { f.formatName = nil }
            return f
        }
        cFormats.withUnsafeMutableBufferPointer { buf in
            var list = CLIPRDR_FORMAT_LIST()
            list.numFormats = UInt32(buf.count)
            list.formats = buf.baseAddress   // nil khi rỗng → numFormats=0
            _ = cliprdr.pointee.ClientFormatList?(cliprdr, &list)
        }
    }

    private func pasteboardFileURLs() -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] ?? []
        return urls.filter { $0.isFileURL }
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
private func rdpCliprdrServerFileContentsRequest(_ ctx: UnsafeMutablePointer<CliprdrClientContext>?,
                                                 _ req: UnsafePointer<CLIPRDR_FILE_CONTENTS_REQUEST>?) -> UInt32 {
    if let req { clip(ctx)?.onServerFileContentsRequest(req) }
    return 0
}
private func rdpCliprdrServerFileContentsResponse(_ ctx: UnsafeMutablePointer<CliprdrClientContext>?,
                                                  _ resp: UnsafePointer<CLIPRDR_FILE_CONTENTS_RESPONSE>?) -> UInt32 {
    if let resp { clip(ctx)?.onServerFileContentsResponse(resp) }
    return 0
}
#endif
