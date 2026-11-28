import SwiftUI
import UIKit
import UserNotifications

@main
struct KuberaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = Store.shared
    @StateObject private var router = Router.shared
    @StateObject private var lock = AppLock.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(router)
                .environmentObject(lock)
                .preferredColorScheme(.dark)
                .tint(Theme.gold)
                .onOpenURL { url in router.open(url) }
                .onChange(of: phase) { p in
                    switch p {
                    case .active:
                        lock.didForeground()
                        Task { await store.sync(reason: "foreground") }
                    case .inactive:
                        lock.didResignActive()
                    case .background:
                        lock.didBackground()
                        store.saveNow()
                        BackgroundSync.schedule()
                    default: break
                    }
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Pref.register()
        Diag.setup()
        // Solid black bars with a hairline, for the OLED screen (content never shows through the tab bar).
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = .black
        tab.shadowColor = UIColor(white: 0.17, alpha: 1)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = .black
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: UIColor.white]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UNUserNotificationCenter.current().delegate = self
        BackgroundSync.register()
        DarwinNote.observe(DarwinNote.inboxChanged) {
            Task { @MainActor in await Store.shared.sync(reason: "inbox") }
        }
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let link = response.notification.request.content.userInfo["link"] as? String
        Task { @MainActor in
            if let l = link, let u = URL(string: l) { Router.shared.open(u) }
            completionHandler()
        }
    }
}

enum MainTab: String { case expenses, invest, networth, more }

/// Which screen is up, and the jobs that open screens from links, notifications and test hooks.
@MainActor
final class Router: ObservableObject {
    static let shared = Router()
    @Published var tab: MainTab = .expenses
    @Published var showCheckin = false
    @Published var showMantra = false
    @Published var showBudgets = false
    @Published var showImport = false
    /// Test hook: screenshots read by `_diag/importfile`, handed to the Invest screen's review.
    @Published var diagFindings: [ScreenshotFinding] = []
    @Published var showSplash: Bool = Router.splashAtLaunch()
    @Published var expensePath = NavigationPath()

    /// Decided once per launch: every launch, once a day, or never (Settings).
    nonisolated static func splashAtLaunch() -> Bool {
        let d = UserDefaults.standard
        if FileManager.default.fileExists(atPath: Paths.caches.appendingPathComponent("kb-diag").path) { return false }
        switch d.string(forKey: Pref.splashMode) ?? "always" {
        case "never": return false
        case "daily":
            let today = Cal.dayKey(Date())
            if d.string(forKey: Pref.lastSplashDay) == today { return false }
            d.set(today, forKey: Pref.lastSplashDay)
            return true
        default: return true
        }
    }

    func open(_ url: URL) {
        guard url.scheme == "kubera" else { return }
        if url.host == "_diag" { Diag.handle(url); return }
        // While locked (or about to lock) the link waits, and opens after Face ID.
        if AppLock.shared.hold(url) { return }
        switch url.host ?? "" {
        case "checkin": tab = .expenses; showCheckin = true
        case "budgets": tab = .expenses; showBudgets = true
        case "trading": tab = .invest
        case "import": tab = .invest; showImport = true
        case "networth": tab = .networth
        default: break
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @EnvironmentObject var lock: AppLock
    @State private var started = false

    var body: some View {
        ZStack {
            TabView(selection: $router.tab) {
                ExpensesView()
                    .tabItem { Label("Expenses", systemImage: "indianrupeesign.circle.fill") }
                    .tag(MainTab.expenses)
                TradingView()
                    .tabItem { Label("Invest", systemImage: "chart.line.uptrend.xyaxis") }
                    .tag(MainTab.invest)
                NetWorthView()
                    .tabItem { Label("Net Worth", systemImage: "crown.fill") }
                    .tag(MainTab.networth)
                SettingsView()
                    .tabItem { Label("More", systemImage: "gearshape.fill") }
                    .tag(MainTab.more)
            }
            if router.showSplash {
                SplashView { withAnimation(.easeOut(duration: 0.35)) { router.showSplash = false } }
                    .transition(.opacity)
                    .zIndex(2)
            }
            if lock.locked {
                LockView().zIndex(3)
            }
        }
        .sheet(isPresented: $router.showCheckin) { CheckInView() }
        .sheet(isPresented: $router.showMantra) { MantraSheet() }
        .sheet(isPresented: $router.showBudgets) { BudgetsView() }
        .task {
            guard !started else { return }
            started = true
            lock.appear()
            Reminders.requestPermission()
            await store.sync(reason: "launch")
        }
    }
}

struct LockView: View {
    @EnvironmentObject var lock: AppLock
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Image("Emblem").resizable().scaledToFit().frame(width: 90, height: 90)
                Text("Kubera is locked").font(.headline)
                Button { lock.unlock() } label: {
                    Label("Unlock", systemImage: "faceid").font(.headline).padding(.horizontal, 24).padding(.vertical, 10)
                        .background(Capsule().fill(Theme.gold)).foregroundColor(.black)
                }
            }
        }
    }
}
