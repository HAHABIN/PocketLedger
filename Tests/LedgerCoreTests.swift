import XCTest
import GRDB
@testable import LedgerCore
final class LedgerCoreTests: XCTestCase {
    func testMoney() throws {
        XCTAssertEqual(try Money.parse("0.29"), 29)
        XCTAssertThrowsError(try Money.parse("1.234"))
        XCTAssertThrowsError(try Money.parse("1e6"))
        XCTAssertThrowsError(try Money.parse("-1"))
        XCTAssertThrowsError(try Money.parse("0"))
    }
    func testTransferAndCreditRepayment() throws {
        var s = LedgerState.initial
        let a = s.accounts[0].id; s.accounts[0].opening = 10000
        let credit = Account(name: "信用卡", kind: .credit, opening: -5000); s.accounts.append(credit)
        let before = s.netWorth
        s.entries.append(Entry(bookID: s.books[0].id, accountID: a, kind: .creditRepayment, amount: 3000, targetID: credit.id))
        try s.validate(); XCTAssertEqual(s.netWorth, before); XCTAssertEqual(s.balance(credit.id), -2000)
    }
    func testLoanAndPartialRepayment() throws {
        var s = LedgerState.initial; s.accounts[0].opening = 10000
        let loan = Loan(person: "朋友", isLent: true); s.loans.append(loan)
        let date = Date()
        s.entries.append(Entry(bookID: s.books[0].id, accountID: s.accounts[0].id, kind: .lend, amount: 5000, date: date, loanID: loan.id))
        s.entries.append(Entry(bookID: s.books[0].id, accountID: s.accounts[0].id, kind: .collect, amount: 2000, date: date, loanID: loan.id))
        try s.validate(); XCTAssertEqual(s.outstanding(loan.id), 3000); XCTAssertEqual(s.netWorth, 10000)
        s.entries.append(Entry(bookID: s.books[0].id, accountID: s.accounts[0].id, kind: .collect, amount: 4000, date: date, loanID: loan.id))
        XCTAssertThrowsError(try s.validate())
    }
    func testBackupRoundtripAndConflicts() throws {
        let s = LedgerState.initial
        let restored = try BackupService.decode(BackupService.export(s))
        XCTAssertEqual(s, restored)
        XCTAssertEqual(try BackupService.restore(s, into: s, mode: .replace), s)
    }
    func testDatabaseReopenAndFailedWrite() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let repo = try SQLiteLedgerRepository(path: path); let s = LedgerState.initial
        try repo.save(s); var invalid = s; invalid.books = []
        XCTAssertThrowsError(try repo.save(invalid))
        XCTAssertEqual(try SQLiteLedgerRepository(path: path).load(), s)
    }
    func testDanglingReferenceAndSameAccount() throws {
        var s = LedgerState.initial
        s.entries.append(Entry(bookID: s.books[0].id, accountID: s.accounts[0].id, kind: .transfer, amount: 100, targetID: s.accounts[0].id))
        XCTAssertThrowsError(try s.validate())
        s.entries[0].accountID = UUID(); XCTAssertThrowsError(try s.validate())
    }
}

final class AcceptanceTests: XCTestCase {
    func testFinancialScenarioAndCrossBook() throws {
        var s = LedgerState.initial
        s.accounts[0].opening = 100_000
        let cash = s.accounts[0].id, book = s.books[0].id
        let bank = Account(name: "银行", kind: .bank, opening: 200_000)
        let card = Account(name: "信用卡", kind: .credit, opening: -30_000)
        s.accounts += [bank, card]
        XCTAssertEqual(s.assets, 300_000); XCTAssertEqual(s.liabilities, 30_000); XCTAssertEqual(s.netWorth, 270_000)
        func add(_ kind: EntryKind, _ amount: Int64, _ account: UUID, target: UUID? = nil, loan: UUID? = nil) {
            s.entries.append(Entry(bookID: book, accountID: account, kind: kind, amount: amount, targetID: target, loanID: loan))
        }
        add(.expense, 2_000, cash); XCTAssertEqual(s.netWorth, 268_000)
        add(.transfer, 20_000, bank.id, target: cash); XCTAssertEqual(s.netWorth, 268_000)
        add(.expense, 10_000, card.id); XCTAssertEqual(s.netWorth, 258_000)
        add(.creditRepayment, 15_000, bank.id, target: card.id); XCTAssertEqual(s.netWorth, 258_000)
        let lent = Loan(person: "朋友甲", isLent: true); s.loans.append(lent)
        add(.lend, 30_000, cash, loan: lent.id)
        add(.collect, 12_000, bank.id, loan: lent.id)
        let borrowed = Loan(person: "朋友乙", isLent: false); s.loans.append(borrowed)
        add(.borrow, 50_000, bank.id, loan: borrowed.id)
        add(.repay, 20_000, bank.id, loan: borrowed.id)
        try s.validate()
        XCTAssertEqual(s.balance(cash), 88_000); XCTAssertEqual(s.balance(bank.id), 207_000)
        XCTAssertEqual(s.balance(card.id), -25_000); XCTAssertEqual(s.receivable, 18_000); XCTAssertEqual(s.payable, 30_000)
        XCTAssertEqual(s.netWorth, 258_000)
        let family = Book(name: "家庭账本"); s.books.append(family)
        let before = s.netWorth; s.entries[0].bookID = family.id
        XCTAssertEqual(s.netWorth, before)
        XCTAssertEqual(s.entries.filter { $0.bookID == family.id && $0.kind == .expense }.reduce(0) { $0 + $1.amount }, 2_000)
        let data = try BackupService.export(s), restored = try BackupService.decode(data)
        XCTAssertEqual(restored.netWorth, s.netWorth); XCTAssertEqual(restored.entries.count, 8)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let repo = try SQLiteLedgerRepository(path: path); try repo.save(s)
        XCTAssertEqual(try repo.load(), s)
        var revised = s; revised.entries[0].amount = 3_000; try repo.save(revised)
        XCTAssertEqual(try repo.load()?.netWorth, before - 1_000)
        try BookkeepingService.remove(revised.entries[0], from: &revised); try repo.save(revised)
        XCTAssertEqual(try repo.load()?.netWorth, before + 2_000)
    }
    func testTamperedPostingUnsupportedVersionAndCorruptFile() throws {
        let data = try BackupService.export(.initial)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 99
        XCTAssertThrowsError(try BackupService.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try BackupService.decode(Data("broken".utf8)))
        XCTAssertThrowsError(try BackupService.decode(Data()))
        var s = LedgerState.initial
        s.entries.append(Entry(bookID: s.books[0].id, accountID: s.accounts[0].id, kind: .income, amount: 100))
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: BackupService.export(s)) as? [String: Any])
        var payload = try XCTUnwrap(object["data"] as? [String: Any]); payload["accountPostings"] = []; object["data"] = payload
        XCTAssertThrowsError(try BackupService.decode(JSONSerialization.data(withJSONObject: object)))
    }
    func testCSVInjectionQuotingAndDecimalPlaces() throws {
        var s = LedgerState.initial
        s.entries.append(Entry(bookID: s.books[0].id, accountID: s.accounts[0].id, kind: .income, amount: 1200, note: "=SUM(1,2)\n\"引号\""))
        let csv = String(decoding: BackupService.csv(s), as: UTF8.self)
        XCTAssertTrue(csv.hasPrefix("\u{FEFF}")); XCTAssertTrue(csv.contains("\"12.00\""))
        XCTAssertTrue(csv.contains("\"'=SUM(1,2)\n\"\"引号\"\"\"")); XCTAssertTrue(csv.contains(s.entries[0].id.uuidString))
    }
    func testLoanDeletionAndAccountConstraints() throws {
        var s = LedgerState.initial
        let loan = Loan(person: "朋友", isLent: true); s.loans.append(loan)
        let e = Entry(bookID: s.books[0].id, accountID: s.accounts[0].id, kind: .lend, amount: 100, loanID: loan.id)
        s.entries.append(e)
        let repayment = Entry(bookID: s.books[0].id, accountID: s.accounts[0].id, kind: .collect, amount: 20, loanID: loan.id)
        s.entries.append(repayment)
        XCTAssertThrowsError(try BookkeepingService.remove(e, from: &s))
        try BookkeepingService.remove(repayment, from: &s); try BookkeepingService.remove(e, from: &s)
        XCTAssertTrue(s.loans.isEmpty)
        s.accounts[0].archived = true; XCTAssertThrowsError(try s.validate())
    }
    func testDebtTargetBalanceEntryParsing() throws {
        XCTAssertEqual(try Money.parse("0", signed: false, allowZero: true), 0)
        XCTAssertEqual(try Money.parse("100.01", signed: false), 10_001)
        XCTAssertThrowsError(try Money.parse("-100", signed: false))
    }
    func testTargetBalanceAdjustment() throws {
        var s = LedgerState.initial; s.accounts[0].opening = 1000
        try BookkeepingService.adjust(accountID: s.accounts[0].id, target: 0, reason: "盘点", date: Date(), state: &s)
        try s.validate(); XCTAssertEqual(s.balance(s.accounts[0].id), 0)
        XCTAssertEqual(s.entries[0].amount, -1000); XCTAssertEqual(s.entries[0].kind, .adjustment)
    }
}

final class DatabaseSafetyTests: XCTestCase {
    func testSQLiteWriteFailureRollsBackAllRows() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let repo = try SQLiteLedgerRepository(path: path)
        let initial = LedgerState.initial; try repo.save(initial)
        let connection = try DatabaseQueue(path: path)
        try connection.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_posting BEFORE INSERT ON postings BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        }
        var next = initial
        next.books.append(Book(name: "不应残留的账本"))
        next.entries.append(Entry(bookID: initial.books[0].id, accountID: initial.accounts[0].id, kind: .income, amount: 100))
        XCTAssertThrowsError(try repo.save(next))
        XCTAssertEqual(try repo.load(), initial)
        XCTAssertEqual(try connection.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM transactions") }, 0)
    }
    func testLegacyDatabaseMigration() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let s = LedgerState.initial
        let connection = try DatabaseQueue(path: path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: "CREATE TABLE ledger (id INTEGER PRIMARY KEY,payload BLOB NOT NULL)")
            try db.execute(sql: "INSERT INTO ledger VALUES (1,?)", arguments: [try JSONEncoder().encode(s)])
        }
        try migrator.migrate(connection)
        XCTAssertEqual(try SQLiteLedgerRepository(path: path).load(), s)
    }
    func testBudgetUpdatesAndDeletionRemainConsistent() throws {
        let repo = try SQLiteLedgerRepository(path: ":memory:")
        var state = LedgerState.initial
        let bookID = try XCTUnwrap(state.defaultBookID)
        state.budgets = [Budget(bookID: bookID, month: "2026-10", amount: 10_000)]
        try repo.save(state)
        state.entries.append(Entry(bookID: bookID, accountID: state.accounts[0].id, kind: .expense, amount: 100))
        try repo.save(state)
        XCTAssertEqual(try repo.load()?.budgets, state.budgets)
        state.budgets[0].amount = 20_000
        try repo.save(state)
        XCTAssertEqual(try repo.load()?.budgets, state.budgets)
        state.budgets.removeAll()
        try repo.save(state)
        XCTAssertEqual(try repo.load()?.budgets, [])
    }
    func testTwentyThousandRecordsAndAccountOrder() throws {
        let repo = try SQLiteLedgerRepository(path: ":memory:")
        var s = LedgerState.initial
        let bank = Account(name: "银行", kind: .bank); s.accounts.insert(bank, at: 0)
        s.entries = (0..<20_000).map { _ in Entry(bookID: s.books[0].id, accountID: bank.id, kind: .income, amount: 1) }
        try repo.save(s)
        let loaded = try XCTUnwrap(repo.load())
        XCTAssertEqual(loaded.entries.count, 20_000); XCTAssertEqual(loaded.balance(bank.id), 20_000)
        XCTAssertEqual(loaded.accounts.map(\.id), s.accounts.map(\.id))
        s.entries[0].amount = 5; s.accounts.reverse(); try repo.save(s)
        XCTAssertEqual(try repo.load()?.balance(bank.id), 20_004)
        XCTAssertEqual(try repo.load()?.accounts.map(\.id), s.accounts.map(\.id))
    }
}

final class BackupFileTests: XCTestCase {
    func testDedicatedBackupAndLegacyJSONUseIdenticalValidation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = LedgerState.demonstration
        for name in ["fictional.pocketledger", "fictional.json", "FICTIONAL.JSON"] {
            let url = directory.appendingPathComponent(name)
            try BackupService.export(state).write(to: url)
            let backup = try BackupService.readFile(url)
            XCTAssertEqual(backup.data.netWorth, state.netWorth)
            XCTAssertEqual(backup.data.entries.map(\.id), state.entries.map(\.id))
        }
    }
    func testInvalidFilesDoNotChangeDatabase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = try SQLiteLedgerRepository(path: ":memory:")
        let initial = LedgerState.initial; try repo.save(initial)
        let csv = directory.appendingPathComponent("not-a-backup.csv")
        try BackupService.csv(.demonstration).write(to: csv)
        XCTAssertThrowsError(try BackupService.readFile(csv))
        let broken = directory.appendingPathComponent("broken.json")
        try Data("invalid".utf8).write(to: broken)
        XCTAssertThrowsError(try BackupService.readFile(broken))
        XCTAssertThrowsError(try BackupService.readFile(directory.appendingPathComponent("missing.json")))
        XCTAssertThrowsError(try BackupService.readFile(URL(string: "https://example.invalid/backup.json")!))
        XCTAssertEqual(try repo.load(), initial)
    }
    func testOversizedFileIsRejectedBeforeReading() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pocketledger")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(BackupService.maximumFileSize + 1)); try handle.close()
        XCTAssertThrowsError(try BackupService.readFile(url))
    }
    func testDemonstrationIsExplicitAndFreshInstallStaysEmpty() throws {
        let demo = LedgerState.demonstration
        try demo.validate()
        XCTAssertTrue(demo.accounts.allSatisfy { $0.name.hasPrefix("示例") })
        XCTAssertTrue(demo.books.allSatisfy { $0.name.hasPrefix("示例") })
        XCTAssertTrue(demo.entries.allSatisfy { $0.note.hasPrefix("虚构") })
        let initial = LedgerState.initial
        XCTAssertTrue(initial.entries.isEmpty)
        XCTAssertTrue(initial.loans.isEmpty)
        XCTAssertTrue(initial.accounts.allSatisfy { $0.opening == 0 })
    }
}
