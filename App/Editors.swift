import SwiftUI
import LedgerCore

struct EntryEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    var existing: Entry? = nil
    var loan: Loan? = nil
    var initialKind = EntryKind.expense
    var initialCategory = "餐饮"
    var initialAccount: UUID? = nil
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
    @State private var discard = false
    @State private var baseline = ""
    @State private var localError: String?
    @FocusState private var amountFocused: Bool
    var fingerprint: String { "\(kind)|\(amount)|\(book?.uuidString ?? "")|\(account?.uuidString ?? "")|\(target?.uuidString ?? "")|\(category)|\(note)|\(person)|\(date)|\(due)|\(hasDue)" }
    var selectableAccounts: [Account] { store.state.accounts.filter { (!$0.archived || $0.id == existing?.accountID) && ((kind == .lend || kind == .borrow || kind == .collect || kind == .repay || kind == .transfer || kind == .creditRepayment) ? !$0.kind.isDebt : true) } }
    var targets: [Account] { store.activeAccounts.filter { $0.id != account && (kind == .creditRepayment ? $0.kind.isDebt : !$0.kind.isDebt) } }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if existing == nil && loan == nil && ![EntryKind.lend, .borrow, .creditRepayment].contains(initialKind) {
                        Picker("类型", selection: $kind) { ForEach([EntryKind.expense, .income, .transfer], id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    } else { Text(kind.rawValue).font(.headline) }
                    TextField("0.00", text: $amount).keyboardType(.decimalPad).font(.system(size: 40, weight: .semibold, design: .rounded)).focused($amountFocused).accessibilityLabel("金额，元")
                }
                if kind == .expense || kind == .income {
                    Section("分类") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72))], spacing: 12) {
                            ForEach(store.state.categories + ((existing != nil && !store.state.categories.contains(existing!.category) && (existing!.kind == .expense || existing!.kind == .income)) ? [existing!.category] : []), id: \.self) { item in
                                Button { category = item } label: { VStack(spacing: 6) { DesignIcon(symbol: categoryIcon(item), color: categoryColor(item), size: 42); Text(item).font(.caption) }.frame(maxWidth: .infinity).frame(minHeight: 60).foregroundStyle(category == item ? Color.brand : Color.primary).background(category == item ? Color.brand.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 12)) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                Section {
                    Picker("账本", selection: $book) { ForEach(store.state.books.filter { !$0.archived || $0.id == existing?.bookID }) { Text($0.name).tag(Optional($0.id)) } }
                    Picker(kind == .transfer || kind == .creditRepayment ? "转出账户" : "资金账户", selection: $account) { Text("请选择").tag(UUID?.none); ForEach(selectableAccounts) { Text($0.name).tag(Optional($0.id)) } }
                    if kind == .transfer || kind == .creditRepayment { Picker("转入账户", selection: $target) { Text("请选择").tag(UUID?.none); ForEach(targets) { Text($0.name).tag(Optional($0.id)) } } }
                    if kind == .lend || kind == .borrow {
                        TextField("对方姓名", text: $person)
                        Toggle("约定还款日期", isOn: $hasDue)
                        if hasDue { DatePicker("到期日", selection: $due, displayedComponents: .date) }
                    }
                    DatePicker("发生日期", selection: $date)
                    TextField("备注", text: $note, axis: .vertical).lineLimit(2...4)
                    if let loan { Text("未结清：\(Money.format(store.state.outstanding(loan.id)))") }
                    if kind == .creditRepayment { Text("还款同时减少资金账户和负债，不计入支出。").font(.caption).foregroundStyle(.secondary) }
                }
                if let localError { Text(localError).foregroundStyle(Color.expense) }
            }.scrollContentBackground(.hidden).background(Color(uiColor: .systemBackground)).navigationTitle(existing == nil ? "记一笔" : "编辑交易").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) { Button("保存", action: { Task { await save() } }).disabled(store.saving).buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity).padding().background(.regularMaterial) }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { if baseline != fingerprint { discard = true } else { dismiss() } } }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { amountFocused = false } }
                }.onAppear(perform: load)
                .onChange(of: kind) { if existing == nil && loan == nil { if !selectableAccounts.contains(where: { $0.id == account }) { account = selectableAccounts.first?.id }; target = nil } }
                .interactiveDismissDisabled(baseline != fingerprint)
                .confirmationDialog("放弃未保存的修改？", isPresented: $discard, titleVisibility: .visible) { Button("放弃修改", role: .destructive) { dismiss() } }
        }
    }
    func load() {
        guard baseline.isEmpty else { return }
        kind = existing?.kind ?? (loan.map { $0.isLent ? .collect : .repay } ?? initialKind)
        book = existing?.bookID ?? store.bookID ?? store.state.defaultBookID
        account = existing?.accountID ?? initialAccount ?? selectableAccounts.first?.id
        category = existing?.category ?? (store.state.categories.contains(initialCategory) ? initialCategory : store.state.categories.first ?? "其他")
        if let existing {
            amount = NSDecimalNumber(decimal: Decimal(existing.amount) / 100).stringValue
            target = existing.targetID; date = existing.date; note = existing.note
            if let l = store.state.loans.first(where: { $0.id == existing.loanID }) { person = l.person; hasDue = l.dueDate != nil; due = l.dueDate ?? due }
        }
        baseline = fingerprint
    }
    func save() async {
        do {
            let cents = try Money.parse(amount, signed: kind == .adjustment)
            guard let book, let account else { throw LedgerError.invalid("请选择账本和账户") }
            if await store.perform({ s in
                var loanID = existing?.loanID ?? loan?.id
                if kind == .lend || kind == .borrow {
                    if let id = loanID, let i = s.loans.firstIndex(where: { $0.id == id }) { s.loans[i].person = person; s.loans[i].dueDate = hasDue ? due : nil }
                    else { let item = Loan(person: person, isLent: kind == .lend, dueDate: hasDue ? due : nil); s.loans.append(item); loanID = item.id }
                }
                var e = Entry(bookID: book, accountID: account, kind: kind, amount: cents, category: kind == .expense || kind == .income ? category : kind.rawValue, date: date, note: note, targetID: kind == .transfer || kind == .creditRepayment ? target : nil, loanID: loanID)
                if let existing { e.id = existing.id; e.createdAt = existing.createdAt; e.updatedAt = Date(); s.entries.removeAll { $0.id == existing.id } }
                s.entries.append(e)
            }) { dismiss() } else { localError = store.error; store.error = nil }
        } catch { localError = error.localizedDescription }
    }
}

struct AssetsView: View {
    @EnvironmentObject var store: Store
    @State private var add = false
    @State private var transfer = false
    @State private var repayment = false
    @State private var filter: AccountKind?
    @State private var archived = false
    var body: some View {
        List {
            Section {
                GradientOverview(title: "净资产（元）", main: store.state.netWorth, items: [("总资产", store.state.assets), ("总负债", store.state.liabilities)])
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                Button("还信用卡 / 偿还其他负债") { repayment = true }
            }.listRowSeparator(.hidden)
            Section {
                Picker("账户类型", selection: $filter) { Text("全部").tag(AccountKind?.none); ForEach(AccountKind.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) } }
                Toggle("显示归档账户", isOn: $archived)
            }
            Section("资产账户") { accountRows(debt: false) }
            Section("负债账户 · 显示当前欠款") { accountRows(debt: true) }
            Section("借贷管理") {
                NavigationLink { LoansView(isLent: true) } label: { HStack { Text("我借出 · 待收回"); Spacer(); MoneyText(amount: store.state.receivable) } }
                NavigationLink { LoansView(isLent: false) } label: { HStack { Text("我借入 · 待偿还"); Spacer(); MoneyText(amount: store.state.payable) } }
            }
            Button("添加资金账户", systemImage: "plus.circle") { add = true }
        }.listSectionSpacing(16).navigationTitle("资产").navigationBarTitleDisplayMode(.inline).toolbar { EditButton(); Button("转账") { transfer = true } }
        .sheet(isPresented: $add) { AccountEditor() }
        .sheet(isPresented: $transfer) { EntryEditor(initialKind: .transfer) }
        .sheet(isPresented: $repayment) { EntryEditor(initialKind: .creditRepayment) }
    }
    @ViewBuilder func accountRows(debt: Bool) -> some View {
        let accounts = store.state.accounts.filter { $0.kind.isDebt == debt && (archived || !$0.archived) && (filter == nil || filter == $0.kind) }
        if accounts.isEmpty { Text("暂无账户").foregroundStyle(.secondary) }
        ForEach(accounts) { account in
            NavigationLink { AccountDetail(id: account.id) } label: {
                HStack { DesignIcon(symbol: account.icon ?? "creditcard", color: account.kind.isDebt ? .orange : account.kind == .cash ? .blue : account.kind == .wallet ? .green : .brand, size: 34); Text(account.name + (account.archived ? " · 已归档" : "")); Spacer(); MoneyText(amount: debt ? -store.state.balance(account.id) : store.state.balance(account.id)) }
            }
        }.onMove { indices, destination in
            Task { await store.perform { s in
                var reordered = accounts; reordered.move(fromOffsets: indices, toOffset: destination)
                let ids = Set(accounts.map(\.id)); var iterator = reordered.makeIterator()
                s.accounts = s.accounts.map { ids.contains($0.id) ? iterator.next()! : $0 }
            } }
        }
    }
}
struct AccountDetail: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let id: UUID
    @State private var edit = false
    @State private var transfer = false
    @State private var adjustment = ""
    @State private var reason = ""
    @State private var date = Date()
    @State private var deletion = false
    var account: Account? { store.state.accounts.first { $0.id == id } }
    var body: some View {
        List {
            if let account {
                SummaryCard(title: account.kind.isDebt ? "当前欠款" : "账户余额", amount: account.kind.isDebt ? -store.state.balance(id) : store.state.balance(id))
                if !account.kind.isDebt && store.state.balance(id) < 0 { Label("账户出现负余额，请核对流水或余额", systemImage: "exclamationmark.triangle").foregroundStyle(Color.expense) }
                Section("本月资金流动 · 包含转账及本金") {
                    let interval = Calendar.current.dateInterval(of: .month, for: Date())!
                    let postings = store.entries(book: nil, interval: interval, account: id).flatMap(BookkeepingService.postings).filter { $0.accountID == id }
                    HStack { Text("流入"); Spacer(); MoneyText(amount: postings.filter { $0.deltaCents > 0 }.reduce(0) { $0 + $1.deltaCents }) }
                    HStack { Text("流出"); Spacer(); MoneyText(amount: -postings.filter { $0.deltaCents < 0 }.reduce(0) { $0 + $1.deltaCents }) }
                }
                Section("账户设置") {
                    Button("编辑名称、图标和统计设置") { edit = true }
                    Button(account.archived ? "重新启用" : "归档账户") { Task { await store.perform { s in if let i = s.accounts.firstIndex(where: { $0.id == id }) { s.accounts[i].archived.toggle() } } } }
                    Button(account.kind.isDebt ? "偿还负债" : "账户转账") { transfer = true }
                    if !store.state.entries.contains(where: { $0.accountID == id || $0.targetID == id }) { Button("删除空账户", role: .destructive) { deletion = true } }
                }
                Section("余额校正 · 不计入收支") {
                    TextField(account.kind.isDebt ? "目标欠款金额（元）" : "目标余额（元，可负数）", text: $adjustment)
                    TextField("校正原因", text: $reason)
                    DatePicker("校正日期", selection: $date)
                    Button("生成校正记录") { Task { await store.attemptAsync {
                        let value = try Money.parse(adjustment, signed: true)
                        if await store.perform({ try BookkeepingService.adjust(accountID: id, target: account.kind.isDebt ? -value : value, reason: reason, date: date, state: &$0) }) { adjustment = ""; reason = "" }
                    } } }
                }
                Section("账户流水") { TransactionRows(entries: store.entries(book: nil, account: id)) }
            }
        }.navigationTitle(account?.name ?? "账户")
        .toolbar { EditButton() }
        .sheet(isPresented: $edit) { AccountEditor(existing: account) }
        .sheet(isPresented: $transfer) { EntryEditor(initialKind: account?.kind.isDebt == true ? .creditRepayment : .transfer, initialAccount: account?.kind.isDebt == true ? nil : id) }
        .confirmationDialog("删除没有交易的账户？", isPresented: $deletion, titleVisibility: .visible) { Button("删除", role: .destructive) { Task { if await store.perform({ $0.accounts.removeAll { $0.id == id } }) { dismiss() } } } }
    }
}
struct AccountEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    var existing: Account? = nil
    @State private var name = ""
    @State private var kind = AccountKind.bank
    @State private var balance = "0"
    @State private var included = true
    @State private var icon = "creditcard"
    @State private var note = ""
    @State private var localError: String?
    @State private var baseline = ""
    @State private var discard = false
    var fingerprint: String { "\(name)|\(kind)|\(balance)|\(included)|\(icon)|\(note)" }
    var body: some View {
        NavigationStack { Form {
            TextField("账户名称", text: $name)
            if existing == nil {
                Picker("类型", selection: $kind) { ForEach(AccountKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                TextField(kind.isDebt ? "初始欠款（元）" : "初始余额（元）", text: $balance)
                Text("初始余额不计入收支。负债账户请输入正数欠款。").font(.caption).foregroundStyle(.secondary)
            }
            Picker("图标", selection: $icon) { ForEach(["creditcard", "banknote", "building.columns", "wallet.pass", "yensign.circle"], id: \.self) { Image(systemName: $0).tag($0) } }
            Toggle("纳入净资产统计", isOn: $included)
            TextField("账户备注", text: $note)
            if let localError { Text(localError).foregroundStyle(Color.expense) }
        }.navigationTitle(existing == nil ? "新增账户" : "编辑账户").toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { if baseline != fingerprint { discard = true } else { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { await save() } }.disabled(store.saving) }
        }.onAppear { guard baseline.isEmpty else { return }; if let existing { name = existing.name; kind = existing.kind; included = existing.includeInNetWorth != false; icon = existing.icon ?? "creditcard"; note = existing.note ?? "" }; baseline = fingerprint }
        .interactiveDismissDisabled(baseline != fingerprint)
        .confirmationDialog("放弃未保存的账户修改？", isPresented: $discard, titleVisibility: .visible) { Button("放弃修改", role: .destructive) { dismiss() } }
        }
    }
    func save() async {
        do {
            let value = existing == nil ? try Money.parse(balance, signed: true) : 0
            guard !kind.isDebt || value >= 0 else { throw LedgerError.invalid("欠款请输入正数；没有欠款请输入0") }
            if await store.perform({ s in
                var item = existing ?? Account(name: name, kind: kind, opening: kind.isDebt ? -value : value)
                item.name = name; item.includeInNetWorth = included; item.icon = icon; item.note = note
                if let i = s.accounts.firstIndex(where: { $0.id == item.id }) { s.accounts[i] = item } else { s.accounts.append(item) }
            }) { dismiss() } else { localError = store.error; store.error = nil }
        } catch { localError = error.localizedDescription }
    }
}
struct LoansView: View {
    @EnvironmentObject var store: Store
    var isLent: Bool
    @State private var add = false
    var loans: [Loan] { store.state.loans.filter { $0.isLent == isLent } }
    var body: some View {
        List {
            Section {
                SummaryCard(title: "未结清", amount: loans.reduce(0) { $0 + store.state.outstanding($1.id) })
                let principal = store.state.entries.filter { e in loans.contains { $0.id == e.loanID } && (e.kind == .lend || e.kind == .borrow) }.reduce(Int64(0)) { $0 + $1.amount }
                HStack { Text("累计本金"); Spacer(); MoneyText(amount: principal) }
                HStack { Text("已归还"); Spacer(); MoneyText(amount: principal - loans.reduce(0) { $0 + store.state.outstanding($1.id) }) }
                LabeledContent("借贷笔数", value: "\(loans.count)")
                LabeledContent("逾期笔数", value: "\(loans.filter { loanStatus($0, state: store.state) == "已逾期" }.count)")
            }
            Section("借贷记录") {
                if loans.isEmpty { Text("暂无借贷记录").foregroundStyle(.secondary) }
                ForEach(loans) { loan in NavigationLink { LoanDetail(id: loan.id) } label: { VStack(alignment: .leading, spacing: 8) { HStack { Text(loan.person); Spacer(); MoneyText(amount: store.state.outstanding(loan.id)) }; Text(loanStatus(loan, state: store.state)).font(.caption).foregroundStyle(.secondary) } } }
            }
            Button("新增\(isLent ? "借出" : "借入")") { add = true }
        }.navigationTitle(isLent ? "我借出" : "我借入").sheet(isPresented: $add) { EntryEditor(initialKind: isLent ? .lend : .borrow) }
    }
}
func loanStatus(_ loan: Loan, state: LedgerState) -> String {
    let outstanding = state.outstanding(loan.id)
    if outstanding == 0 { return "已结清" }
    if let due = loan.dueDate, Calendar.current.startOfDay(for: due) < Calendar.current.startOfDay(for: Date()) { return "已逾期" }
    return state.entries.contains { $0.loanID == loan.id && ($0.kind == .collect || $0.kind == .repay) } ? "部分归还" : "未结清"
}
struct LoanDetail: View {
    @EnvironmentObject var store: Store
    let id: UUID
    @State private var repayment = false
    var loan: Loan? { store.state.loans.first { $0.id == id } }
    var body: some View {
        List {
            if let loan {
                Section {
                    Text(loanStatus(loan, state: store.state)).font(.headline)
                    SummaryCard(title: "剩余本金", amount: store.state.outstanding(id))
                    let principal = store.state.entries.filter { $0.loanID == id && ($0.kind == .lend || $0.kind == .borrow) }.reduce(Int64(0)) { $0 + $1.amount }
                    HStack { Text("起始本金"); Spacer(); MoneyText(amount: principal) }
                    HStack { Text("已归还"); Spacer(); MoneyText(amount: principal - store.state.outstanding(id)) }
                    if let due = loan.dueDate { LabeledContent("约定到期", value: due.formatted(date: .abbreviated, time: .omitted)) }
                    Button(loan.isLent ? "记录收回本金" : "记录偿还本金") { repayment = true }.disabled(store.state.outstanding(id) == 0)
                }
                Section("本金与还款历史 · 点击查看 / 撤销") { TransactionRows(entries: store.state.entries.filter { $0.loanID == id }.sorted { $0.date > $1.date }) }
            }
        }.navigationTitle(loan?.person ?? "借贷详情").sheet(isPresented: $repayment) { if let loan { EntryEditor(loan: loan) } }
    }
}
struct BooksView: View {
    @EnvironmentObject var store: Store
    @State private var name = ""
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ForEach(store.state.books) { book in
                    NavigationLink { BookDetail(id: book.id) } label: {
                        DesignCard {
                            HStack(spacing: 14) {
                                DesignIcon(symbol: book.name.contains("旅行") ? "airplane" : book.name.contains("家庭") ? "house.fill" : "book.closed.fill", color: book.name.contains("旅行") ? .blue : book.name.contains("家庭") ? .orange : .brand, size: 48)
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack { Text(book.name).font(.headline); if book.id == store.state.defaultBookID { Text("默认账本").font(.caption2).padding(.horizontal, 7).padding(.vertical, 4).foregroundStyle(.orange).background(.orange.opacity(0.1), in: Capsule()) } }
                                    let rows = store.entries(book: book.id)
                                    HStack(spacing: 4) { Text("收入"); MoneyText(amount: rows.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount }); Text("支出"); MoneyText(amount: rows.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount }) }.font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
                                    if book.archived { Text("已归档").font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 0); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }.buttonStyle(.plain)
                }
                DesignCard {
                    TextField("新账本名称", text: $name).padding(12).background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                    Button { Task { if await store.perform({ $0.books.append(Book(name: name)) }) { name = "" } } } label: { Label("创建新账本", systemImage: "plus").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(14).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.brand.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5]))) }.disabled(store.saving)
                }
            }.padding(16)
        }.background(Color(uiColor: .systemGroupedBackground)).navigationTitle("我的账本").navigationBarTitleDisplayMode(.inline)
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
    var archived: Bool { store.state.books.first { $0.id == id }?.archived ?? true }
    var body: some View {
        List {
            Section("账本设置") {
                TextField("名称", text: $name)
                Button("保存名称") { Task { await store.perform { s in if let i = s.books.firstIndex(where: { $0.id == id }) { s.books[i].name = name } } } }
                Button("切换到此账本") { store.bookID = id }.disabled(archived)
                Button("设为默认") { Task { await store.perform { $0.defaultBookID = id } } }.disabled(archived)
                Button(archived ? "取消归档" : "归档账本") { Task { await store.perform { s in if let i = s.books.firstIndex(where: { $0.id == id }) { s.books[i].archived.toggle() } } } }.disabled(id == store.state.defaultBookID)
            }
            Section("月度预算") {
                DatePicker("月份", selection: $date, displayedComponents: .date)
                TextField("预算金额（元）", text: $budget).keyboardType(.decimalPad)
                Button("保存预算") { Task { await store.attemptAsync { let value = try Money.parse(budget); await store.perform { s in s.budgets.removeAll { $0.bookID == id && $0.month == LedgerState.month(date) }; s.budgets.append(Budget(bookID: id, month: LedgerState.month(date), amount: value)) } } } }
                Button("移除此月预算") { Task { await store.perform { $0.budgets.removeAll { $0.bookID == id && $0.month == LedgerState.month(date) } } } }
            }
            Section("账本全部交易") { TransactionRows(entries: store.entries(book: id)) }
            Button("删除空账本", role: .destructive) { confirm = true }.disabled(id == store.state.defaultBookID)
        }.navigationTitle("账本详情").onAppear { name = store.state.books.first { $0.id == id }?.name ?? ""; loadBudget() }
            .onChange(of: date) { loadBudget() }
            .confirmationDialog("仅允许删除没有交易的非默认账本", isPresented: $confirm) { Button("删除", role: .destructive) { Task { if await store.perform({ s in guard !s.entries.contains(where: { $0.bookID == id }) else { throw LedgerError.invalid("账本存在交易，请归档保留历史数据") }; s.books.removeAll { $0.id == id }; s.budgets.removeAll { $0.bookID == id } }) { dismiss() } } } }
    }
    func loadBudget() {
        budget = store.state.budgets.first { $0.bookID == id && $0.month == LedgerState.month(date) }.map { NSDecimalNumber(decimal: Decimal($0.amount) / 100).stringValue } ?? ""
    }

}
