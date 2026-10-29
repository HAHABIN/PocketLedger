import Foundation
import GRDB

public protocol LedgerRepository {
    func load() throws -> LedgerState?
    func save(_ state: LedgerState) throws
}

public final class SQLiteLedgerRepository: LedgerRepository, @unchecked Sendable {
    private let queue: DatabaseQueue
    public init(path: String) throws {
        queue = try DatabaseQueue(path: path)
        var migration = DatabaseMigrator()
        migration.registerMigration("v1") { db in
            try db.create(table: "ledger") { t in t.column("id", .integer).primaryKey(); t.column("payload", .blob).notNull() }
        }
        migration.registerMigration("v2-relational-postings") { db in
            try db.execute(sql: """
                CREATE TABLE books (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE accounts (id TEXT PRIMARY KEY, opening INTEGER NOT NULL, payload BLOB NOT NULL, sort_order INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE loans (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE transactions (id TEXT PRIMARY KEY, book_id TEXT NOT NULL REFERENCES books(id), account_id TEXT NOT NULL REFERENCES accounts(id), target_id TEXT REFERENCES accounts(id), loan_id TEXT REFERENCES loans(id), occurred_at REAL NOT NULL, kind TEXT NOT NULL, amount INTEGER NOT NULL, category TEXT NOT NULL, payload BLOB NOT NULL);
                CREATE INDEX transaction_book_date ON transactions(book_id, occurred_at);
                CREATE INDEX transaction_account_date ON transactions(account_id, occurred_at);
                CREATE INDEX transaction_loan ON transactions(loan_id);
                CREATE TABLE postings (id TEXT PRIMARY KEY, transaction_id TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE, account_id TEXT NOT NULL REFERENCES accounts(id), delta INTEGER NOT NULL);
                CREATE INDEX posting_account ON postings(account_id);
                CREATE TABLE budgets (id TEXT PRIMARY KEY, book_id TEXT NOT NULL REFERENCES books(id), payload BLOB NOT NULL);
                CREATE TABLE metadata (id INTEGER PRIMARY KEY, payload BLOB NOT NULL);
                """)
            if let data = try Data.fetchOne(db, sql: "SELECT payload FROM ledger WHERE id=1") {
                var state = try JSONDecoder().decode(LedgerState.self, from: data)
                // Legacy releases represented credit repayment as a transfer.
                for i in state.entries.indices where state.entries[i].kind == .transfer {
                    if state.accounts.first(where: { $0.id == state.entries[i].targetID })?.kind.isDebt == true { state.entries[i].kind = .creditRepayment }
                }
                try state.validate(); try Self.write(state, db: db)
            }
            try db.execute(sql: "DROP TABLE ledger")
        }
        try migration.migrate(queue)
    }
    public func load() throws -> LedgerState? {
        try queue.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM metadata WHERE id=1") else { return nil }
            var state = try JSONDecoder().decode(LedgerState.self, from: data)
            func rows<T: Decodable>(_ table: String) throws -> [T] {
                try Data.fetchAll(db, sql: "SELECT payload FROM \(table) ORDER BY \(table == "accounts" ? "sort_order" : "rowid")").map { try JSONDecoder().decode(T.self, from: $0) }
            }
            state.books = try rows("books"); state.accounts = try rows("accounts"); state.loans = try rows("loans")
            state.entries = try rows("transactions"); state.budgets = try rows("budgets")
            try state.validate()
            let storedPostings = try Row.fetchAll(db, sql: "SELECT transaction_id,account_id,delta FROM postings")
            let stored = Dictionary(uniqueKeysWithValues: storedPostings.map { row in
                ("\(row["transaction_id"] as String):\(row["account_id"] as String)", row["delta"] as Int64)
            })
            let expected = Dictionary(uniqueKeysWithValues: state.postings.map { ($0.id, $0.deltaCents) })
            guard stored == expected else { throw LedgerError.invalid("数据库过账不完整，请从完整备份恢复") }
            return state
        }
    }
    public func save(_ state: LedgerState) throws {
        try state.validate()
        try queue.write { db in try Self.write(state, db: db) }
    }
    private static func write(_ state: LedgerState, db: Database) throws {
        let encoder = JSONEncoder()
        // Diff rows: ordinary saves do not rewrite twenty thousand unchanged records.
        func sync<T: Encodable & Identifiable>(_ table: String, values: [T], insert: (T, Data) throws -> Void) throws where T.ID == UUID {
            let old = try Row.fetchAll(db, sql: "SELECT id,payload FROM \(table)")
            let cache = Dictionary(uniqueKeysWithValues: old.map { ( $0["id"] as String, $0["payload"] as Data) })
            for value in values { let data = try encoder.encode(value); if cache[value.id.uuidString] != data { try insert(value, data) } }
        }
        // Remove child rows before parents to preserve real foreign-key constraints.
        let entryIDs = Set(state.entries.map { $0.id.uuidString })
        for id in try String.fetchAll(db, sql: "SELECT id FROM transactions") where !entryIDs.contains(id) { try db.execute(sql: "DELETE FROM transactions WHERE id=?", arguments: [id]) }
        try sync("books", values: state.books) { v,d in try db.execute(sql: "INSERT INTO books VALUES (?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", arguments: [v.id.uuidString,d]) }
        try sync("accounts", values: state.accounts) { v,d in try db.execute(sql: "INSERT INTO accounts (id,opening,payload) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET opening=excluded.opening,payload=excluded.payload", arguments: [v.id.uuidString,v.opening,d]) }
        for (index, account) in state.accounts.enumerated() { try db.execute(sql: "UPDATE accounts SET sort_order=? WHERE id=?", arguments: [index, account.id.uuidString]) }
        try sync("loans", values: state.loans) { v,d in try db.execute(sql: "INSERT INTO loans VALUES (?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", arguments: [v.id.uuidString,d]) }
        try sync("transactions", values: state.entries) { e,d in
            try db.execute(sql: "INSERT INTO transactions VALUES (?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET book_id=excluded.book_id,account_id=excluded.account_id,target_id=excluded.target_id,loan_id=excluded.loan_id,occurred_at=excluded.occurred_at,kind=excluded.kind,amount=excluded.amount,category=excluded.category,payload=excluded.payload", arguments: [e.id.uuidString,e.bookID.uuidString,e.accountID.uuidString,e.targetID?.uuidString,e.loanID?.uuidString,e.date.timeIntervalSince1970,e.kind.rawValue,e.amount,e.category,d])
            try db.execute(sql: "DELETE FROM postings WHERE transaction_id=?", arguments: [e.id.uuidString])
            for p in BookkeepingService.postings(e) { try db.execute(sql: "INSERT INTO postings VALUES (?,?,?,?)", arguments: [p.id,p.transactionID.uuidString,p.accountID.uuidString,p.deltaCents]) }
        }
        // Budgets can be removed with a book.
        try db.execute(sql: "DELETE FROM budgets")
        for v in state.budgets { try db.execute(sql: "INSERT INTO budgets VALUES (?,?,?)", arguments: [v.id.uuidString,v.bookID.uuidString,try encoder.encode(v)]) }
        for (table, ids) in [("loans", Set(state.loans.map { $0.id.uuidString })), ("accounts", Set(state.accounts.map { $0.id.uuidString })), ("books", Set(state.books.map { $0.id.uuidString }))] {
            for id in try String.fetchAll(db, sql: "SELECT id FROM \(table)") where !ids.contains(id) { try db.execute(sql: "DELETE FROM \(table) WHERE id=?", arguments: [id]) }
        }
        var meta = state; meta.books = []; meta.accounts = []; meta.entries = []; meta.loans = []; meta.budgets = []
        try db.execute(sql: "INSERT INTO metadata VALUES (1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", arguments: [try encoder.encode(meta)])
    }
}
