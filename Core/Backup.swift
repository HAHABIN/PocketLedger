import Foundation

public struct Backup: Codable {
    public var format = "com.localbookkeeping.full-backup"
    public var schemaVersion = 1
    public var exportedAt = Date()
    public var currency = "CNY"
    public var appVersion = "1.0.0"
    public var data: LedgerState
    public init(data: LedgerState) { self.data = data }
}
public enum ImportMode { case replace }
public enum BackupService {
    // 备份保留秒的小数部分，避免恢复时丢失交易时间精度。
    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            let raw = date.timeIntervalSince1970
            var seconds = floor(raw)
            var units = Int64(((raw - seconds) * 10_000_000).rounded())
            if units == 10_000_000 { seconds += 1; units = 0 }
            let base = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
            let fraction = String(format: ".%07lld", units)
            var c = encoder.singleValueContainer(); try c.encode(String(base.dropLast()) + fraction + "Z")
        }; return e
    }
    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer(); let value = try c.decode(String.self)
            let f = ISO8601DateFormatter()
            if let dot = value.firstIndex(of: "."), value.hasSuffix("Z") {
                let whole = String(value[..<dot]) + "Z"
                let fraction = String(value[dot..<value.index(before: value.endIndex)])
                if let date = f.date(from: whole), let part = Double("0" + fraction) { return date.addingTimeInterval(part) }
            }
            if let date = f.date(from: value) { return date }
            throw LedgerError.invalid("备份日期格式无效")
        }; return d
    }
    public static func export(_ state: LedgerState) throws -> Data {
        try state.validate(); let data = try encoder().encode(Backup(data: state))
        guard data.count <= 50 * 1024 * 1024 else { throw LedgerError.invalid("完整备份超过50MB，请减少过长备注后重试") }; return data
    }
    public static func preview(_ data: Data) throws -> Backup {
        guard !data.isEmpty, data.count <= 50 * 1024 * 1024 else { throw LedgerError.invalid("备份为空或超过50MB") }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let payload = object?["data"] as? [String: Any], payload["accountPostings"] != nil, payload["transactions"] != nil else { throw LedgerError.invalid("备份缺少交易或资金过账") }
        let backup = try decoder().decode(Backup.self, from: data)
        guard backup.format == "com.localbookkeeping.full-backup", backup.schemaVersion == 1, backup.currency == "CNY" else { throw LedgerError.invalid("备份格式、版本或币种不受支持") }
        try backup.data.validate()
        return backup
    }
    public static let maximumFileSize = 50 * 1024 * 1024
    // 文件选择器、文件 App 和 AirDrop 均走相同的限量读取与校验。
    public static func readFile(_ url: URL) throws -> Backup {
        guard url.isFileURL else { throw LedgerError.invalid("只支持从本地文件或系统文件提供器打开备份") }
        guard ["json", "pocketledger"].contains(url.pathExtension.lowercased()) else { throw LedgerError.invalid("请选择 JSON 或 pocketledger 完整备份；CSV 不能用于恢复") }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Backup, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
            result = Result { try readCoordinatedFile(coordinatedURL) }
        }
        if let result { return try result.get() }
        throw coordinationError ?? NSError(domain: "PocketLedger.Backup", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件尚未准备好，请在「文件」中下载后重试"])
    }
    private static func readCoordinatedFile(_ url: URL) throws -> Backup {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= maximumFileSize else { throw LedgerError.invalid("备份不是普通文件或超过50MB") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(1024 * 1024, maximumFileSize + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumFileSize else { throw LedgerError.invalid("备份超过50MB") }
        }
        return try preview(data)
    }
    public static func decode(_ data: Data) throws -> LedgerState { try preview(data).data }
    public static func restore(_ incoming: LedgerState, into current: LedgerState, mode: ImportMode) throws -> LedgerState {
        try incoming.validate(); return incoming
    }
    public static func csv(_ state: LedgerState, entries: [Entry]? = nil) -> Data {
        func quote(_ value: String) -> String {
            let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first
            let safe = first.map { "=+-@".contains($0) } == true || value.hasPrefix("\t") || value.hasPrefix("\r") ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let f = ISO8601DateFormatter()
        let books = Dictionary(uniqueKeysWithValues: state.books.map { ($0.id, $0.name) })
        let accounts = Dictionary(uniqueKeysWithValues: state.accounts.map { ($0.id, $0.name) })
        let rows = (entries ?? state.entries).sorted { $0.date > $1.date }.map { e in
            let absolute = abs(e.amount)
            let amount = (e.amount < 0 ? "-" : "") + "\(absolute / 100)." + String(format: "%02lld", absolute % 100)
            return [f.string(from: e.date), e.kind.rawValue, books[e.bookID] ?? "", e.category, accounts[e.accountID] ?? "", e.targetID.flatMap { accounts[$0] } ?? "", amount, e.note, e.id.uuidString].map(quote).joined(separator: ",")
        }
        return Data(("\u{FEFF}日期,类型,账本,分类,转出账户,转入账户,金额(元),备注,交易ID\r\n" + rows.joined(separator: "\r\n")).utf8)
    }
}
