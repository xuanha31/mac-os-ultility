import Foundation

public enum GitError: Error, CustomStringConvertible {
    case commandFailed(args: [String], status: Int32, message: String)

    public var description: String {
        switch self {
        case .commandFailed(let args, let status, let message):
            return "git \(args.joined(separator: " ")) → status \(status): \(message)"
        }
    }
}

/// Bọc lệnh `git` qua Process. (xem docs/features/07-git-manager.md)
///
/// Lưu ý: đọc cả stdout/stderr sau `waitUntilExit` chỉ an toàn với output nhỏ
/// (status/branch). Đủ cho mục đích quét repo.
public struct GitCLI: Sendable {
    public let gitPath: String

    public init(gitPath: String = "/usr/bin/git") {
        self.gitPath = gitPath
    }

    @discardableResult
    public func run(_ args: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = args
        process.currentDirectoryURL = directory

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let outString = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errString = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        guard process.terminationStatus == 0 else {
            let message = errString.isEmpty ? outString : errString
            throw GitError.commandFailed(args: args, status: process.terminationStatus, message: message)
        }
        return outString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Chạy lệnh, trả nil nếu lỗi (cho các lệnh có thể fail "bình thường", vd không có upstream).
    public func tryRun(_ args: [String], in directory: URL) -> String? {
        try? run(args, in: directory)
    }
}
