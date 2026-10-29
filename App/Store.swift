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
    @Published var pendingBackup: Backup?
    @Published private(set) var readingBackup = false
    let isDemonstration: Bool
    private let repository: SQLiteLedgerRepository
    private init(repository: SQLiteLedgerRepository, state: LedgerState, isDemonstration: Bool = false) {
        self.repository = repository; self.state = state; self.isDemonstration = isDemonstration
        let saved = UserDefaults.standard.string(forKey: "currentBookID")
        bookID = saved == "all" ? nil : saved.flatMap(UUID.init(uuidString:)) ?? state.defaultBookID
        if let bookID, !state.books.contains(where: { $0.id == bookID && !$0.archived }) { self.bookID = state.defaultBookID }
    }
    static var preview: Store { Store(repository: try! SQLiteLedgerRepository(path: ":memory:"), state: .demonstration, isDemonstration: true) }
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
    func stageBackup(_ url: URL) async {
        guard !saving && !readingBackup && pendingBackup == nil else { error = "请先完成或取消当前备份操作"; return }
        readingBackup = true; defer { readingBackup = false }
        do { pendingBackup = try await Task.detached(priority: .userInitiated) { try BackupService.readFile(url) }.value }
        catch { self.error = error.localizedDescription }
    }
    #if DEBUG
    // 模拟器自检只读取临时虚构文件，正式数据库及恢复点均不修改。
    func checkBackupFileFlow() async -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let before = state
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("fictional.pocketledger")
            try BackupService.export(.demonstration).write(to: file)
            await stageBackup(file)
            guard pendingBackup != nil, state == before else { throw LedgerError.invalid("备份读取改变了账本或没有生成预览") }
            pendingBackup = nil
            let broken = directory.appendingPathComponent("broken.json")
            try Data("invalid".utf8).write(to: broken)
            await stageBackup(broken)
            guard pendingBackup == nil, state == before, error != nil else { throw LedgerError.invalid("损坏文件没有被拒绝") }
            error = nil
            return "PASS：备份预览、取消、损坏文件拒绝和原数据保留"
        } catch { return "FAIL：" + error.localizedDescription }
    }
    #endif
    func previousBackup() throws -> Data {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try Data(contentsOf: dir.appendingPathComponent("before-restore.json"))
    }
}
