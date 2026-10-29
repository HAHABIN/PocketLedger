import Foundation
import GRDB

public protocol LedgerRepository {
    func load() throws -> LedgerState?
    func save(_ state: LedgerState) throws
}
// A versioned SQLite snapshot is committed atomically. Balances are derived, never stored twice.
public final class SQLiteLedgerRepository: LedgerRepository {
    private let queue: DatabaseQueue
    public init(path: String) throws {
        queue = try DatabaseQueue(path: path)
        var migration = DatabaseMigrator()
        migration.registerMigration("v1") { db in
            try db.create(table: "ledger") { t in t.column("id", .integer).primaryKey(); t.column("payload", .blob).notNull() }
        }
        try migration.migrate(queue)
    }
    public func load() throws -> LedgerState? {
        try queue.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM ledger WHERE id = 1") else { return nil }
            let state = try JSONDecoder().decode(LedgerState.self, from: data)
            try state.validate(); return state
        }
    }
    public func save(_ state: LedgerState) throws {
        try state.validate()
        let data = try JSONEncoder().encode(state)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO ledger (id,payload) VALUES (1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", arguments: [data])
        }
    }
}
