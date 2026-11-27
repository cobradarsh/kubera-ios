import Foundation
import Security
import UIKit

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let u = base.appendingPathComponent("Kubera", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static let caches: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    /// Shared with the Kubera Listener tweak (real file system; SpringBoard writes as mobile).
    static let shared = URL(fileURLWithPath: "/var/mobile/Library/Kubera", isDirectory: true)
    static let ledger = support.appendingPathComponent("kubera.json")
}

/// App settings (UserDefaults). Names are also used by @AppStorage in the views.
enum Pref {
    static let lockEnabled = "lockEnabled"
    static let splashMode = "splashMode"            // always | daily | never
    static let lastSplashDay = "lastSplashDay"
    static let checkinHour = "checkinHour"
    static let checkinMinute = "checkinMinute"
    static let smsEnabled = "smsEnabled"
    static let inboxEnabled = "inboxEnabled"
    static let listenerApps = "listenerApps"
    static let mailEnabled = "mailEnabled"
    static let mailAddress = "mailAddress"
    static let lastMailSync = "lastMailSync"
    static let webLookup = "webLookup"
    static let claudeEnabled = "claudeEnabled"
    static let claudeModel = "claudeModel"
    static let lastClaudeRun = "lastClaudeRun"
    static let lookupCity = "lookupCity"
    static let budgetAlerts = "budgetAlerts"
    static let autoScanScreenshots = "autoScanScreenshots"
    static let mantraScript = "mantraScript"        // devanagari | latin
    static let chartKind = "chartKind"
    static let tradeChartKind = "tradeChartKind"
    static let alertedBudgets = "alertedBudgets"

    static func register() {
        UserDefaults.standard.register(defaults: [
            lockEnabled: false, splashMode: "always", checkinHour: 22, checkinMinute: 0, smsEnabled: true,
            inboxEnabled: true, mailEnabled: false, webLookup: true, claudeEnabled: false, claudeModel: "claude-opus-5-5",
            lookupCity: "", budgetAlerts: true, autoScanScreenshots: true, mantraScript: "devanagari",
        ])
    }

    static var d: UserDefaults { .standard }
}

/// Secrets (Gmail app password, Claude API key) live in the Keychain, this device only.
enum Keychain {
    static let service = "com.cobradarsh.kubera"

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let v = value, !v.isEmpty, let data = v.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static let gmailPassword = "gmail-app-password"
    static let claudeKey = "claude-api-key"
}

/// Darwin notifications shared with the tweak.
enum DarwinNote {
    static let inboxChanged = "com.cobradarsh.kubera.inbox"
    static let listenerConfig = "com.cobradarsh.kubera.listener"

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }

    static func observe(_ name: String, _ handler: @escaping () -> Void) {
        Handlers.shared.handlers[name] = handler
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, cfName, _, _ in
            guard let cf = cfName?.rawValue else { return }
            let n = cf as String
            DispatchQueue.main.async { Handlers.shared.handlers[n]?() }
        }, name as CFString, nil, .deliverImmediately)
    }

    final class Handlers {
        static let shared = Handlers()
        var handlers: [String: () -> Void] = [:]
    }
}

enum Haptic {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warn() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}
