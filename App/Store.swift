import SwiftUI
import LedgerCore

@MainActor final class Store: ObservableObject {
    @Published private(set) var state: LedgerState
    @Published var bookID: UUID?
    @Published var error: String?
    private let repository: SQLiteLedgerRepository
    init() throws {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("PocketLedger", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        repository = try SQLiteLedgerRepository(path: directory.appendingPathComponent("ledger.sqlite").path)
        state = try repository.load() ?? .initial
        bookID = state.defaultBookID
        try repository.save(state)
    }
    @discardableResult func perform(_ mutation: (inout LedgerState) throws -> Void) -> Bool {
        do {
            var next = state; try mutation(&next); try repository.save(next); state = next
            if !next.books.contains(where: { $0.id == bookID && !$0.archived }) { bookID = next.defaultBookID }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func attempt(_ work: () throws -> Void) { do { try work() } catch { self.error = error.localizedDescription } }
    var activeBooks: [Book] { state.books.filter { !$0.archived } }
    var activeAccounts: [Account] { state.accounts.filter { !$0.archived } }
    func entries(book: UUID?, interval: DateInterval? = nil, account: UUID? = nil) -> [Entry] {
        state.entries.filter { e in
            (book == nil || e.bookID == book) && (interval == nil || (e.date >= interval!.start && e.date < interval!.end)) &&
            (account == nil || e.accountID == account || e.targetID == account)
        }.sorted { $0.date > $1.date }
    }
    func remove(_ entry: Entry) {
        perform { s in
            if entry.kind == .lend || entry.kind == .borrow {
                guard !s.entries.contains(where: { $0.loanID == entry.loanID && $0.id != entry.id }) else { throw LedgerError.invalid("请先删除关联还款记录") }
                s.loans.removeAll { $0.id == entry.loanID }
            }
            s.entries.removeAll { $0.id == entry.id }
        }
    }
    func restore(_ incoming: LedgerState, mode: ImportMode) throws {
        // Keep a recoverable pre-import snapshot outside the live database.
        let backup = try BackupService.export(state)
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try backup.write(to: dir.appendingPathComponent("before-restore.json"), options: [.atomic, .completeFileProtection])
        let next = try BackupService.restore(incoming, into: state, mode: mode)
        try repository.save(next); state = next; bookID = next.defaultBookID
    }
    func previousBackup() throws -> Data {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try Data(contentsOf: dir.appendingPathComponent("before-restore.json"))
    }
}
