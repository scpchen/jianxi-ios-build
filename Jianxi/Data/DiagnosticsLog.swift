import Foundation

struct DiagnosticEntry: Identifiable {
    let id = UUID()
    let time: Date
    let operation: String
    let status: String
    let durationMs: Int
    let errorCode: Int?
}

final class DiagnosticsLog {
    static let shared = DiagnosticsLog()
    private let lock = NSLock()
    private var entries: [DiagnosticEntry] = []
    private let limit = 200

    func record(_ operation: String, _ status: String, _ durationMs: Int = 0, _ errorCode: Int? = nil) {
        lock.lock()
        entries.append(DiagnosticEntry(time: Date(), operation: operation, status: status, durationMs: durationMs, errorCode: errorCode))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        lock.unlock()
    }

    func snapshot() -> [DiagnosticEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries.reversed()
    }

    func exportText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let lines = snapshot().reversed().map { entry in
            let code = entry.errorCode.map { " 错误码=\($0)" } ?? ""
            return "\(formatter.string(from: entry.time)) \(entry.operation) \(entry.status) \(entry.durationMs)ms\(code)"
        }
        return "简洗 iOS 排错日志\n" + lines.joined(separator: "\n")
    }
}