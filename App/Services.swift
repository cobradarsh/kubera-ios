import Foundation
import UIKit
import UserNotifications
import LocalAuthentication
import Photos
import Vision
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

    /// Replaces the daily check-in with one whose text says what is waiting, and sets the app badge.
    @MainActor
    static func refresh(store: Store) {
        let count = store.uncategorized.count
        let today = Cal.startOfDay(Date())
        let tradedToday = store.state.turnovers.values.contains { Cal.sameDay($0.date, today) }
        let recordedToday = store.state.trades.values.contains { Cal.sameDay($0.date, today) }
        let tradeLine = Holidays.isTradingDay(today, extra: store.state.userHolidays) && tradedToday && !recordedToday
            ? " Today's P&L screenshot is not in yet." : ""

        let content = UNMutableNotificationContent()
        content.title = "🙏 Evening check-in"
        if count == 0 {
            content.body = "All expenses are sorted." + tradeLine + " Shubham bhavatu."
        } else {
            content.body = "\(count) expense\(count == 1 ? "" : "s") to sort." + tradeLine + " Tap to sort them now."
        }
        content.sound = .default
        content.categoryIdentifier = checkinCategory
        content.userInfo = ["link": "kubera://checkin"]
        let hour = Pref.d.integer(forKey: Pref.checkinHour)
        let minute = Pref.d.integer(forKey: Pref.checkinMinute)
        var dc = DateComponents()
        dc.hour = hour
        dc.minute = minute
        dc.timeZone = Cal.ist
        let trigger = UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [checkinID])
        center.add(UNNotificationRequest(identifier: checkinID, content: content, trigger: trigger))
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

@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()
    @Published var locked = false
    private var backgroundedAt: Date?

    func appear() {
        if Pref.d.bool(forKey: Pref.lockEnabled) && !Diag.enabled { locked = true; unlock() }
    }

    func didBackground() { backgroundedAt = Date() }

    func didForeground() {
        guard Pref.d.bool(forKey: Pref.lockEnabled), !Diag.enabled else { return }
        if let b = backgroundedAt, Date().timeIntervalSince(b) > 120 { locked = true; unlock() }
    }

    func unlock() {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { locked = false; return }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Kubera") { ok, _ in
            Task { @MainActor in if ok { AppLock.shared.locked = false } }
        }
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

    /// Screenshots taken since `since` that look like a broker's positions or holdings screen.
    static func scan(since: Date, skip: Set<String>, holidays: [Holiday], limit: Int = 30) async -> [ScreenshotFinding] {
        guard authorized() else { return [] }
        // The Screenshots smart album, newest first (a plain date predicate; no bitmask predicate needed).
        guard let album = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumScreenshots, options: nil).firstObject else { return [] }
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "creationDate > %@", since as NSDate)
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = limit
        let assets = PHAsset.fetchAssets(in: album, options: opts)
        var list: [PHAsset] = []
        assets.enumerateObjects { a, _, _ in if !skip.contains(a.localIdentifier) { list.append(a) } }
        var out: [ScreenshotFinding] = []
        for a in list {
            guard let img = await image(for: a) else { continue }
            let reading = await read(img)
            guard reading.kind != .unknown || reading.broker != nil, reading.total != nil || reading.currentValue != nil else { continue }
            let created = a.creationDate ?? Date()
            out.append(ScreenshotFinding(assetID: a.localIdentifier, created: created, image: img, reading: reading,
                                         tradingDay: Holidays.tradingDay(forScreenshotAt: created, extra: holidays)))
        }
        return out
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
        guard let cg = image.cgImage else { return [] }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate
                req.usesLanguageCorrection = false
                req.recognitionLanguages = ["en-US"]
                let handler = VNImageRequestHandler(cgImage: cg, orientation: .up)
                var lines: [OCRLine] = []
                if (try? handler.perform([req])) != nil {
                    let pixels = PixelSampler(cg)
                    for o in req.results ?? [] {
                        guard let top = o.topCandidates(1).first else { continue }
                        let b = o.boundingBox // origin bottom-left, normalised
                        var line = OCRLine(text: top.string, x: Double(b.minX), y: Double(1 - b.maxY), w: Double(b.width), h: Double(b.height))
                        line.tint = pixels?.tint(in: b) ?? 0
                        lines.append(line)
                    }
                }
                cont.resume(returning: lines)
            }
        }
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
