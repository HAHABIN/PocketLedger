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
    @State private var exporting = false
    @State private var importing = false
    @State private var document = ExportDocument(data: Data())
    @State private var type = UTType.json
    @State private var incoming: LedgerState?
    @State private var confirm = false
    @State private var category = ""
    @State private var message: String?
    var body: some View {
        Form {
            Section("隐私与安全") { Toggle("设备认证解锁", isOn: $lock); Text("不注册、不登录，财务数据保存在本机。备份是明文文件，请选择你信任的保存位置。").font(.caption).foregroundStyle(.secondary) }
            Section("数据管理") {
                Button("完整备份 · JSON") { store.attempt { document = ExportDocument(data: try BackupService.export(store.state)); type = .json; exporting = true } }
                Button("从 JSON 恢复") { importing = true }
                Button("导出全部账单 · CSV") { document = ExportDocument(data: BackupService.csv(store.state)); type = .commaSeparatedText; exporting = true }
                Button("检查数据完整性") { store.attempt { try store.state.validate(); message = "数据检查通过" } }
                Button("找回上次恢复前的数据") { store.attempt { incoming = try BackupService.decode(store.previousBackup()); confirm = true } }
            }
            Section("分类管理") {
                ForEach(store.state.categories, id: \.self) { Text($0) }
                    .onDelete { offsets in store.perform { s in s.categories.remove(atOffsets: offsets) } }
                TextField("新增分类", text: $category)
                Button("添加分类") { if store.perform({ $0.categories.append(category) }) { category = "" } }
            }
            Section("关于") { Text("轻松记账 · 1.0"); Text("单币种人民币 · 完全离线"); Text("转账、借还款及余额调整不计入收支报表。").font(.caption) }
        }.navigationTitle("设置与数据")
        .fileExporter(isPresented: $exporting, document: document, contentType: type, defaultFilename: "PocketLedger-\(LedgerState.month(Date()))") { result in if case .failure(let error) = result { store.error = error.localizedDescription } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            store.attempt {
                let url = try result.get(); let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 50 * 1024 * 1024 else { throw LedgerError.invalid("备份不能超过50MB") }
                incoming = try BackupService.decode(Data(contentsOf: url)); confirm = true
            }
        }
        .confirmationDialog("恢复备份：\(incoming?.entries.count ?? 0)笔交易、\(incoming?.books.count ?? 0)个账本。覆盖将替换全部当前数据；操作前会保存恢复点。", isPresented: $confirm, titleVisibility: .visible) {
            Button("合并（冲突时取消）") { restore(.merge) }
            Button("覆盖全部数据", role: .destructive) { restore(.replace) }
        }
        .alert("完成", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("知道了") { message = nil } } message: { Text(message ?? "") }
    }
    func restore(_ mode: ImportMode) { store.attempt { guard let incoming else { return }; try store.restore(incoming, mode: mode); self.incoming = nil; message = "恢复完成" } }
}
