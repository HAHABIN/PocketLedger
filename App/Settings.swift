import SwiftUI
import UniformTypeIdentifiers
import UIKit
import LedgerCore

extension UTType {
    static let pocketLedgerBackup = UTType(exportedAs: "com.localbookkeeping.backup", conformingTo: .json)
}
struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pocketLedgerBackup, .json, .commaSeparatedText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct SharedExport: Identifiable {
    let id = UUID()
    let url: URL
    let isBackup: Bool
}
struct SystemShareSheet: UIViewControllerRepresentable {
    let url: URL
    let completion: (Bool, Error?) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, error in
            Task { @MainActor in completion(completed, error) }
        }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
struct SettingsView: View {
    @EnvironmentObject var store: Store
    @AppStorage("appLock") private var lock = false
    @AppStorage("hideAmounts") private var hideAmounts = false
    @AppStorage("lastExport") private var lastExport = ""
    @State private var exporting = false
    @State private var importing = false
    @State private var preparing = false
    @State private var document = ExportDocument(data: Data())
    @State private var type = UTType.pocketLedgerBackup
    @State private var exportWarning = false
    @State private var exportJSON = true
    @State private var preparedIsBackup = true
    @State private var sharedExport: SharedExport?
    @State private var temporaryShareDirectory: URL?
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
            if store.isDemonstration { Label("演示模式 · 账户和金额均为虚构", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
            Section("数据管理") {
                Text(lastExport.isEmpty ? "尚未完成过完整备份导出" : "上次完成导出：" + lastExport).font(.caption).foregroundStyle(.secondary)
                Button("完整备份 · 保存或分享") { exportJSON = true; exportWarning = true }.disabled(preparing)
                Button("选择文件恢复备份") { importing = true }.disabled(store.readingBackup)
                Text("也可在「文件」中打开 .pocketledger 备份，或通过共享菜单选择轻松记账。旧 JSON 备份仍可导入。").font(.caption).foregroundStyle(.secondary)
                Button("找回上次恢复前的数据") { Task { await store.attemptAsync {
                    guard store.pendingBackup == nil else { throw LedgerError.invalid("请先完成或取消当前恢复预览") }
                    let data = try store.previousBackup()
                    store.pendingBackup = try await Task.detached { try BackupService.preview(data) }.value
                } } }
                Button("检查数据完整性") { store.attempt { try store.state.validate(); message = "数据检查通过" } }
            }
            Section("导出账单 · CSV") {
                DatePicker("开始日期", selection: $start, displayedComponents: .date)
                DatePicker("结束日期", selection: $end, displayedComponents: .date)
                Picker("账本", selection: $book) { Text("全部账本").tag(UUID?.none); ForEach(store.state.books) { Text($0.name).tag(Optional($0.id)) } }
                Picker("账户", selection: $account) { Text("全部账户").tag(UUID?.none); ForEach(store.state.accounts) { Text($0.name).tag(Optional($0.id)) } }
                Button("导出或分享筛选账单") { exportJSON = false; exportWarning = true }.disabled(preparing)
                Text("CSV 供 Excel / Numbers 查阅，不能用于恢复；换机请导出完整备份。").font(.caption).foregroundStyle(.secondary)
            }
            if preparing { ProgressView("正在生成文件…") }
            Section("个性化") {
                NavigationLink("分类管理") { CategoriesView() }
                NavigationLink("预算管理") { BooksView() }
                Toggle("隐藏金额", isOn: $hideAmounts)
                Toggle("设备认证解锁", isOn: $lock)
            }
            Section("隐私") { Text("财务数据仅保存在本机。备份和 CSV 是明文，可能包含账户、借贷对象和备注。你可自行保存至 iCloud Drive 或通过 AirDrop 传送，应用不自动上传或同步。").font(.caption) }
            Section("危险操作") { Button("清空全部数据", role: .destructive) { clear = true } }
            Section("关于") {
                Text("轻松记账 · 1.0.0")
                Text("人民币 · 数据格式 v1 · iOS 17+")
                Text("SwiftUI / Swift Charts · GRDB（MIT 许可证）")
            }
        }.navigationTitle("设置与数据")
        .confirmationDialog("文件可能包含账户信息和备注，请妥善保存。", isPresented: $exportWarning, titleVisibility: .visible) {
            Button("保存到文件") { Task { await export(share: false) } }
            Button("分享 / AirDrop") { Task { await export(share: true) } }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: type, defaultFilename: filename) { result in
            switch result {
            case .success:
                if preparedIsBackup { lastExport = Date().formatted() }
                message = preparedIsBackup ? "完整备份已导出，请保管好文件。此时间不保证外部文件永久可用。" : "CSV 已导出"
            case .failure(let error): if !isCancellation(error) { store.error = error.localizedDescription }
            }
        }
        .sheet(item: $sharedExport, onDismiss: cleanTemporaryShare) { item in
            SystemShareSheet(url: item.url) { completed, error in
                if let error { store.error = error.localizedDescription }
                else if completed {
                    if item.isBackup { lastExport = Date().formatted() }
                    message = "系统分享操作已完成，请确认接收或保存位置。"
                }
                // 取消分享不更新备份时间，也不报告成功。
                sharedExport = nil
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pocketLedgerBackup, .json]) { result in
            switch result {
            case .success(let url): Task { await store.stageBackup(url) }
            case .failure(let error): if !isCancellation(error) { store.error = error.localizedDescription }
            }
        }
        .sheet(isPresented: $clear) { NavigationStack { Form {
            Text("此操作删除全部账本、账户、交易、借贷和上次恢复点，重建空白日常账本。请先导出完整备份。无法撤销。")
            TextField("输入「清空全部数据」", text: $clearWord)
            Button("继续清空…", role: .destructive) { clearConfirm = true }.disabled(clearWord != "清空全部数据")
        }.navigationTitle("清空全部数据").toolbar { Button("取消") { clear = false; clearWord = "" } }
        .confirmationDialog("确定永久清空？", isPresented: $clearConfirm, titleVisibility: .visible) { Button("永久清空", role: .destructive) { Task { await store.attemptAsync { try await store.clearAll(); clear = false; clearWord = ""; message = "数据已清空" } } } }
        } }
        .alert("完成", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("知道了") { message = nil } } message: { Text(message ?? "") }
    }
    var filename: String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmmss"; return "轻松记账_\(f.string(from: Date()))_v1" }
    func isCancellation(_ error: Error) -> Bool { let e = error as NSError; return e.domain == NSCocoaErrorDomain && e.code == NSUserCancelledError }
    func export(share: Bool) async {
        guard !preparing else { return }
        preparing = true; defer { preparing = false }
        do {
            var state = store.state
            if state.settings == nil { state.settings = [:] }
            state.settings?["currentBookID"] = store.bookID?.uuidString ?? "all"
            state.settings?["hideAmounts"] = String(hideAmounts); state.settings?["appLock"] = String(lock)
            let isBackup = exportJSON
            guard isBackup || start <= end else { throw LedgerError.invalid("开始日期不能晚于结束日期") }
            let interval = DateInterval(start: Calendar.current.startOfDay(for: start), end: max(Calendar.current.startOfDay(for: start), Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: end))!))
            let rows = isBackup ? [] : store.entries(book: book, interval: interval, account: account)
            let snapshot = state
            let data = try await Task.detached(priority: .userInitiated) { isBackup ? try BackupService.export(snapshot) : BackupService.csv(snapshot, entries: rows) }.value
            preparedIsBackup = isBackup
            if share {
                let name = filename + (isBackup ? ".pocketledger" : ".csv")
                let url = try await Task.detached {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PocketLedgerExports", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = directory.appendingPathComponent(name)
                    try data.write(to: url, options: [.atomic, .completeFileProtection])
                    return url
                }.value
                temporaryShareDirectory = url.deletingLastPathComponent()
                sharedExport = SharedExport(url: url, isBackup: isBackup)
            } else {
                document = ExportDocument(data: data); type = isBackup ? .pocketLedgerBackup : .commaSeparatedText; exporting = true
            }
        } catch { store.error = error.localizedDescription }
    }
    func cleanTemporaryShare() {
        guard let directory = temporaryShareDirectory else { return }
        temporaryShareDirectory = nil
        Task.detached { try? FileManager.default.removeItem(at: directory) }
    }
}
struct BackupRestoreView: View {
    @EnvironmentObject var store: Store
    let backup: Backup
    @AppStorage("appLock") private var lock = false
    @AppStorage("hideAmounts") private var hideAmounts = false
    @State private var confirm = false
    var body: some View {
        Form {
            Section("已校验的完整备份") {
                LabeledContent("导出时间", value: backup.exportedAt.formatted())
                LabeledContent("格式版本", value: "\(backup.schemaVersion)")
                LabeledContent("账本", value: "\(backup.data.books.count)")
                LabeledContent("账户", value: "\(backup.data.accounts.count)")
                LabeledContent("交易", value: "\(backup.data.entries.count)")
                LabeledContent("借贷", value: "\(backup.data.loans.count)")
            }
            Section {
                Text("将替换当前全部数据。确认前不会修改账本；执行前会保存本机恢复点，失败时保留原数据。").foregroundStyle(Color.expense)
                Button("覆盖恢复…", role: .destructive) { confirm = true }.disabled(store.saving)
            }
        }.navigationTitle("恢复预览").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("取消") { store.pendingBackup = nil }.disabled(store.saving) }
        .confirmationDialog("确认替换全部账本、账户和交易？", isPresented: $confirm, titleVisibility: .visible) {
            Button("确认覆盖", role: .destructive) { Task { await store.attemptAsync {
                try await store.restore(backup.data, mode: .replace)
                if let hidden = backup.data.settings?["hideAmounts"] { hideAmounts = hidden == "true" }
                if let locked = backup.data.settings?["appLock"] { lock = locked == "true" }
                store.pendingBackup = nil
            } } }
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
                .onMove { offsets, destination in Task { await store.perform { $0.categories.move(fromOffsets: offsets, toOffset: destination) } } }
                .onDelete { offsets in Task { await store.perform { s in
                    let names = offsets.map { s.categories[$0] }
                    if s.archivedCategories == nil { s.archivedCategories = [] }
                    for name in names where s.entries.contains(where: { $0.category == name && ($0.kind == .expense || $0.kind == .income) }) { s.archivedCategories?.append(name) }
                    s.categories.remove(atOffsets: offsets)
                } } }
            }
            if let archived = store.state.archivedCategories, !archived.isEmpty {
                Section("已停用 · 保留历史名称") {
                    ForEach(archived, id: \.self) { item in Button("重新启用 " + item) { Task { await store.perform { s in s.archivedCategories?.removeAll { $0 == item }; s.categories.append(item) } } } }
                }
            }
            Section("新增分类") { TextField("分类名称", text: $name); Button("添加") { Task { if await store.perform({ $0.categories.append(name.trimmingCharacters(in: .whitespacesAndNewlines)) }) { name = "" } } } }
        }.navigationTitle("分类管理").toolbar { EditButton() }
    }
}
