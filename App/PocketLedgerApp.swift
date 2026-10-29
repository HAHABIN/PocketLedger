import SwiftUI
import LedgerCore
import LocalAuthentication

@main struct PocketLedgerApp: App {
    @State private var store: Store?
    @State private var failure: String?
    var body: some Scene {
        WindowGroup {
            Group {
                if let store { RootView().environmentObject(store) }
                else if let failure {
                    VStack(spacing: 20) { Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle); Text("无法打开本地数据库").font(.headline); Text(failure); Button("重试", action: open) }.padding()
                } else { ProgressView("打开账本…").onAppear(perform: open) }
            }.tint(.teal)
        }
    }
    private func open() { do { store = try Store(); failure = nil } catch { failure = error.localizedDescription } }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @Environment(\.scenePhase) var phase
    @AppStorage("appLock") private var appLock = false
    @State private var unlocked = false
    @State private var authenticating = false
    @State private var tab = 0
    @State private var add = false
    var body: some View {
        ZStack {
            TabView(selection: $tab) {
                NavigationStack { HomeView() }.tabItem { Label("首页", systemImage: "house") }.tag(0)
                NavigationStack { ReportsView() }.tabItem { Label("报表", systemImage: "chart.bar.xaxis") }.tag(1)
                Color.clear.tabItem { Label("记一笔", systemImage: "plus.circle.fill") }.tag(2)
                NavigationStack { AssetsView() }.tabItem { Label("资产", systemImage: "creditcard") }.tag(3)
                NavigationStack { BooksView() }.tabItem { Label("账本", systemImage: "books.vertical") }.tag(4)
            }
            .onChange(of: tab) { value in if value == 2 { tab = 0; add = true } }
            .sheet(isPresented: $add) { EntryEditor() }
            .alert("操作提示", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("知道了") { store.error = nil } } message: { Text(store.error ?? "") }
            if (appLock && !unlocked) || phase != .active {
                Color(uiColor: .systemBackground).ignoresSafeArea()
                VStack(spacing: 24) {
                    Image(systemName: "lock.shield").font(.system(size: 64)).foregroundStyle(.teal)
                    Text("轻松记账").font(.title.bold())
                    if phase == .active { Button("解锁账本", action: unlock).buttonStyle(.borderedProminent).disabled(authenticating) }
                }
            }
        }
        .onChange(of: phase) { value in if value == .background { unlocked = false } }
        .onChange(of: appLock) { _ in unlocked = false }
    }
    private func unlock() {
        authenticating = true
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "查看你的本地账本") { success, error in
            Task { @MainActor in authenticating = false; unlocked = success; if !success { store.error = error?.localizedDescription ?? "解锁失败" } }
        }
    }
}
