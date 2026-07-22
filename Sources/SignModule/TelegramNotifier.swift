import Foundation

/// Gửi thông báo qua Telegram Bot API.
///
/// Token + chat_id KHÔNG nhét trong source — đọc từ file config cục bộ:
///   ~/Library/Application Support/MacUtil/telegram.json
///   { "bot_token": "...", "chat_id": "..." }   (chat_id có thể là số hoặc chuỗi)
/// Fallback biến môi trường TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID.
/// Thiếu/rỗng config → bỏ qua (không crash), ghi cảnh báo qua log callback.
public enum TelegramNotifier {

    public struct Config {
        public let botToken: String
        public let chatID: String
    }

    /// ~/Library/Application Support/MacUtil/telegram.json
    public static var configURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacUtil/telegram.json")
    }

    /// Đọc config: ưu tiên file JSON, fallback biến môi trường. Trả nil nếu không đủ.
    public static func loadConfig() -> Config? {
        if let data = try? Data(contentsOf: configURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let token = (obj["bot_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let chat = chatIDString(obj["chat_id"])
            if !token.isEmpty, !chat.isEmpty { return Config(botToken: token, chatID: chat) }
        }
        let env = ProcessInfo.processInfo.environment
        let token = env["TELEGRAM_BOT_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let chat = env["TELEGRAM_CHAT_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !token.isEmpty, !chat.isEmpty { return Config(botToken: token, chatID: chat) }
        return nil
    }

    public static var isConfigured: Bool { loadConfig() != nil }

    /// chat_id trong JSON có thể là chuỗi ("-100...") hoặc số nguyên → chuẩn hoá về chuỗi.
    private static func chatIDString(_ value: Any?) -> String {
        if let s = value as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }

    /// Gửi 1 tin nhắn HTML. Trả true nếu Telegram trả 2xx.
    @discardableResult
    public static func send(_ html: String, log: ((String) -> Void)? = nil) async -> Bool {
        guard let cfg = loadConfig() else {
            log?("⚠️ Telegram chưa cấu hình (thiếu telegram.json / env) — bỏ qua thông báo.\n")
            return false
        }
        guard let url = URL(string: "https://api.telegram.org/bot\(cfg.botToken)/sendMessage") else {
            log?("⚠️ Telegram: bot_token không hợp lệ.\n")
            return false
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "chat_id": cfg.chatID,
            "text": html,
            "parse_mode": "HTML",
            "disable_web_page_preview": true,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(code) {
                log?("⚠️ Telegram HTTP \(code): \(String(decoding: data, as: UTF8.self))\n")
                return false
            }
            return true
        } catch {
            log?("⚠️ Gửi Telegram lỗi: \(error)\n")
            return false
        }
    }

    /// Escape các ký tự đặc biệt của HTML (parse_mode=HTML của Telegram chỉ cần & < >).
    public static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
