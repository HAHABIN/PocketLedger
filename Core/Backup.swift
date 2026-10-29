import Foundation

public struct Backup: Codable {
    public var app = "PocketLedger"
    public var version = 1
    public var exportedAt = Date()
    public var data: LedgerState
    public init(data: LedgerState) { self.data = data }
}
public enum ImportMode { case replace, merge }
public enum BackupService {
    public static func export(_ state: LedgerState) throws -> Data {
        try state.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Backup(data: state))
    }
    public static func decode(_ data: Data) throws -> LedgerState {
        guard data.count <= 50 * 1024 * 1024 else { throw LedgerError.invalid("备份不能超过50MB") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(Backup.self, from: data)
        guard backup.app == "PocketLedger", backup.version == 1 else { throw LedgerError.invalid("备份来源或版本不受支持") }
        try backup.data.validate(); return backup.data
    }
    // Same ID + different content is a conflict, never silently overwrite balances.
    public static func restore(_ incoming: LedgerState, into current: LedgerState, mode: ImportMode) throws -> LedgerState {
        try incoming.validate()
        if mode == .replace { return incoming }
        func merge<T: Identifiable & Equatable>(_ a: [T], _ b: [T]) throws -> [T] where T.ID: Hashable {
            var result = a
            for item in b {
                if let existing = a.first(where: { $0.id == item.id }) {
                    guard existing == item else { throw LedgerError.invalid("相同ID的数据发生冲突，请选择覆盖恢复或其他备份") }
                } else { result.append(item) }
            }
            return result
        }
        var result = current
        result.books = try merge(current.books, incoming.books)
        result.accounts = try merge(current.accounts, incoming.accounts)
        result.entries = try merge(current.entries, incoming.entries)
        result.loans = try merge(current.loans, incoming.loans)
        result.budgets = try merge(current.budgets, incoming.budgets)
        result.categories = Array(Set(current.categories + incoming.categories)).sorted()
        try result.validate(); return result
    }
    public static func csv(_ state: LedgerState, entries: [Entry]? = nil) -> Data {
        func quote(_ value: String) -> String {
            // Prevent spreadsheet formula execution on user-supplied text.
            let dangerous = ["=", "+", "-", "@", "\t", "\r"].contains { value.trimmingCharacters(in: .whitespaces).hasPrefix($0) }
            let safe = dangerous ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let f = ISO8601DateFormatter()
        let rows = (entries ?? state.entries).sorted { $0.date > $1.date }.map { e in
            [f.string(from: e.date), state.books.first { $0.id == e.bookID }?.name ?? "", e.kind.rawValue, e.category,
             state.accounts.first { $0.id == e.accountID }?.name ?? "", state.accounts.first { $0.id == e.targetID }?.name ?? "",
             NSDecimalNumber(decimal: Decimal(e.amount) / 100).stringValue, e.note].map(quote).joined(separator: ",")
        }
        return Data(("\u{FEFF}日期,账本,类型,分类,账户,转入账户,金额,备注\r\n" + rows.joined(separator: "\r\n")).utf8)
    }
}
