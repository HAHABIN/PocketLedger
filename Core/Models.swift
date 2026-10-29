import Foundation

public enum LedgerError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

public enum Money {
    // Bounded to keep every sum exact and reject hostile backup amounts.
    public static let limit: Int64 = 1_000_000_000_000
    public static func parse(_ text: String, signed: Bool = false) throws -> Int64 {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = signed ? #"^-?\d{1,10}(\.\d{1,2})?$"# : #"^\d{1,10}(\.\d{1,2})?$"#
        guard value.range(of: pattern, options: .regularExpression) != nil,
              let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
            throw LedgerError.invalid("请输入最多两位小数的金额")
        }
        let result = NSDecimalNumber(decimal: decimal * 100).int64Value
        guard abs(result) <= limit, signed || result > 0 else { throw LedgerError.invalid("金额必须大于零且不超过100亿元") }
        return result
    }
    public static func format(_ cents: Int64) -> String {
        let n = Decimal(cents) / 100
        let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = "CNY"; f.locale = Locale(identifier: "zh_CN")
        return f.string(from: NSDecimalNumber(decimal: n)) ?? "¥0.00"
    }
}

public struct Book: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var archived = false
    public init(name: String) { self.name = name }
}
public enum AccountKind: String, Codable, CaseIterable { case cash = "现金", bank = "银行卡", wallet = "支付账户", credit = "信用卡" }
public struct Account: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var kind: AccountKind
    // Signed balance: negative means debt, including credit card debt.
    public var opening: Int64
    public var archived = false
    public init(name: String, kind: AccountKind, opening: Int64 = 0) { self.name = name; self.kind = kind; self.opening = opening }
}
public enum EntryKind: String, Codable, CaseIterable { case expense = "支出", income = "收入", transfer = "转账", lend = "借出", borrow = "借入", collect = "收回借款", repay = "偿还借款", adjustment = "余额调整" }
public struct Entry: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var bookID: UUID
    public var accountID: UUID
    public var targetID: UUID?
    public var loanID: UUID?
    public var kind: EntryKind
    public var amount: Int64
    public var category: String
    public var date: Date
    public var note: String
    public init(bookID: UUID, accountID: UUID, kind: EntryKind, amount: Int64, category: String = "其他", date: Date = Date(), note: String = "", targetID: UUID? = nil, loanID: UUID? = nil) {
        self.bookID = bookID; self.accountID = accountID; self.kind = kind; self.amount = amount
        self.category = category; self.date = date; self.note = note; self.targetID = targetID; self.loanID = loanID
    }
}
public struct Loan: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var person: String
    public var isLent: Bool
    public var dueDate: Date?
    public init(person: String, isLent: Bool, dueDate: Date? = nil) { self.person = person; self.isLent = isLent; self.dueDate = dueDate }
}
public struct Budget: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var bookID: UUID
    public var month: String // Gregorian yyyy-MM, local timezone
    public var amount: Int64
    public init(bookID: UUID, month: String, amount: Int64) { self.bookID = bookID; self.month = month; self.amount = amount }
}
public struct LedgerState: Codable, Equatable {
    public var books: [Book] = []
    public var accounts: [Account] = []
    public var entries: [Entry] = []
    public var loans: [Loan] = []
    public var budgets: [Budget] = []
    public var categories = ["餐饮", "交通", "购物", "居住", "娱乐", "医疗", "工资", "奖金", "其他"]
    public var defaultBookID: UUID?
    public init() {}
    public static var initial: LedgerState {
        var s = LedgerState(); let b = Book(name: "日常账本"); s.books = [b]; s.defaultBookID = b.id
        s.accounts = [Account(name: "现金", kind: .cash)]; return s
    }
    public func balance(_ id: UUID) -> Int64 {
        guard let account = accounts.first(where: { $0.id == id }) else { return 0 }
        return entries.reduce(account.opening) { total, e in
            if e.accountID == id {
                switch e.kind {
                case .expense, .transfer, .lend, .repay: return total - e.amount
                default: return total + e.amount
                }
            }
            return e.kind == .transfer && e.targetID == id ? total + e.amount : total
        }
    }
    public func outstanding(_ id: UUID) -> Int64 {
        entries.filter { $0.loanID == id }.reduce(0) { total, e in
            total + ((e.kind == .lend || e.kind == .borrow) ? e.amount : -e.amount)
        }
    }
    public var receivable: Int64 { loans.filter(\.isLent).reduce(0) { $0 + outstanding($1.id) } }
    public var payable: Int64 { loans.filter { !$0.isLent }.reduce(0) { $0 + outstanding($1.id) } }
    public var assets: Int64 { accounts.reduce(receivable) { $0 + max(0, balance($1.id)) } }
    public var liabilities: Int64 { accounts.reduce(payable) { $0 + max(0, -balance($1.id)) } }
    public var netWorth: Int64 { assets - liabilities }
    public static func month(_ date: Date) -> String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM"; f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: date)
    }
    public func validate() throws {
        func require(_ condition: Bool, _ message: String) throws { if !condition { throw LedgerError.invalid(message) } }
        func unique<T: Identifiable>(_ values: [T]) -> Bool where T.ID: Hashable { Set(values.map(\.id)).count == values.count }
        try require(entries.count <= 100_000 && accounts.count <= 1000 && books.count <= 1000 && loans.count <= 100_000 && budgets.count <= 120_000, "备份数据数量超过限制")
        try require(unique(books) && unique(accounts) && unique(entries) && unique(loans) && unique(budgets), "存在重复ID")
        try require(!books.isEmpty && books.contains { !$0.archived && $0.id == defaultBookID }, "默认账本必须存在且未归档")
        try require(!accounts.isEmpty, "至少保留一个账户")
        try require(books.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 60 }, "账本名称无效")
        try require(accounts.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 60 && $0.opening >= -Money.limit && $0.opening <= Money.limit }, "账户无效")
        try require(categories.count <= 200 && Set(categories).count == categories.count && !categories.isEmpty && categories.allSatisfy { !$0.isEmpty && $0.count <= 40 }, "分类无效")
        let bookIDs = Set(books.map(\.id)), accountIDs = Set(accounts.map(\.id))
        for e in entries {
            try require(bookIDs.contains(e.bookID) && accountIDs.contains(e.accountID), "交易引用了不存在的账本或账户")
            try require(e.date.timeIntervalSince1970.isFinite && e.note.count <= 2000 && e.category.count <= 40, "交易日期或备注无效")
            try require(e.amount >= -Money.limit && e.amount <= Money.limit && (e.kind == .adjustment || e.amount > 0), "交易金额无效")
            if e.kind == .transfer {
                try require(e.targetID != e.accountID && e.targetID.map(accountIDs.contains) == true && e.loanID == nil, "转入转出账户必须不同且存在")
            } else { try require(e.targetID == nil, "非转账交易不能包含转入账户") }
            let isLoan = [.lend, .borrow, .collect, .repay].contains(e.kind)
            if isLoan {
                guard let loan = loans.first(where: { $0.id == e.loanID }) else { throw LedgerError.invalid("借贷关联不存在") }
                try require(loan.isLent ? [.lend, .collect].contains(e.kind) : [.borrow, .repay].contains(e.kind), "借贷方向不匹配")
            } else { try require(e.loanID == nil, "普通交易不能关联借贷") }
        }
        for loan in loans {
            try require(!loan.person.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && loan.person.count <= 60, "借贷对象无效")
            let linked = entries.filter { $0.loanID == loan.id }
            let principal = linked.filter { $0.kind == .lend || $0.kind == .borrow }
            try require(principal.count == 1 && outstanding(loan.id) >= 0, "借贷本金缺失、重复或还款超过本金")
            try require(linked.allSatisfy { $0.date >= principal[0].date }, "还款日期不能早于借款日期")
        }
        var budgetKeys = Set<String>()
        for budget in budgets {
            try require(bookIDs.contains(budget.bookID) && budget.amount > 0 && budget.amount <= Money.limit && budget.month.range(of: #"^\d{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil, "预算无效")
            try require(budgetKeys.insert("\(budget.bookID)-\(budget.month)").inserted, "同账本同月份预算重复")
        }
    }
}
