import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SharedFile: Identifiable {
    var id: String { url.path }
    var url: URL
}

/// The system share sheet for a file made on demand.
struct ShareSheet: UIViewControllerRepresentable {
    var url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @AppStorage(Pref.smsEnabled) private var smsOn = true
    @AppStorage(Pref.inboxEnabled) private var inboxOn = true
    @AppStorage(Pref.mailEnabled) private var mailOn = false
    @AppStorage(Pref.mailAddress) private var mailAddress = ""
    @AppStorage(Pref.webLookup) private var webOn = true
    @AppStorage(Pref.lookupCity) private var city = ""
    @AppStorage(Pref.claudeEnabled) private var claudeOn = false
    @AppStorage(Pref.claudeModel) private var claudeModel = "claude-opus-5-5"
    @AppStorage(Pref.checkinHour) private var checkinHour = 22
    @AppStorage(Pref.checkinMinute) private var checkinMinute = 0
    @AppStorage(Pref.budgetAlerts) private var budgetAlerts = true
    @AppStorage(Pref.autoScanScreenshots) private var autoScan = true
    @AppStorage(Pref.lockEnabled) private var lockOn = false
    @AppStorage(Pref.splashMode) private var splashMode = "always"
    @AppStorage(Pref.mantraScript) private var script = "devanagari"
    @State private var gmailPassword = ""
    @State private var claudeKey = ""
    @State private var mailTest: String?
    @State private var importing = false
    @State private var restoreResult: String?
    @State private var smsProbe: String?
    @State private var sharing: SharedFile?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MantraHeader().listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                }
                sourcesSection
                gmailSection
                lookupSection
                Section {
                    DatePicker("Daily check-in", selection: checkinTime, displayedComponents: .hourAndMinute)
                    Toggle("Budget alerts (80% and 100%)", isOn: $budgetAlerts).tint(Theme.gold)
                    Button("Budgets…") { router.showBudgets = true }
                    Button("Sort now (\(store.uncategorized.count))") { router.showCheckin = true }
                } header: { Text("Check-in") } footer: {
                    Text("Every day at this time a notification lists what is still unsorted (and whether today's P&L is in).")
                }
                Section("Categories") {
                    NavigationLink("Your rules (\(store.state.rules.count))") { RulesView() }
                    NavigationLink("Add a category") { AddCategoryView() }
                }
                Section {
                    Toggle("Find broker screenshots by themselves", isOn: $autoScan).tint(Theme.gold)
                } header: { Text("Trading") } footer: {
                    Text("Reads new screenshots in Photos on this iPhone (text recognition runs on the phone).")
                }
                Section("Look & security") {
                    Toggle("Face ID lock", isOn: $lockOn).tint(Theme.gold)
                    Picker("Salutations on opening", selection: $splashMode) {
                        Text("Every time").tag("always")
                        Text("Once a day").tag("daily")
                        Text("Never").tag("never")
                    }
                    Picker("Script", selection: $script) {
                        Text("देवनागरी").tag("devanagari")
                        Text("English letters").tag("latin")
                    }
                    Button("Show the salutations now") { router.showSplash = true }
                }
                dataSection
                Section {
                    Text("Everything stays on this iPhone. Web lookups send only a business's name (and your city); Claude gets the same, and only with your own key. Kubera never writes to your Messages.")
                        .font(.footnote).foregroundColor(Theme.dim)
                    HStack { Text("Version"); Spacer(); Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "").foregroundColor(Theme.dim) }
                } header: { Text("About") }
            }
            .kuberaScreen()
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                gmailPassword = Keychain.get(Keychain.gmailPassword) == nil ? "" : "••••••••••••••••"
                claudeKey = Keychain.get(Keychain.claudeKey) == nil ? "" : "••••••••••••••••"
                smsProbe = SMSReader.probe()
            }
            .onChange(of: checkinHour) { _ in Reminders.refresh(store: store) }
            .onChange(of: checkinMinute) { _ in Reminders.refresh(store: store) }
            .sheet(item: $sharing) { f in ShareSheet(url: f.url) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result {
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    restoreResult = store.restoreBackup(from: url) ? "Restored." : "That file is not a Kubera backup."
                }
            }
        }
    }

    private var checkinTime: Binding<Date> {
        Binding(get: {
            Cal.cal.date(bySettingHour: checkinHour, minute: checkinMinute, second: 0, of: Date()) ?? Date()
        }, set: { d in
            checkinHour = Cal.hour(d)
            checkinMinute = Cal.cal.component(.minute, from: d)
        })
    }

    private var sourcesSection: some View {
        Section {
            Toggle("Read bank SMS", isOn: $smsOn).tint(Theme.gold)
            if let p = smsProbe { Text(p).font(.caption2).foregroundColor(Theme.faint) }
            Toggle("Payment-app notifications", isOn: $inboxOn).tint(Theme.gold)
                .onChange(of: inboxOn) { v in NotificationInbox.writeConfig(enabled: v, apps: listenerApps) }
            HStack {
                Text("Kubera Listener tweak")
                Spacer()
                Text(NotificationInbox.tweakSeen ? "installed" : "not installed").foregroundColor(NotificationInbox.tweakSeen ? Theme.profit : Theme.dim)
            }
            .font(.footnote)
            NavigationLink("Apps to listen to") { ListenerAppsView() }
            Button("Read messages now") { Task { await store.sync(reason: "manual") } }
            if let s = store.status { Text(s).font(.caption).foregroundColor(Theme.dim) }
        } header: { Text("Where expenses come from") } footer: {
            Text("SMS are read straight from the Messages database (read-only). Notifications from GPay, BHIM, Amazon, Gmail and broker apps come through the Kubera Listener tweak (.deb).")
        }
    }

    private var listenerApps: [String] {
        (Pref.d.stringArray(forKey: Pref.listenerApps) ?? NotificationInbox.defaultApps)
    }

    private var gmailSection: some View {
        Section {
            Toggle("Read Gmail alerts", isOn: $mailOn).tint(Theme.gold)
            if mailOn {
                TextField("you@gmail.com", text: $mailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("App password (16 letters)", text: $gmailPassword)
                    .onSubmit { saveGmailPassword() }
                Button("Save and test sign-in") {
                    saveGmailPassword()
                    Task { await testGmail() }
                }
                if let t = mailTest { Text(t).font(.caption).foregroundColor(Theme.dim) }
                Link("Create an app password (Google account)", destination: URL(string: "https://myaccount.google.com/apppasswords")!)
                    .font(.footnote)
            }
        } header: { Text("Gmail") } footer: {
            Text("Read-only: bank, card and UPI alert mail from the last six months, then new ones every half hour. Needs 2-Step Verification on your Google account; the app password stays in this iPhone's Keychain.")
        }
    }

    private func saveGmailPassword() {
        if !gmailPassword.hasPrefix("••") {
            Keychain.set(gmailPassword.replacingOccurrences(of: " ", with: ""), for: Keychain.gmailPassword)
            gmailPassword = gmailPassword.isEmpty ? "" : "••••••••••••••••"
        }
    }

    private func testGmail() async {
        guard let pw = Keychain.get(Keychain.gmailPassword), !mailAddress.isEmpty else { mailTest = "Enter the address and app password."; return }
        mailTest = "Signing in…"
        do {
            try await GmailIMAPClient(email: mailAddress, appPassword: pw).verifyLogin()
            mailTest = "Signed in. Alerts are read at the next sync."
        } catch {
            mailTest = "Could not sign in: \(error.localizedDescription)"
        }
    }

    private var lookupSection: some View {
        Section {
            Toggle("Look up unknown shops on the web", isOn: $webOn).tint(Theme.gold)
            TextField("Your city (for local shops), e.g. Bengaluru", text: $city)
            Toggle("Then ask Claude (web search)", isOn: $claudeOn).tint(Theme.gold)
            if claudeOn {
                SecureField("Claude API key", text: $claudeKey)
                    .onSubmit { saveClaudeKey() }
                Picker("Model", selection: $claudeModel) {
                    Text("Claude Opus 5.5").tag("claude-opus-5-5")
                    Text("Claude Sonnet 5.5").tag("claude-sonnet-5-5")
                }
                Button("Save key and sort now") {
                    saveClaudeKey()
                    Task { await store.runLookups(useClaude: true) }
                }
            }
            if let s = store.lookupStatus { Text(s).font(.caption).foregroundColor(Theme.dim) }
        } header: { Text("Smart sorting") } footer: {
            Text("Order: your rules, Kubera's list of Indian merchants, bank notices, earlier payments, words in the name, then Wikipedia, DuckDuckGo and OpenStreetMap; Claude last, at most once an hour, for up to 25 payees at a time. Payees that look like people are never sent anywhere.")
        }
    }

    private func saveClaudeKey() {
        if !claudeKey.hasPrefix("••") {
            Keychain.set(claudeKey.trimmed, for: Keychain.claudeKey)
            claudeKey = claudeKey.isEmpty ? "" : "••••••••••••••••"
        }
    }

    private var dataSection: some View {
        Section {
            Button { if let u = store.exportCSV() { sharing = SharedFile(url: u) } } label: {
                Label("Export transactions (CSV)", systemImage: "square.and.arrow.up")
            }
            Button { if let u = store.exportBackup() { sharing = SharedFile(url: u) } } label: {
                Label("Back up everything (JSON)", systemImage: "externaldrive.fill")
            }
            Button { importing = true } label: { Label("Restore a backup", systemImage: "arrow.counterclockwise") }
            if let r = restoreResult { Text(r).font(.caption).foregroundColor(Theme.dim) }
            Button { Task { await store.rescanSMS() } } label: { Label("Read all SMS again", systemImage: "arrow.triangle.2.circlepath") }
            if let p = store.loadProblem { Text(p).font(.caption).foregroundColor(.orange) }
        } header: { Text("Data") } footer: {
            Text("\(store.state.txns.filter { !$0.isDuplicate }.count) transactions, \(store.state.txns.filter { $0.isDuplicate }.count) repeats hidden, \(store.state.ignoredCount) messages skipped (OTPs, offers, reminders).")
        }
    }
}

struct RulesView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let rules = store.state.rules.values.sorted { $0.label.lowercased() < $1.label.lowercased() }
        List {
            if rules.isEmpty {
                Text("Rules are made when you sort a payment with \"Remember\" on.").font(.footnote).foregroundColor(Theme.dim)
            }
            ForEach(rules) { r in
                let c = store.category(r.category)
                HStack {
                    CategoryIcon(category: c, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.label.isEmpty ? r.key : r.label).font(.subheadline)
                        Text(r.key.replacingOccurrences(of: "vpa:", with: "UPI ").replacingOccurrences(of: "name:", with: "name ")).font(.caption2).foregroundColor(Theme.faint)
                    }
                    Spacer()
                    Text(c.name).font(.caption).foregroundColor(Theme.dim)
                }
                .swipeActions { Button(role: .destructive) { store.removeRule(r.key) } label: { Label("Delete", systemImage: "trash") } }
            }
        }
        .kuberaScreen()
        .navigationTitle("Your rules")
    }
}

struct AddCategoryView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = "tag.fill"
    @State private var color = Color(hex: "#D4AF37")
    @State private var kind: CategoryKind = .expense
    private let symbols = ["tag.fill", "pawprint.fill", "figure.walk", "car.2.fill", "leaf.fill", "gamecontroller.fill", "music.note", "camera.fill", "wrench.and.screwdriver.fill", "graduationcap.fill", "heart.fill", "star.fill", "bolt.car.fill", "tshirt.fill", "cup.and.saucer.fill", "wineglass.fill", "building.2.fill", "person.crop.circle.fill"]

    var body: some View {
        Form {
            TextField("Name", text: $name)
            Picker("Counts as", selection: $kind) {
                ForEach(CategoryKind.allCases, id: \.self) { k in Text(k.label).tag(k) }
            }
            ColorPicker("Colour", selection: $color, supportsOpacity: false)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                ForEach(symbols, id: \.self) { s in
                    Image(systemName: s).font(.title3).frame(width: 40, height: 40)
                        .foregroundColor(symbol == s ? .black : color)
                        .background(Circle().fill(symbol == s ? color : Color.clear))
                        .onTapGesture { symbol = s }
                }
            }
            Button("Add") {
                let id = "custom." + MerchantDB.normalize(name).replacingOccurrences(of: " ", with: "-")
                store.addCategory(Category(id: id, name: name.trimmed, symbol: symbol, colorHex: color.hexString, kind: kind, builtIn: false))
                dismiss()
            }
            .disabled(name.trimmed.isEmpty)
        }
        .kuberaScreen()
        .navigationTitle("Add a category")
    }
}

struct ListenerAppsView: View {
    @State private var apps: [String] = Pref.d.stringArray(forKey: Pref.listenerApps) ?? NotificationInbox.defaultApps
    @State private var newID = ""
    var body: some View {
        List {
            Section {
                ForEach(apps, id: \.self) { a in Text(a).font(.footnote.monospaced()) }
                    .onDelete { apps.remove(atOffsets: $0); save() }
                HStack {
                    TextField("bundle id, e.g. com.phonepe.PhonePeApp", text: $newID).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Add") { let t = newID.trimmed; if !t.isEmpty && !apps.contains(t) { apps.append(t); save() }; newID = "" }
                }
            } footer: {
                Text("The tweak keeps only notifications from these apps that mention an amount; mail apps also need a word like debited, credited or UPI.")
            }
            Section { Button("Back to the default list") { apps = NotificationInbox.defaultApps; save() } }
        }
        .kuberaScreen()
        .navigationTitle("Apps to listen to")
    }

    private func save() {
        Pref.d.set(apps, forKey: Pref.listenerApps)
        NotificationInbox.writeConfig(enabled: Pref.d.bool(forKey: Pref.inboxEnabled), apps: apps)
    }
}

extension Color {
    var hexString: String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(max(0, min(1, r)) * 255), Int(max(0, min(1, g)) * 255), Int(max(0, min(1, b)) * 255))
    }
}
