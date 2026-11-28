import Foundation
import UIKit
import UserNotifications
import LocalAuthentication
import Photos
import Vision
import ImageIO
import BackgroundTasks

// MARK: - The 22:00 check-in, badge and budget alerts

enum Reminders {
    static let checkinID = "kubera.checkin"
    static let checkinCategory = "kubera.checkin.category"
    static let budgetPrefix = "kubera.budget."
    static let testID = "kubera.listener-test"

    static func requestPermission() {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        let sort = UNNotificationAction(identifier: "sort", title: "Sort now", options: [.foreground])
        c.setNotificationCategories([UNNotificationCategory(identifier: checkinCategory, actions: [sort], intentIdentifiers: [], options: [])])
    }

    /// Schedules the next seven check-ins and sets the app badge. Only a check-in later today can know what will be
    /// waiting, so it alone carries the count and the P&L reminder; the others use plain text (every refresh, from
    /// the app or a background sync, writes them again).
    @MainActor
    static func refresh(store: Store) {
        let count = store.uncategorized.count
        let now = Date()
        let today = Cal.startOfDay(now)
        let tradedToday = store.state.turnovers.values.contains { Cal.sameDay($0.date, today) }
        let recordedToday = store.state.trades.values.contains { Cal.sameDay($0.date, today) }
        let tradeLine = Holidays.isTradingDay(today, extra: store.state.userHolidays) && tradedToday && !recordedToday
            ? " Today's P&L screenshot is not in yet." : ""
        let hour = Pref.d.integer(forKey: Pref.checkinHour)
        let minute = Pref.d.integer(forKey: Pref.checkinMinute)
        let center = UNUserNotificationCenter.current()
        let ids = (0..<7).map { "\(checkinID).\($0)" }
        center.removePendingNotificationRequests(withIdentifiers: [checkinID] + ids)
        guard var first = Cal.make(Cal.year(now), Cal.month(now), Cal.day(now), hour, minute) else { return }
        if first <= now { first = Cal.addDays(1, to: first) }
        for i in 0..<7 {
            let at = Cal.addDays(i, to: first)
            let content = UNMutableNotificationContent()
            content.title = "🙏 Evening check-in"
            if i == 0 && Cal.sameDay(at, now) {
                content.body = count == 0
                    ? "All expenses are sorted." + tradeLine + " Shubham bhavatu."
                    : "\(count) expense\(count == 1 ? "" : "s") to sort." + tradeLine + " Tap to sort them now."
            } else {
                content.body = "Time to sort the day's payments. Tap to open the check-in."
            }
            content.sound = .default
            content.categoryIdentifier = checkinCategory
            content.userInfo = ["link": "kubera://checkin"]
            var dc = Cal.cal.dateComponents([.year, .month, .day, .hour, .minute], from: at)
            dc.timeZone = Cal.ist
            center.add(UNNotificationRequest(identifier: ids[i], content: content,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: dc, repeats: false)))
        }
        UIApplication.shared.applicationIconBadgeNumber = count
    }

    /// One alert per category per month when it passes 80% and again at 100% of its budget.
    @MainActor
    static func checkBudgets(store: Store, newIDs: [String]) {
        guard Pref.d.bool(forKey: Pref.budgetAlerts), !newIDs.isEmpty, !store.state.budgets.isEmpty else { return }
        let month = Date()
        let s = store.spend
        let list = s.inMonth(month)
        var alerted = Set(Pref.d.stringArray(forKey: Pref.alertedBudgets) ?? [])
        let monthKey = Cal.dayKey(Cal.startOfMonth(month))
        for (cat, budget) in store.state.budgets where budget > 0 {
            let spent = cat == "total" ? s.spent(list) : s.spent(list.filter { $0.category == cat })
            let pct = spent / budget
            for level in [1.0, 0.8] where pct >= level {
                let key = "\(monthKey)|\(cat)|\(level)"
                if alerted.contains(key) { break }
                alerted.insert(key)
                let name = cat == "total" ? "Monthly budget" : store.category(cat).name
                let c = UNMutableNotificationContent()
                c.title = level >= 1 ? "\(name): budget used up" : "\(name): 80% of budget used"
                c.body = "\(Money.format(spent, paise: false)) of \(Money.format(budget, paise: false)) this month."
                c.sound = .default
                c.userInfo = ["link": "kubera://budgets"]
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: budgetPrefix + key, content: c, trigger: nil))
                break
            }
        }
        Pref.d.set(Array(alerted.suffix(200)), forKey: Pref.alertedBudgets)
    }

    /// Posts a notification that only the Kubera Listener tweak should react to (test of the whole route).
    static func postListenerTest() {
        let c = UNMutableNotificationContent()
        c.title = "Kubera listener test"
        c.body = "Rs.1.00 debited from A/c XX0000 for a test of the notification route (Ref 999999999999)"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: testID + ".\(Int(Date().timeIntervalSince1970))", content: c, trigger: nil))
    }
}

// MARK: - Face ID lock

/// Locks at launch and after more than two minutes away. The Face ID prompt, Control Center and the app switcher
/// all make the app inactive and active again, so the time away is used once and only one prompt runs at a time.
/// Sheets sit above the lock screen, so locking closes them; a link that comes in meanwhile waits for Face ID.
@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()
    @Published var locked = false
    private var backgroundedAt: Date?
    private var started = false
    private var authenticating = false
    private var promptWhenActive = false
    private var heldLink: URL?
    private var cover: UIWindow?

    /// On in Settings, and never while the test hooks drive the app.
    private var isOn: Bool { Pref.d.bool(forKey: Pref.lockEnabled) && !Diag.enabled }

    func appear() {
        started = true
        if isOn { lock(promptNow: UIApplication.shared.applicationState == .active) }
    }

    /// Out of the front for a moment (app switcher, Control Center): cover the screen. While locked the lock screen
    /// already covers it, and the Face ID prompt shows over the lock screen.
    func didResignActive() {
        if isOn && !locked { setCover(true) }
    }

    func didBackground() {
        if isOn { setCover(true) }
        if backgroundedAt == nil { backgroundedAt = Date() }
    }

    func didForeground() {
        let away = backgroundedAt.map { Date().timeIntervalSince($0) } ?? 0
        backgroundedAt = nil
        let due = promptWhenActive
        promptWhenActive = false
        if isOn {
            if away > 120 { lock(promptNow: true) } else if due { unlock() }
        }
        setCover(false)
    }

    /// Keeps a link that comes in while locked, or while a lock is due (at launch, or back after two minutes away).
    func hold(_ url: URL) -> Bool {
        let due = locked || !started || (backgroundedAt.map { Date().timeIntervalSince($0) > 120 } ?? false)
        guard isOn, due else { return false }
        heldLink = url
        return true
    }

    func unlock() {
        guard locked, !authenticating else { return }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { opened(); return }
        authenticating = true
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Kubera") { ok, _ in
            Task { @MainActor in
                AppLock.shared.authenticating = false
                if ok { AppLock.shared.opened() }
            }
        }
    }

    private func lock(promptNow: Bool) {
        // With no passcode on the phone there is nothing to unlock with.
        guard LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { opened(); return }
        locked = true
        closeSheets()
        if promptNow { unlock() } else { promptWhenActive = true }
    }

    private func opened() {
        locked = false
        if let u = heldLink { heldLink = nil; Router.shared.open(u) }
    }

    /// Sheets (and the keyboard) would stay above the lock screen.
    private func closeSheets() {
        _ = UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let r = Router.shared
        r.showCheckin = false; r.showMantra = false; r.showBudgets = false; r.showImport = false
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for w in scene.windows where w !== cover && w.rootViewController?.presentedViewController != nil {
                w.rootViewController?.dismiss(animated: false)
            }
        }
    }

    /// Black with the emblem, in a window above every sheet, so the app-switcher picture shows nothing.
    private func setCover(_ on: Bool) {
        guard on else { cover?.isHidden = true; cover = nil; return }
        guard cover == nil, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        w.overrideUserInterfaceStyle = .dark
        let vc = UIViewController()
        vc.view.backgroundColor = .black
        let emblem = UIImageView(image: UIImage(named: "Emblem"))
        emblem.contentMode = .scaleAspectFit
        emblem.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(emblem)
        NSLayoutConstraint.activate([
            emblem.widthAnchor.constraint(equalToConstant: 90),
            emblem.heightAnchor.constraint(equalToConstant: 90),
            emblem.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor),
            emblem.centerYAnchor.constraint(equalTo: vc.view.centerYAnchor),
        ])
        w.rootViewController = vc
        w.isHidden = false
        cover = w
    }
}

// MARK: - Broker screenshots: Photos + on-device text recognition

struct ScreenshotFinding: Identifiable {
    var id: String { assetID }
    var assetID: String
    var created: Date
    var image: UIImage
    var reading: TradeReading
    var tradingDay: Date
    /// False when the picture's date was not available, so the trading day is a guess.
    var dateKnown = true
}

enum ScreenshotScanner {
    static func authorized() -> Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    static func requestAccess() async -> Bool {
        let s = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return s == .authorized || s == .limited
    }

    struct ScanResult {
        var findings: [ScreenshotFinding] = []
        /// Screenshots that were read and are not broker screens, so they need not be read again.
        var examined: [String] = []
    }

    /// Pictures taken since `since` that are screenshots (tagged so by iOS, or exactly the size of this screen:
    /// screenshots saved by tweaks are not always tagged) and look like a broker's positions or holdings screen.
    /// Screenshots in `skip` (already read or reviewed) are passed over before the limit is counted.
    static func scan(since: Date, skip: Set<String>, holidays: [Holiday], limit: Int = 25) async -> ScanResult {
        guard authorized() else { return ScanResult() }
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "creationDate > %@", since as NSDate)
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: .image, options: opts)
        let screen = await MainActor.run { UIScreen.main.nativeBounds.size }
        let sw = Int(min(screen.width, screen.height)), sh = Int(max(screen.width, screen.height))
        var list: [PHAsset] = []
        assets.enumerateObjects { a, _, stop in
            guard !skip.contains(a.localIdentifier) else { return }
            let tagged = a.mediaSubtypes.contains(.photoScreenshot)
            let screenSized = min(a.pixelWidth, a.pixelHeight) == sw && max(a.pixelWidth, a.pixelHeight) == sh
            if tagged || screenSized { list.append(a) }
            if list.count >= limit { stop.pointee = true }
        }
        Diag.log("screenshot scan: \(assets.count) pictures since \(since), \(list.count) new screenshots to read")
        var result = ScanResult()
        for a in list {
            guard let img = await image(for: a) else { Diag.log("  \(a.localIdentifier.prefix(8)) no image"); continue }
            let t0 = Date()
            let lines = await recognize(img)
            let reading = TradeOCRParser.read(lines)
            Diag.log("  \(a.localIdentifier.prefix(8)) \(a.pixelWidth)x\(a.pixelHeight) lines=\(lines.count) \(Int(Date().timeIntervalSince(t0) * 1000)) ms broker=\(reading.broker ?? "-") kind=\(reading.kind.rawValue) total=\(reading.total.map { String($0) } ?? "-") conf=\(String(format: "%.2f", reading.confidence))")
            guard reading.kind != .unknown || reading.broker != nil, reading.total != nil || reading.currentValue != nil else {
                // Not a broker screen. Only remembered when text was read, so a failed read is tried again later.
                if !lines.isEmpty { result.examined.append(a.localIdentifier) }
                continue
            }
            let created = a.creationDate ?? Date()
            result.findings.append(ScreenshotFinding(assetID: a.localIdentifier, created: created, image: img, reading: reading,
                                                     tradingDay: Holidays.tradingDay(forScreenshotAt: created, extra: holidays, commodity: reading.commodity),
                                                     dateKnown: a.creationDate != nil))
        }
        return result
    }

    /// When a picture was taken, from its own metadata (for pictures the photo library could not be asked about).
    static func takenDate(in data: Data) -> Date? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let candidates: [Any?] = [exif?[kCGImagePropertyExifDateTimeOriginal], exif?[kCGImagePropertyExifDateTimeDigitized],
                                  tiff?[kCGImagePropertyTIFFDateTime], png?[kCGImagePropertyPNGCreationTime]]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current   // EXIF times carry no zone: they are the phone's local time
        for case let raw as String in candidates.compactMap({ $0 }) {
            for format in ["yyyy:MM:dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd HH:mm:ss"] {
                f.dateFormat = format
                if let d = f.date(from: raw) { return d }
            }
        }
        return nil
    }

    static func image(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { cont in
            let o = PHImageRequestOptions()
            o.isNetworkAccessAllowed = true
            o.deliveryMode = .highQualityFormat
            o.isSynchronous = false
            PHImageManager.default().requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .default, options: o) { img, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !degraded { cont.resume(returning: img) }
            }
        }
    }

    /// On-device text recognition, then the broker reader. Text colour (green / red) is sampled for the sign.
    static func read(_ image: UIImage) async -> TradeReading {
        let lines = await recognize(image)
        return TradeOCRParser.read(lines)
    }

    static func recognize(_ image: UIImage) async -> [OCRLine] {
        guard let cg = bitmap(of: image) else { Diag.log("text reader: picture has no bitmap"); return [] }
        return await TextReader.lines(in: cg)
    }

    /// The picture's bitmap, upright. Drawn afresh when the picture has none or is stored turned.
    static func bitmap(of image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard size.width >= 1, size.height >= 1 else { return nil }
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = true
        return UIGraphicsImageRenderer(size: size, format: f).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.cgImage
    }
}

/// Reads pixels of a screenshot to tell green (profit) from red (loss) text.
struct PixelSampler {
    let width: Int, height: Int
    let data: [UInt8]

    init?(_ cg: CGImage) {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        width = w; height = h; data = buf
    }

    /// +1 when the strongly coloured pixels in the box are green, -1 when red, 0 otherwise.
    func tint(in box: CGRect) -> Int {
        // CGContext rows start at the top here (the bitmap is drawn upright); Vision's box starts bottom-left.
        let x0 = max(0, Int(box.minX * CGFloat(width))), x1 = min(width - 1, Int(box.maxX * CGFloat(width)))
        let y0 = max(0, Int((1 - box.maxY) * CGFloat(height))), y1 = min(height - 1, Int((1 - box.minY) * CGFloat(height)))
        guard x1 > x0, y1 > y0 else { return 0 }
        var green = 0, red = 0
        let stepX = max(1, (x1 - x0) / 60), stepY = max(1, (y1 - y0) / 12)
        var y = y0
        while y <= y1 {
            var x = x0
            while x <= x1 {
                let i = (y * width + x) * 4
                let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
                if g > r + 40 && g > b + 10 { green += 1 }
                if r > g + 50 && r > b + 30 { red += 1 }
                x += stepX
            }
            y += stepY
        }
        if green > red * 2 && green >= 3 { return 1 }
        if red > green * 2 && red >= 3 { return -1 }
        return 0
    }
}

// MARK: - Background refresh

enum BackgroundSync {
    static let id = "com.cobradarsh.kubera.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            schedule()
            let work = Task { @MainActor in
                await Store.shared.sync(reason: "background")
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let r = BGAppRefreshTaskRequest(identifier: id)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 45 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }
}
