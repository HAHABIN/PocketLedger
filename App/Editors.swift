import SwiftUI
import LedgerCore

struct EntryEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    var existing: Entry? = nil
    var loan: Loan? = nil
    @State private var kind = EntryKind.expense
    @State private var amount = ""
    @State private var book: UUID?
    @State private var account: UUID?
    @State private var target: UUID?
    @State private var category = "餐饮"
    @State private var note = ""
    @State private var person = ""
    @State private var date = Date()
    @State private var due = Date()
    @State private var hasDue = false
    var body: some View {
        NavigationStack {
            Form {
                if existing == nil && loan == nil {
                    Picker("类型", selection: $kind) { ForEach([EntryKind.expense, .income, .transfer, .lend, .borrow], id: \.self) { Text($0.rawValue).tag($0) } }
                } else { Text(kind.rawValue) }
                TextField("金额（元）", text: $amount).keyboardType(.decimalPad).font(.largeTitle)
                Picker("账本", selection: $book) { ForEach(store.state.books) { Text($0.name).tag(Optional($0.id)) } }
                Picker("账户", selection: $account) { ForEach(store.state.accounts) { Text($0.name).tag(Optional($0.id)) } }
                if kind == .transfer { Picker("转入账户", selection: $target) { Text("请选择").tag(UUID?.none); ForEach(store.activeAccounts) { Text($0.name).tag(Optional($0.id)) } } }
                if kind == .expense || kind == .income { Picker("分类", selection: $category) { ForEach(store.state.categories, id: \.self) { Text($0).tag($0) } } }
                if kind == .lend || kind == .borrow {
                    TextField("对方姓名", text: $person)
                    Toggle("约定还款日期", isOn: $hasDue)
                    if hasDue { DatePicker("到期日", selection: $due, displayedComponents: .date) }
                }
                DatePicker("发生日期", selection: $date)
                TextField("备注", text: $note)
                if let loan { Text("未结清：\(Money.format(store.state.outstanding(loan.id)))") }
            }.navigationTitle(existing == nil ? "记一笔" : "编辑交易")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) } }
                .onAppear {
                    book = existing?.bookID ?? store.bookID ?? store.state.defaultBookID; account = existing?.accountID ?? store.activeAccounts.first?.id
                    if let existing {
                        kind = existing.kind; amount = NSDecimalNumber(decimal: Decimal(existing.amount) / 100).stringValue
                        target = existing.targetID; category = existing.category; date = existing.date; note = existing.note
                        if let l = store.state.loans.first(where: { $0.id == existing.loanID }) { person = l.person; hasDue = l.dueDate != nil; due = l.dueDate ?? Date() }
                    } else if let loan { kind = loan.isLent ? .collect : .repay }
                }
        }
    }
    func save() {
        store.attempt {
            let cents = try Money.parse(amount, signed: kind == .adjustment)
            guard let book, let account else { throw LedgerError.invalid("请选择账本和账户") }
            if store.perform({ s in
                var loanID = existing?.loanID ?? loan?.id
                if kind == .lend || kind == .borrow {
                    if let id = loanID, let i = s.loans.firstIndex(where: { $0.id == id }) { s.loans[i].person = person; s.loans[i].dueDate = hasDue ? due : nil }
                    else { let item = Loan(person: person, isLent: kind == .lend, dueDate: hasDue ? due : nil); s.loans.append(item); loanID = item.id }
                }
                var e = Entry(bookID: book, accountID: account, kind: kind, amount: cents, category: category, date: date, note: note, targetID: kind == .transfer ? target : nil, loanID: loanID)
                if let existing { e.id = existing.id; s.entries.removeAll { $0.id == existing.id } }
                s.entries.append(e)
            }) { dismiss() }
        }
    }
}
struct AssetsView: View {
    @EnvironmentObject var store: Store
    @State private var add = false
    @State private var repayment: Loan?
    var body: some View {
        List {
            Section { SummaryCard(title: "净资产", amount: store.state.netWorth); HStack { SummaryCard(title: "总资产", amount: store.state.assets); SummaryCard(title: "总负债", amount: store.state.liabilities) } }
            Section("资金账户") {
                ForEach(store.state.accounts) { account in
                    NavigationLink { AccountDetail(account: account) } label: { HStack { Label(account.name, systemImage: "creditcard"); Spacer(); MoneyText(amount: store.state.balance(account.id)) } }
                }
                Button("新增账户") { add = true }
            }
            Section("借贷 · 点击记录还款") {
                if store.state.loans.isEmpty { Text("在「记一笔」选择借出或借入").foregroundStyle(.secondary) }
                ForEach(store.state.loans) { loan in
                    Button { repayment = loan } label: {
                        VStack(alignment: .leading) {
                            HStack { Text((loan.isLent ? "待收 · " : "待还 · ") + loan.person); Spacer(); MoneyText(amount: store.state.outstanding(loan.id)) }
                            if let due = loan.dueDate { Text("到期：" + due.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(due < Date() && store.state.outstanding(loan.id) > 0 ? .red : .secondary) }
                        }
                    }.disabled(store.state.outstanding(loan.id) == 0)
                }
            }
        }.navigationTitle("我的资产").sheet(isPresented: $add) { AccountEditor() }.sheet(item: $repayment) { EntryEditor(loan: $0) }
    }
}
struct AccountDetail: View {
    @EnvironmentObject var store: Store
    var account: Account
    @State private var editing: Entry?
    @State private var name = ""
    @State private var adjustment = ""
    var body: some View {
        List {
            SummaryCard(title: "账户余额", amount: store.state.balance(account.id))
            Section("账户设置") {
                TextField("账户名称", text: $name)
                Button("保存名称") { store.perform { s in if let i = s.accounts.firstIndex(where: { $0.id == account.id }) { s.accounts[i].name = name } } }
                TextField("余额调整差额，可负数（元）", text: $adjustment)
                Button("记录余额调整") { store.attempt { let value = try Money.parse(adjustment, signed: true); if store.perform({ $0.entries.append(Entry(bookID: store.state.defaultBookID!, accountID: account.id, kind: .adjustment, amount: value, category: "余额调整")) }) { adjustment = "" } } }
            }
            Section("账户流水") { ForEach(store.entries(book: nil, account: account.id)) { entry in Button { editing = entry } label: { EntryRow(entry: entry) } } }
        }.navigationTitle(account.name).onAppear { name = account.name }.sheet(item: $editing) { EntryEditor(existing: $0) }
    }
}
struct AccountEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var kind = AccountKind.bank
    @State private var balance = "0"
    var body: some View {
        NavigationStack { Form {
            TextField("账户名称", text: $name)
            Picker("类型", selection: $kind) { ForEach(AccountKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            TextField("初始余额（负数表示欠款）", text: $balance)
            Text("账户由所有账本共用，信用卡欠款请输入负数。").font(.caption)
        }.navigationTitle("新增账户").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("保存") { store.attempt { let value = try Money.parse(balance, signed: true); if store.perform({ $0.accounts.append(Account(name: name, kind: kind, opening: value)) }) { dismiss() } } } } } }
    }
}
struct BooksView: View {
    @EnvironmentObject var store: Store
    @State private var name = ""
    var body: some View {
        List {
            Section("创建账本") { TextField("账本名称", text: $name); Button("创建") { if store.perform({ $0.books.append(Book(name: name)) }) { name = "" } } }
            Section("全部账本") { ForEach(store.state.books) { book in NavigationLink { BookDetail(id: book.id) } label: { HStack { Label(book.name, systemImage: "book.closed"); Spacer(); Text(book.archived ? "已归档" : book.id == store.state.defaultBookID ? "默认" : "").font(.caption).foregroundStyle(.secondary) } } } }
        }.navigationTitle("我的账本")
    }
}
struct BookDetail: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let id: UUID
    @State private var name = ""
    @State private var budget = ""
    @State private var date = Date()
    @State private var confirm = false
    var body: some View {
        Form {
            TextField("名称", text: $name)
            Button("保存名称") { store.perform { s in if let i = s.books.firstIndex(where: { $0.id == id }) { s.books[i].name = name } } }
            Button("切换到此账本") { store.bookID = id }
            Button("设为默认") { store.perform { $0.defaultBookID = id } }
            Button("归档 / 取消归档") { store.perform { s in if let i = s.books.firstIndex(where: { $0.id == id }) { s.books[i].archived.toggle() } } }
            Section("月度预算") { DatePicker("月份", selection: $date, displayedComponents: .date); TextField("预算金额（元）", text: $budget).keyboardType(.decimalPad); Button("保存预算") { store.attempt { let value = try Money.parse(budget); store.perform { s in s.budgets.removeAll { $0.bookID == id && $0.month == LedgerState.month(date) }; s.budgets.append(Budget(bookID: id, month: LedgerState.month(date), amount: value)) } } } }
            Button("删除空账本", role: .destructive) { confirm = true }
        }.navigationTitle("账本设置").onAppear { name = store.state.books.first { $0.id == id }?.name ?? "" }
            .confirmationDialog("仅允许删除没有交易的非默认账本", isPresented: $confirm) { Button("删除", role: .destructive) { if store.perform({ s in guard !s.entries.contains(where: { $0.bookID == id }) else { throw LedgerError.invalid("账本存在交易，请归档保留历史数据") }; s.books.removeAll { $0.id == id }; s.budgets.removeAll { $0.bookID == id } }) { dismiss() } } }
    }
}
