import SwiftUI
import LedgerCore

@MainActor final class Store: ObservableObject {
    @Published private(set) var state: LedgerState
    @Published private(set) var saving = false
    @Published var bookID: UUID? {
        didSet {
            // 界面选择单独保存，避免切换账本时重写财务记录。
            UserDefaults.standard.set(bookID?.uuidString ?? "all", forKey: "currentBookID")
        }
    }
    @Published var error: String?
    private let repository: SQLiteLedgerRepository
    private init(repository: SQLiteLedgerRepository, state: LedgerState) {
        self.repository = repository; self.state = state
        let saved = UserDefaults.standard.string(forKey: "currentBookID")
        bookID = saved == "all" ? nil : saved.flatMap(UUID.init(uuidString:)) ?? state.defaultBookID
        if let bookID, !state.books.contains(where: { $0.id == bookID && !$0.archived }) { self.bookID = state.defaultBookID }
    }
    static var preview: Store {
        var state = LedgerState.initial; state.accounts[0].opening = 200_000
        state.entries = [Entry(bookID: state.books[0].id, accountID: state.accounts[0].id, kind: .expense, amount: 2500, category: "餐饮", note: "午餐"), Entry(bookID: state.books[0].id, accountID: state.accounts[0].id, kind: .income, amount: 800_000, category: "工资")]
        return Store(repository: try! SQLiteLedgerRepository(path: ":memory:"), state: state)
    }
    static func open() async throws -> Store {
        let (repository, state) = try await Task.detached(priority: .userInitiated) {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("PocketLedger", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            let repository = try SQLiteLedgerRepository(path: directory.appendingPathComponent("ledger.sqlite").path)
            let state = try repository.load() ?? .initial
            try repository.save(state)
            return (repository, state)
        }.value
        return Store(repository: repository, state: state)
    }
    @discardableResult func perform(_ mutation: (inout LedgerState) throws -> Void) async -> Bool {
        guard !saving else { return false }
        saving = true; defer { saving = false }
        do {
            var next = state; try mutation(&next)
            let repository = repository, snapshot = next
            try await Task.detached(priority: .userInitiated) { try repository.save(snapshot) }.value
            state = next
            if let bookID, !next.books.contains(where: { $0.id == bookID && !$0.archived }) { self.bookID = next.defaultBookID }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func attempt(_ work: () throws -> Void) { do { try work() } catch { self.error = error.localizedDescription } }
    func attemptAsync(_ work: () async throws -> Void) async { do { try await work() } catch { self.error = error.localizedDescription } }
    var activeBooks: [Book] { state.books.filter { !$0.archived } }
    var activeAccounts: [Account] { state.accounts.filter { !$0.archived } }
    func entries(book: UUID?, interval: DateInterval? = nil, account: UUID? = nil) -> [Entry] {
        state.entries.filter { e in
            (book == nil || e.bookID == book) && (interval == nil || (e.date >= interval!.start && e.date < interval!.end)) && (account == nil || e.accountID == account || e.targetID == account)
        }.sorted { $0.date > $1.date }
    }
    func clearAll() async throws {
        guard !saving else { throw LedgerError.invalid("正在保存，请稍后再试") }
        saving = true; defer { saving = false }
        let repository = repository, initial = LedgerState.initial
        try await Task.detached(priority: .userInitiated) {
            let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let previous = dir.appendingPathComponent("before-restore.json")
            if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
            try repository.save(initial)
        }.value
        state = initial; bookID = initial.defaultBookID
    }
    func restore(_ incoming: LedgerState, mode: ImportMode) async throws {
        guard !saving else { throw LedgerError.invalid("正在保存，请稍后再试") }
        saving = true; defer { saving = false }
        let repository = repository, current = state
        let next = try await Task.detached(priority: .userInitiated) {
            let next = try BackupService.restore(incoming, into: current, mode: mode)
            let backup = try BackupService.export(current)
            let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            try backup.write(to: dir.appendingPathComponent("before-restore.json"), options: [.atomic, .completeFileProtection])
            try repository.save(next); return next
        }.value
        state = next; bookID = next.settings?["currentBookID"].flatMap(UUID.init(uuidString:)) ?? next.defaultBookID
    }
    func previousBackup() throws -> Data {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try Data(contentsOf: dir.appendingPathComponent("before-restore.json"))
    }
}
