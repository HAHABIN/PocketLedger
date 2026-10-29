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
    var body: some Scene {
        WindowGroup {
            Group {
                if let store { RootView().environmentObject(store) }
                else if let failure { VStack(spacing: 20) { Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle); Text("无法打开本地数据库").font(.headline); Text(failure); Button("重试", action: open) }.padding() }
                else { ProgressView("打开账本…").onAppear(perform: open) }
            }.tint(.brand)
        }
    }
    private func open() { Task { do { store = try await Store.open(); failure = nil } catch { failure = error.localizedDescription } } }
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
                default: NavigationStack { HomeView() }
                }
            }.safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .sheet(isPresented: $add) { EntryEditor() }
            .sheet(isPresented: Binding(get: { !onboarded }, set: { if !$0 { onboarded = true } })) { onboarding }
            .alert("操作提示", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("知道了") { store.error = nil } } message: { Text(store.error ?? "") }
            if store.saving { Color.black.opacity(0.1).ignoresSafeArea(); ProgressView("正在保存…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
            if (appLock && !unlocked) || phase != .active {
                Color(uiColor: .systemBackground).ignoresSafeArea()
                VStack(spacing: 24) {
                    Image(systemName: "lock.shield").font(.system(size: 64)).foregroundStyle(Color.brand)
                    Text("轻松记账").font(.title.bold())
                    if phase == .active { Button("解锁账本", action: unlock).buttonStyle(.borderedProminent).disabled(authenticating) }
                }
            }
        }.onChange(of: phase) { _, value in if value == .background { unlocked = false } }
        .onChange(of: appLock) { unlocked = false }
    }
    var bottomBar: some View {
        HStack {
            tabButton("首页", "house", 0); tabButton("报表", "chart.bar.xaxis", 1)
            Button { add = true } label: { Image(systemName: "plus").font(.title2.bold()).foregroundStyle(.white).frame(width: 56, height: 56).background(Color.brand.gradient, in: Circle()) }.accessibilityLabel("记一笔").padding(.horizontal, 8)
            tabButton("资产", "creditcard", 2); tabButton("账本", "books.vertical", 3)
        }.padding(.horizontal, 10).padding(.vertical, 8).background(.regularMaterial)
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
