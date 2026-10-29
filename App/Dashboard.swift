import SwiftUI
import Charts
import LedgerCore

func categoryIcon(_ name: String) -> String {
    ["餐饮": "fork.knife", "交通": "tram", "购物": "bag", "居住": "house", "娱乐": "gamecontroller", "医疗": "cross.case", "工资": "banknote", "奖金": "gift"][name] ?? "square.grid.2x2"
}
struct MoneyText: View {
    @AppStorage("hideAmounts") private var hidden = false
    var amount: Int64
    var body: some View { Text(hidden ? "••••" : Money.format(amount)).monospacedDigit().accessibilityLabel(hidden ? "金额已隐藏" : Money.format(amount)) }
}
struct PrivacyButton: View {
    @AppStorage("hideAmounts") private var hidden = false
    var body: some View { Button { hidden.toggle() } label: { Image(systemName: hidden ? "eye.slash" : "eye") }.accessibilityLabel(hidden ? "显示金额" : "隐藏金额") }
}
struct BookPicker: View {
    @EnvironmentObject var store: Store
    var all = true
    var body: some View {
        Picker("账本", selection: $store.bookID) {
            if all { Text("全部账本").tag(UUID?.none) }
            ForEach(store.activeBooks) { Text($0.name).tag(Optional($0.id)) }
        }
    }
}
struct SummaryCard: View {
    var title: String
    var amount: Int64
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { Text(title).font(.subheadline).foregroundStyle(.secondary); MoneyText(amount: amount).font(.title2.bold()).minimumScaleFactor(0.6).lineLimit(1) }
            .frame(maxWidth: .infinity, alignment: .leading).padding().background(Color.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }
}
struct EntryRow: View {
    @EnvironmentObject var store: Store
    var entry: Entry
    var color: Color { entry.kind == .expense ? .expense : entry.kind == .income ? .income : .blue }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: categoryIcon(entry.category)).foregroundStyle(color).frame(width: 36, height: 36).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.category + " · " + entry.kind.rawValue)
                Text(store.state.accounts.first { $0.id == entry.accountID }?.name ?? "").font(.caption).foregroundStyle(.secondary)
                if !entry.note.isEmpty { Text(entry.note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Text(entry.date, style: .date).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 1) { Text(entry.kind == .expense ? "−" : entry.kind == .income ? "+" : ""); MoneyText(amount: entry.amount) }.foregroundStyle(color).font(.subheadline)
        }.padding(.vertical, 4)
    }
}
struct TransactionRows: View {
    var entries: [Entry]
    @State private var limit = 50
    var body: some View {
        if entries.isEmpty { Label("暂无记录", systemImage: "tray").foregroundStyle(.secondary) }
        ForEach(Array(entries.prefix(limit))) { entry in NavigationLink { TransactionDetail(id: entry.id) } label: { EntryRow(entry: entry) } }
        if entries.count > limit { Button("加载更多（剩余\(entries.count - limit)笔）") { limit += 50 } }
    }
}
struct TransactionDetail: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let id: UUID
    @State private var edit = false
    @State private var confirm = false
    var entry: Entry? { store.state.entries.first { $0.id == id } }
    var body: some View {
        List {
            if let e = entry {
                Section { SummaryCard(title: e.kind.rawValue, amount: e.amount) }
                Section {
                    LabeledContent("分类", value: e.category)
                    LabeledContent("所属账本", value: store.state.books.first { $0.id == e.bookID }?.name ?? "")
                    LabeledContent("资金账户", value: store.state.accounts.first { $0.id == e.accountID }?.name ?? "")
                    if let target = e.targetID { LabeledContent("转入账户", value: store.state.accounts.first { $0.id == target }?.name ?? "") }
                    LabeledContent("发生时间", value: e.date.formatted())
                    LabeledContent("备注", value: e.note.isEmpty ? "无" : e.note)
                    if let created = e.createdAt { LabeledContent("创建时间", value: created.formatted()) }
                    if let updated = e.updatedAt { LabeledContent("修改时间", value: updated.formatted()) }
                }
                Button("编辑记录") { edit = true }
                Button("删除记录", role: .destructive) { confirm = true }
            }
        }.navigationTitle("交易详情").sheet(isPresented: $edit) { if let entry { EntryEditor(existing: entry) } }
        .confirmationDialog("删除交易并重新计算账户余额？借贷本金有关联还款时不能直接删除。", isPresented: $confirm, titleVisibility: .visible) { Button("删除", role: .destructive) { Task { if let entry, await store.perform({ try BookkeepingService.remove(entry, from: &$0) }) { dismiss() } } } }
    }
}
struct HomeView: View {
    @EnvironmentObject var store: Store
    @State private var month = Date()
    @State private var search = ""
    @State private var filtering = false
    @State private var account: UUID?
    @State private var kind: EntryKind?
    @State private var category: String?
    @State private var dayOnly = false
    @State private var quick: String?
    @State private var limit = 50
    var interval: DateInterval { Calendar.current.dateInterval(of: dayOnly ? .day : .month, for: month)! }
    var baseRows: [Entry] { store.entries(book: store.bookID, interval: interval) }
    var rows: [Entry] { baseRows.filter { e in
        (account == nil || e.accountID == account || e.targetID == account) && (kind == nil || kind == e.kind) && (category == nil || category == e.category) && (search.isEmpty || (e.note + e.category + e.kind.rawValue + (store.state.accounts.first { $0.id == e.accountID }?.name ?? "")).localizedCaseInsensitiveContains(search))
    } }
    var income: Int64 { baseRows.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount } }
    var expense: Int64 { baseRows.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount } }
    var body: some View {
        List {
            Section {
                BookPicker()
                HStack {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("上个月")
                    DatePicker(dayOnly ? "日期" : "月份", selection: $month, displayedComponents: .date)
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("下个月")
                }
                HStack { SummaryCard(title: "收入", amount: income); SummaryCard(title: "支出", amount: expense) }
                HStack { Text("期间结余"); Spacer(); MoneyText(amount: income - expense); PrivacyButton() }
            }.listRowSeparator(.hidden)
            Section("快速记账") {
                HStack { ForEach(["餐饮", "交通", "购物", "娱乐"], id: \.self) { item in Button { quick = item } label: { VStack(spacing: 8) { Image(systemName: categoryIcon(item)).font(.title2); Text(item).font(.caption) }.frame(maxWidth: .infinity).frame(minHeight: 56) }.buttonStyle(.plain).foregroundStyle(Color.brand) } }
            }
            Section("本月预算") {
                if let budget = store.state.budgets.first(where: { $0.bookID == store.bookID && $0.month == LedgerState.month(month) }) {
                    let spent = store.entries(book: store.bookID, interval: Calendar.current.dateInterval(of: .month, for: month)).filter { $0.kind == .expense }.reduce(Int64(0)) { $0 + $1.amount }
                    HStack { Text("总预算"); Spacer(); MoneyText(amount: budget.amount) }
                    ProgressView(value: min(Double(spent) / Double(budget.amount), 1))
                    HStack { Text(spent > budget.amount ? "已超支" : "剩余"); Spacer(); MoneyText(amount: abs(budget.amount - spent)) }.foregroundStyle(spent > budget.amount ? Color.expense : .secondary)
                } else if let id = store.bookID { NavigationLink("设置月度预算") { BookDetail(id: id) } }
                else { Text("选择一个账本后设置预算").foregroundStyle(.secondary) }
            }
            Section("账单 · \(rows.count) 笔") {
                let groups = Dictionary(grouping: Array(rows.prefix(limit))) { Calendar.current.startOfDay(for: $0.date) }
                if rows.isEmpty { Button("记录第一笔收支", systemImage: "plus.circle") { quick = "餐饮" } }
                ForEach(groups.keys.sorted(by: >), id: \.self) { day in
                    Text(day.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                    ForEach(groups[day] ?? []) { e in NavigationLink { TransactionDetail(id: e.id) } label: { EntryRow(entry: e) } }
                }
                if rows.count > limit { Button("加载更多") { limit += 50 } }
            }
        }.navigationTitle("轻松记账").searchable(text: $search, prompt: "搜索分类、类型、账户、备注")
        .toolbar { Button { filtering.toggle() } label: { Image(systemName: "line.3.horizontal.decrease.circle") }.accessibilityLabel("筛选账单"); NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }.accessibilityLabel("设置") }
        .sheet(isPresented: $filtering) { NavigationStack { Form {
            Toggle("只查看选中日期", isOn: $dayOnly)
            Picker("类型", selection: $kind) { Text("全部").tag(EntryKind?.none); ForEach(EntryKind.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) } }
            Picker("账户", selection: $account) { Text("全部").tag(UUID?.none); ForEach(store.state.accounts) { Text($0.name).tag(Optional($0.id)) } }
            Picker("分类", selection: $category) { Text("全部").tag(String?.none); ForEach(store.state.categories, id: \.self) { Text($0).tag(Optional($0)) } }
            Button("重置") { dayOnly = false; kind = nil; account = nil; category = nil }
        }.navigationTitle("账单筛选").toolbar { Button("完成") { filtering = false } } } }
        .sheet(isPresented: Binding(get: { quick != nil }, set: { if !$0 { quick = nil } })) { EntryEditor(initialCategory: quick ?? "餐饮") }
    }
    func shift(_ direction: Int) { month = Calendar.current.date(byAdding: dayOnly ? .day : .month, value: direction, to: month) ?? month }
}
struct ReportsView: View {
    @EnvironmentObject var store: Store
    @State private var date = Date()
    @State private var period = 1
    @State private var account: UUID?
    @State private var kind = EntryKind.expense
    @AppStorage("hideAmounts") private var hideAmounts = false
    var interval: DateInterval { Calendar.current.dateInterval(of: period == 0 ? .weekOfYear : period == 1 ? .month : .year, for: date)! }
    var entries: [Entry] { store.entries(book: store.bookID, interval: interval, account: account) }
    var categories: [(name: String, amount: Int64)] { Dictionary(grouping: entries.filter { $0.kind == kind }, by: \.category).map { (name: $0.key, amount: $0.value.reduce(0) { $0 + $1.amount }) }.sorted { $0.amount > $1.amount } }
    var body: some View {
        List {
            Section {
                BookPicker()
                Picker("账户", selection: $account) { Text("全部账户").tag(UUID?.none); ForEach(store.state.accounts) { Text($0.name).tag(Optional($0.id)) } }
                Picker("周期", selection: $period) { Text("周").tag(0); Text("月").tag(1); Text("年").tag(2) }.pickerStyle(.segmented)
                HStack { Button { shift(-1) } label: { Image(systemName: "chevron.left") }; DatePicker("统计日期", selection: $date, displayedComponents: .date); Button { shift(1) } label: { Image(systemName: "chevron.right") } }
            }
            Section {
                let expense = entries.filter { $0.kind == .expense }.reduce(Int64(0)) { $0 + $1.amount }
                let income = entries.filter { $0.kind == .income }.reduce(Int64(0)) { $0 + $1.amount }
                HStack { SummaryCard(title: "支出", amount: expense); SummaryCard(title: "收入", amount: income) }
                SummaryCard(title: "结余", amount: income - expense)
            }
            if !hideAmounts {
                Section("收支趋势") {
                    if entries.contains(where: { $0.kind == .expense || $0.kind == .income }) { trend.frame(height: 200) }
                    else { Text("暂无收支数据").foregroundStyle(.secondary) }
                    NavigationLink("查看期间明细") { List { TransactionRows(entries: entries) }.navigationTitle("期间交易") }
                }
            }
            Section("分类占比与排行") {
                Picker("统计类型", selection: $kind) { Text("支出").tag(EntryKind.expense); Text("收入").tag(EntryKind.income) }.pickerStyle(.segmented)
                if categories.isEmpty { Text("暂无数据").foregroundStyle(.secondary) }
                if !hideAmounts && !categories.isEmpty {
                    Chart(categories, id: \.name) { item in SectorMark(angle: .value("金额", Double(item.amount)), innerRadius: .ratio(0.65)).foregroundStyle(by: .value("分类", item.name)) }.frame(height: 220)
                }
                ForEach(categories, id: \.name) { item in
                    NavigationLink { List { TransactionRows(entries: entries.filter { $0.kind == kind && $0.category == item.name }) }.navigationTitle(item.name) } label: {
                        HStack { Text(item.name); Spacer(); MoneyText(amount: item.amount); if !hideAmounts { let total = categories.reduce(Int64(0)) { $0 + $1.amount }; Text(String(format: "%.1f%%", Double(item.amount) / Double(max(1, total)) * 100)).font(.caption).foregroundStyle(.secondary) } }
                    }
                }
            }
        }.navigationTitle("收支报表")
    }
    var trend: some View {
        Chart {
            ForEach([EntryKind.expense, .income], id: \.self) { kind in
                ForEach(0..<(period == 2 ? 12 : period == 0 ? 7 : Calendar.current.range(of: .day, in: .month, for: date)!.count), id: \.self) { offset in
                    let start = Calendar.current.date(byAdding: period == 2 ? .month : .day, value: offset, to: interval.start)!
                    let end = Calendar.current.date(byAdding: period == 2 ? .month : .day, value: 1, to: start)!
                    let total = entries.filter { $0.kind == kind && $0.date >= start && $0.date < end }.reduce(Int64(0)) { $0 + $1.amount }
                    LineMark(x: .value("日期", start), y: .value("金额", Double(total) / 100)).foregroundStyle(by: .value("类型", kind.rawValue))
                }
            }
        }.chartForegroundStyleScale([EntryKind.expense.rawValue: Color.expense, EntryKind.income.rawValue: Color.income])
    }
    func shift(_ direction: Int) { date = Calendar.current.date(byAdding: period == 0 ? .weekOfYear : period == 1 ? .month : .year, value: direction, to: date) ?? date }
}

#Preview("首页 · 示例数据") { NavigationStack { HomeView() }.environmentObject(Store.preview) }
