import XCTest
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
        s.entries.append(Entry(bookID: s.books[0].id, accountID: a, kind: .transfer, amount: 3000, targetID: credit.id))
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
        XCTAssertEqual(try BackupService.restore(s, into: s, mode: .merge), s)
        var conflict = s; conflict.accounts[0].opening = 100
        XCTAssertThrowsError(try BackupService.restore(conflict, into: s, mode: .merge))
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
