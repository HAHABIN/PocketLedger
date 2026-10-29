import SwiftUI
import UniformTypeIdentifiers
import LedgerCore

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct SettingsView: View {
    @EnvironmentObject var store: Store
    @AppStorage("appLock") private var lock = false
    @AppStorage("hideAmounts") private var hideAmounts = false
    @AppStorage("lastExport") private var lastExport = ""
    @State private var exporting = false
    @State private var importing = false
    @State private var document = ExportDocument(data: Data())
    @State private var type = UTType.json
    @State private var incoming: Backup?
    @State private var preview = false
    @State private var confirm = false
    @State private var exportWarning = false
    @State private var exportJSON = true
    @State private var clear = false
    @State private var clearWord = ""
    @State private var clearConfirm = false
    @State private var message: String?
    @State private var start = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
    @State private var end = Date()
    @State private var book: UUID?
    @State private var account: UUID?
    var body: some View {
        Form {
            Section("数据管理") {
                Text(lastExport.isEmpty ? "尚未导出过完整备份" : "上次导出：" + lastExport).font(.caption).foregroundStyle(.secondary)
                Button("完整备份 · JSON") { exportJSON = true; exportWarning = true }
                Button("从 JSON 覆盖恢复") { importing = true }
                Button("找回上次恢复前的数据") { store.attempt { incoming = try BackupService.preview(store.previousBackup()); preview = true } }
                Button("检查数据完整性") { store.attempt { try store.state.validate(); message = "数据检查通过" } }
            }
            Section("导出账单 · CSV") {
                DatePicker("开始日期", selection: $start, displayedComponents: .date)
                DatePicker("结束日期", selection: $end, displayedComponents: .date)
                Picker("账本", selection: $book) { Text("全部账本").tag(UUID?.none); ForEach(store.state.books) { Text($0.name).tag(Optional($0.id)) } }
                Picker("账户", selection: $account) { Text("全部账户").tag(UUID?.none); ForEach(store.state.accounts) { Text($0.name).tag(Optional($0.id)) } }
                Button("按以上条件导出 CSV") { exportJSON = false; exportWarning = true }
                Text("CSV 用于查阅，不能恢复数据。完整恢复请使用 JSON 备份。").font(.caption).foregroundStyle(.secondary)
            }
            Section("个性化") {
                NavigationLink("分类管理") { CategoriesView() }
                NavigationLink("预算管理") { BooksView() }
                Toggle("隐藏金额", isOn: $hideAmounts)
                Toggle("设备认证解锁", isOn: $lock)
            }
            Section("隐私") { Text("无需账号，数据仅保存在本机。应用不上传数据，无自动云同步。JSON / CSV 备份均为明文，可能包含账户、借款对象及备注，请妥善保存。").font(.caption) }
            Section("危险操作") { Button("清空全部数据", role: .destructive) { clear = true } }
            Section("关于") {
                Text("轻松记账 · 1.0.0")
                Text("人民币 · 数据格式 v1 · iOS 17+")
                Text("SwiftUI / Swift Charts · GRDB（MIT 许可证）")
                Text("资金账户采用统一有符号余额：负数表示欠款，负债页显示正数欠款。转账、借还本金和校正不计入收支。").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("设置与数据")
        .confirmationDialog("备份文件可能包含账户信息和备注，请妥善保存。", isPresented: $exportWarning, titleVisibility: .visible) { Button("继续导出") { export() } }
        .fileExporter(isPresented: $exporting, document: document, contentType: type, defaultFilename: filename) { result in
            switch result {
            case .success:
                if exportJSON { lastExport = Date().formatted(); message = "备份已导出，请保管好文件；此时间不代表外部文件永久可用。" }
                else { message = "CSV 已导出" }
            case .failure(let error): store.error = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            store.attempt {
                let url = try result.get(); let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 50 * 1024 * 1024 else { throw LedgerError.invalid("备份不能超过50MB") }
                incoming = try BackupService.preview(Data(contentsOf: url)); preview = true
            }
        }
        .sheet(isPresented: $preview) { NavigationStack { Form {
            if let incoming {
                Section("已校验的备份") {
                    LabeledContent("导出时间", value: incoming.exportedAt.formatted())
                    LabeledContent("格式版本", value: "\(incoming.schemaVersion)")
                    LabeledContent("账本", value: "\(incoming.data.books.count)")
                    LabeledContent("账户", value: "\(incoming.data.accounts.count)")
                    LabeledContent("交易", value: "\(incoming.data.entries.count)")
                    LabeledContent("借贷", value: "\(incoming.data.loans.count)")
                }
                Section { Text("将替换当前全部数据。执行前会在本机保存一次恢复点，失败时保留原数据。").foregroundStyle(Color.expense); Button("覆盖恢复…", role: .destructive) { confirm = true } }
            }
        }.navigationTitle("恢复预览").toolbar { Button("取消") { preview = false; incoming = nil } }
        .confirmationDialog("确认用此备份替换全部账本、账户和交易？", isPresented: $confirm, titleVisibility: .visible) { Button("确认覆盖", role: .destructive) { restore() } }
        } }
        .sheet(isPresented: $clear) { NavigationStack { Form {
            Text("此操作删除全部账本、账户、交易、借贷和上次恢复点，重建空白日常账本。请先导出完整备份。无法撤销。")
            TextField("输入「清空全部数据」", text: $clearWord)
            Button("继续清空…", role: .destructive) { clearConfirm = true }.disabled(clearWord != "清空全部数据")
        }.navigationTitle("清空全部数据").toolbar { Button("取消") { clear = false; clearWord = "" } }
        .confirmationDialog("确定永久清空？", isPresented: $clearConfirm, titleVisibility: .visible) { Button("永久清空", role: .destructive) { store.attempt { try store.clearAll(); clear = false; clearWord = ""; message = "数据已清空" } } }
        } }
        .alert("完成", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("知道了") { message = nil } } message: { Text(message ?? "") }
    }
    var filename: String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmmss"; return "轻松记账_\(f.string(from: Date()))_v1" }
    func export() {
        store.attempt {
            if exportJSON {
                var state = store.state
                if state.settings == nil { state.settings = [:] }
                state.settings?["hideAmounts"] = String(hideAmounts); state.settings?["appLock"] = String(lock)
                document = ExportDocument(data: try BackupService.export(state)); type = .json
            } else {
                guard start <= end else { throw LedgerError.invalid("开始日期不能晚于结束日期") }
                let interval = DateInterval(start: Calendar.current.startOfDay(for: start), end: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end))!)
                document = ExportDocument(data: BackupService.csv(store.state, entries: store.entries(book: book, interval: interval, account: account))); type = .commaSeparatedText
            }
            exporting = true
        }
    }
    func restore() {
        store.attempt {
            guard let incoming else { return }; try store.restore(incoming.data, mode: .replace)
            if let hidden = incoming.data.settings?["hideAmounts"] { hideAmounts = hidden == "true" }
            if let locked = incoming.data.settings?["appLock"] { lock = locked == "true" }
            self.incoming = nil; preview = false; message = "恢复完成，所有页面已刷新"
        }
    }
}
struct CategoriesView: View {
    @EnvironmentObject var store: Store
    @State private var name = ""
    var body: some View {
        List {
            Section("启用分类") {
                ForEach(store.state.categories, id: \.self) { Text($0) }
                .onMove { offsets, destination in store.perform { $0.categories.move(fromOffsets: offsets, toOffset: destination) } }
                .onDelete { offsets in store.perform { s in
                    let names = offsets.map { s.categories[$0] }
                    guard !s.entries.contains(where: { names.contains($0.category) && ($0.kind == .expense || $0.kind == .income) }) else { throw LedgerError.invalid("历史交易正在使用此分类，不能删除") }
                    s.categories.remove(atOffsets: offsets)
                } }
            }
            Section("新增分类") { TextField("分类名称", text: $name); Button("添加") { if store.perform({ $0.categories.append(name.trimmingCharacters(in: .whitespacesAndNewlines)) }) { name = "" } } }
        }.navigationTitle("分类管理").toolbar { EditButton() }
    }
}
