import SwiftUI
import LedgerCore
import LocalAuthentication

extension Color {
    static let brand = Color(red: 1, green: 0.392, blue: 0.357)
    static let income = Color(red: 0.086, green: 0.655, blue: 0.482)
    static let expense = Color(red: 0.89, green: 0.294, blue: 0.314)
}
@main struct PocketLedgerApp: App {
    @State private var store: Store?
    @State private var failure: String?
    @State private var receivedBackupURL: URL?
    var body: some Scene {
        WindowGroup {
            Group {
                if let store {
                    RootView().environmentObject(store).task(id: receivedBackupURL) {
                        if let url = receivedBackupURL { await store.stageBackup(url); receivedBackupURL = nil }
                    }
                }
                else if let failure { VStack(spacing: 20) { Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle); Text("无法打开本地数据库").font(.headline); Text(failure); Button("重试", action: open) }.padding() }
                else { ProgressView("打开账本…").onAppear(perform: open) }
            }.tint(.brand).onOpenURL { url in
                // 包括冷启动收到的文件，等数据库就绪后再校验，绝不直接覆盖。
                receivedBackupURL = url
            }
        }
    }
    @MainActor private func open() {
        #if DEBUG
        // 自动化截图仅使用内存样例，不写入用户数据库。
        if ProcessInfo.processInfo.arguments.contains("--界面预览") { store = Store.preview; return }
        #endif
        Task { do { store = try await Store.open(); failure = nil } catch { failure = error.localizedDescription } }
    }
}
struct RootView: View {
    @EnvironmentObject var store: Store
    @Environment(\.scenePhase) var phase
    @AppStorage("appLock") private var appLock = false
    @AppStorage("onboardingComplete") private var onboarded = false
    @State private var unlocked = false
    @State private var authenticating = false
    @State private var tab = 0
    @State private var add = false
    var body: some View {
        ZStack {
            Group {
                switch tab {
                case 1: NavigationStack { ReportsView() }
                case 2: NavigationStack { AssetsView() }
                case 3: NavigationStack { BooksView() }
                case 4: NavigationStack { SettingsView() }
                default: NavigationStack { HomeView() }
                }
            }.safeAreaInset(edge: .top, spacing: 0) {
                if store.isDemonstration { Text("演示数据 · 全部虚构").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 4).background(Color.brand.opacity(0.07)) }
            }.safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .sheet(isPresented: $add) { EntryEditor() }
            .sheet(isPresented: Binding(get: { !onboarded && !ProcessInfo.processInfo.arguments.contains("--界面预览") }, set: { if !$0 { onboarded = true } })) { onboarding }
            .alert("操作提示", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("知道了") { store.error = nil } } message: { Text(store.error ?? "") }
            if let backup = store.pendingBackup, (!appLock || unlocked), phase == .active, onboarded || store.isDemonstration {
                // 恢复预览由根界面统一呈现；已有表单关闭后才会露出，不丢弃未保存输入。
                NavigationStack { BackupRestoreView(backup: backup) }.background(Color(uiColor: .systemBackground))
            }
            if store.readingBackup { ProgressView("正在校验备份…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
            if store.saving { Color.black.opacity(0.1).ignoresSafeArea(); ProgressView("正在保存…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
            if (appLock && !unlocked) || phase != .active {
                Color(uiColor: .systemBackground).ignoresSafeArea()
                VStack(spacing: 24) {
                    Image(systemName: "lock.shield").font(.system(size: 64)).foregroundStyle(Color.brand)
                    Text("轻松记账").font(.title.bold())
                    if phase == .active { Button("解锁账本", action: unlock).buttonStyle(.borderedProminent).disabled(authenticating) }
                }
            }
        }.onAppear {
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--预览报表") { tab = 1 }
            if arguments.contains("--预览资产") { tab = 2 }
            if arguments.contains("--预览账本") { tab = 3 }
            if arguments.contains("--预览记账") { add = true }
            if arguments.contains("--预览数据管理") { tab = 4 }
            if arguments.contains("--备份文件自检") {
                Task {
                    let result = await store.checkBackupFileFlow()
                    let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try? result.write(to: directory.appendingPathComponent("backup-self-check.txt"), atomically: true, encoding: .utf8)
                }
            }
            #endif
        }.onChange(of: phase) { _, value in if value == .background { unlocked = false } }
        .onChange(of: appLock) { unlocked = false }
    }
    var bottomBar: some View {
        HStack {
            tabButton("首页", "house", 0); tabButton("报表", "chart.bar.xaxis", 1)
            Button { add = true } label: { Image(systemName: "plus").font(.title2.bold()).foregroundStyle(.white).frame(width: 56, height: 56).background(Color.brand.gradient, in: Circle()) }.accessibilityLabel("记一笔").padding(.horizontal, 8)
            tabButton("资产", "creditcard", 2); tabButton("账本", "books.vertical", 3)
        }.padding(.horizontal, 10).padding(.vertical, 8).background(Color(uiColor: .systemBackground)).overlay(alignment: .top) { Divider().opacity(0.5) }
    }
    func tabButton(_ title: String, _ icon: String, _ value: Int) -> some View {
        Button { tab = value } label: { VStack(spacing: 5) { Image(systemName: icon).font(.title3); Text(title).font(.caption) }.frame(maxWidth: .infinity).frame(minHeight: 48).foregroundStyle(tab == value ? Color.brand : Color.secondary) }.accessibilityAddTraits(tab == value ? .isSelected : [])
    }
    var onboarding: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "book.closed.fill").font(.system(size: 60)).foregroundStyle(Color.brand)
            Text("把每一笔，记在自己手里").font(.largeTitle.bold())
            Text("已为你创建日常账本和零余额现金账户。你可以在资产页添加微信、支付宝和银行卡，并填写真实余额。")
            Label("无需注册，所有数据仅保存在本机", systemImage: "iphone")
            Label("请定期导出备份；卸载或换机可能丢失数据", systemImage: "externaldrive")
            Spacer()
            Button("开始记账") { onboarded = true }.buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
        }.padding(28).interactiveDismissDisabled()
    }
    private func unlock() {
        authenticating = true
        LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "查看你的本地账本") { success, error in
            Task { @MainActor in authenticating = false; unlocked = success; if !success { store.error = error?.localizedDescription ?? "解锁失败" } }
        }
    }
}
