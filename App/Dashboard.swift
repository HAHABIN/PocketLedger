import SwiftUI
import Charts
import LedgerCore

struct MoneyText: View {
    var amount: Int64
    var body: some View { Text(Money.format(amount)).monospacedDigit() }
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
            .frame(maxWidth: .infinity, alignment: .leading).padding().background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }
}
struct EntryRow: View {
    @EnvironmentObject var store: Store
    var entry: Entry
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind == .expense ? "arrow.up.right" : "arrow.down.left").foregroundStyle(.teal).frame(width: 36, height: 36).background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.category + " · " + entry.kind.rawValue)
                Text(entry.note.isEmpty ? (store.state.accounts.first { $0.id == entry.accountID }?.name ?? "") : entry.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(entry.date, style: .date).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(); MoneyText(amount: entry.amount).foregroundStyle(entry.kind == .expense ? Color.primary : Color.teal)
        }.padding(.vertical, 4)
    }
}
struct HomeView: View {
    @EnvironmentObject var store: Store
    @State private var month = Date()
    @State private var search = ""
    @State private var editing: Entry?
    @State private var deleting: Entry?
    var interval: DateInterval { Calendar.current.dateInterval(of: .month, for: month)! }
    var rows: [Entry] { store.entries(book: store.bookID, interval: interval).filter { search.isEmpty || ($0.note + $0.category + $0.kind.rawValue).localizedCaseInsensitiveContains(search) } }
    var income: Int64 { store.entries(book: store.bookID, interval: interval).filter { $0.kind == .income }.reduce(0) { $0 + $1.amount } }
    var expense: Int64 { store.entries(book: store.bookID, interval: interval).filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount } }
    var body: some View {
        List {
            Section { BookPicker(); DatePicker("统计月份", selection: $month, displayedComponents: .date) }
            Section {
                HStack { SummaryCard(title: "本月支出", amount: expense); SummaryCard(title: "本月收入", amount: income) }
                HStack { Text("本月结余"); Spacer(); MoneyText(amount: income - expense) }
                if let budget = store.state.budgets.first(where: { $0.bookID == store.bookID && $0.month == LedgerState.month(month) }) {
                    VStack(alignment: .leading) { HStack { Text("月度预算"); Spacer(); MoneyText(amount: budget.amount) }; ProgressView(value: min(Double(expense) / Double(budget.amount), 1)); Text(expense > budget.amount ? "已超支 \(Money.format(expense - budget.amount))" : "剩余 \(Money.format(budget.amount - expense))").font(.caption).foregroundStyle(.secondary) }
                }
            }.listRowSeparator(.hidden)
            Section("账单 · \(rows.count) 笔") {
                if rows.isEmpty { Text("还没有账单，点击底部「记一笔」开始记录").foregroundStyle(.secondary) }
                ForEach(rows) { entry in
                    Button { editing = entry } label: { EntryRow(entry: entry).foregroundStyle(.primary) }
                        .swipeActions { Button("删除", role: .destructive) { deleting = entry } }
                }
            }
        }.navigationTitle("轻松记账").searchable(text: $search, prompt: "搜索分类、类型、备注")
        .toolbar { NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }.accessibilityLabel("设置") }
        .sheet(item: $editing) { EntryEditor(existing: $0) }
        .confirmationDialog("删除这笔交易？账户余额将重新计算。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) { Button("删除", role: .destructive) { if let deleting { store.remove(deleting) }; deleting = nil } }
    }
}
struct ReportsView: View {
    @EnvironmentObject var store: Store
    @State private var date = Date()
    @State private var period = 1
    @State private var account: UUID?
    var interval: DateInterval { Calendar.current.dateInterval(of: period == 0 ? .weekOfYear : period == 1 ? .month : .year, for: date)! }
    var entries: [Entry] { store.entries(book: store.bookID, interval: interval, account: account) }
    var categories: [(name: String, amount: Int64)] {
        Dictionary(grouping: entries.filter { $0.kind == .expense }, by: \.category).map { (name: $0.key, amount: $0.value.reduce(0) { $0 + $1.amount }) }.sorted { $0.amount > $1.amount }
    }
    var body: some View {
        List {
            Section {
                BookPicker()
                Picker("账户", selection: $account) { Text("全部账户").tag(UUID?.none); ForEach(store.state.accounts) { Text($0.name).tag(Optional($0.id)) } }
                Picker("周期", selection: $period) { Text("周").tag(0); Text("月").tag(1); Text("年").tag(2) }.pickerStyle(.segmented)
                DatePicker("统计日期", selection: $date, displayedComponents: .date)
            }
            Section {
                SummaryCard(title: "期间支出", amount: entries.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amount })
                SummaryCard(title: "期间收入", amount: entries.filter { $0.kind == .income }.reduce(0) { $0 + $1.amount })
            }
            Section("收支趋势") {
                if entries.contains(where: { $0.kind == .expense || $0.kind == .income }) {
                    Chart {
                        ForEach([EntryKind.expense, .income], id: \.self) { kind in
                            ForEach(0..<(period == 2 ? 12 : period == 0 ? 7 : Calendar.current.range(of: .day, in: .month, for: date)!.count), id: \.self) { offset in
                                let start = Calendar.current.date(byAdding: period == 2 ? .month : .day, value: offset, to: interval.start)!
                                let end = Calendar.current.date(byAdding: period == 2 ? .month : .day, value: 1, to: start)!
                                let total = entries.filter { $0.kind == kind && $0.date >= start && $0.date < end }.reduce(Int64(0)) { $0 + $1.amount }
                                LineMark(x: .value("日期", start), y: .value("金额", Double(total) / 100)).foregroundStyle(by: .value("类型", kind.rawValue))
                            }
                        }
                    }.frame(height: 200)
                } else { Text("暂无收支数据").foregroundStyle(.secondary) }
            }
            Section("支出分类与占比") {
                if categories.isEmpty { Text("暂无支出") }
                ForEach(categories, id: \.name) { item in
                    let total = categories.reduce(Int64(0)) { $0 + $1.amount }
                    VStack { HStack { Text(item.name); Spacer(); MoneyText(amount: item.amount); Text(total == 0 ? "0%" : String(format: "%.1f%%", Double(item.amount) / Double(total) * 100)).font(.caption) }; ProgressView(value: Double(item.amount), total: Double(max(1, total))) }
                }
            }
        }.navigationTitle("收支报表")
    }
}
