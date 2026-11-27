/*  Tweak.m - Kubera Listener, the SpringBoard half of the Kubera app (../App).

    Every notification on its way to the banner, the Lock Screen and Notification Centre passes
    -[NCNotificationDispatcher postNotificationWithRequest:]; one that an app changes passes
    -[NCNotificationDispatcher modifyNotificationWithRequest:]. Both are hooked here the way Shani
    hooks them on the same iOS 16.5 (20F66): the Objective-C runtime replaces the method, and the
    replacement calls the original first, unchanged, and only then looks at the request. Nothing
    is held back, changed or added.

    What is kept: a notification from an app on the list (built in below, or the app's own list
    in listener.json) whose title, subtitle and text hold an amount: the rupee sign, Rs, Rs. or
    INR, then spaces or a colon if any, then a digit. Mail apps also need a transaction word, so
    personal mail never gets in. Each one kept becomes one line of
    /var/mobile/Library/Kubera/inbox.jsonl as ../README.md lays it down ("Contract: tweak -> app
    notification inbox"), and com.cobradarsh.kubera.inbox is posted.

    Threads: the hook copies a few strings out of the request on the thread it is called on (the
    main thread). The filter, the files and the log are all on one private serial queue. Anything
    of ours that throws is caught where it happens: SpringBoard never sees it.

    Files, on the real file system (SpringBoard runs as mobile; the app is unsandboxed):
      Kubera/inbox.jsonl      appended, one JSON object per line; at 2 MB renamed to inbox.1.jsonl
      Kubera/listener.json    written by the app: {"enabled":true|false,"apps":[...]}. Read at
                              start and whenever com.cobradarsh.kubera.listener is posted.
      Kubera/listener-diag    while it exists the app's own notifications count too (its test
                              notification), and each notification seen gets a log line: the
                              app, the lengths of the three strings, kept or why not
      Logs/KuberaListener.log what happened. Never the text of a notification.

    After a respring SpringBoard posts every notification it still holds once more. The last
    lines of the inbox are read at start, so those are recognised and not written twice.       */

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define KL_VERSION      @"1.0.0"
#define KL_DIR          "/var/mobile/Library/Kubera"
#define KL_INBOX        KL_DIR "/inbox.jsonl"
#define KL_INBOX_OLD    KL_DIR "/inbox.1.jsonl"
#define KL_CONFIG       KL_DIR "/listener.json"
#define KL_DIAG         KL_DIR "/listener-diag"
#define KL_LOG_DIR      "/var/mobile/Library/Logs"
#define KL_LOG          KL_LOG_DIR "/KuberaListener.log"
#define KL_NOTE_INBOX   "com.cobradarsh.kubera.inbox"
#define KL_NOTE_CONFIG  "com.cobradarsh.kubera.listener"
#define KL_SELF_APP     @"com.cobradarsh.kubera"

static const off_t kKLInboxMax = 2 * 1024 * 1024;       // then inbox.jsonl becomes inbox.1.jsonl
static const off_t kKLLogMax = 256 * 1024;              // then the older half of the log goes
static const off_t kKLSeedBytes = 128 * 1024;           // read from the end of each inbox file at start
static const NSUInteger kKLSeenMax = 300;               // notifications remembered against repeats

#pragma mark - the queue

static dispatch_queue_t KLQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        queue = dispatch_queue_create("com.adarsh.kuberalistener", attr);
    });
    return queue;
}

#pragma mark - files (queue only)

// Appends with O_APPEND, so a line lands whole at the end of the file. `fixMode`: the file may
// be new, make it rw-r--r-- whatever SpringBoard's umask is.
static BOOL KLAppend(const char *path, NSData *data, BOOL fixMode, int *error) {
    int fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0) {
        if (error) *error = errno;
        return NO;
    }
    if (fixMode) fchmod(fd, 0644);
    const uint8_t *bytes = data.bytes;
    size_t left = data.length;
    BOOL ok = YES;
    while (left > 0) {
        ssize_t n = write(fd, bytes, left);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
            if (error) *error = n < 0 ? errno : EIO;
            ok = NO;
            break;
        }
        bytes += n;
        left -= (size_t)n;
    }
    close(fd);
    return ok;
}

#pragma mark - log (never the text of a notification)

static NSDateFormatter *gLogClock;                      // queue only
static BOOL gLogDirChecked;                             // queue only

static void KLLogWrite(NSDate *when, NSString *message) {
    if (!gLogClock) {
        gLogClock = [NSDateFormatter new];
        gLogClock.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        gLogClock.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    }
    if (!gLogDirChecked) {
        mkdir(KL_LOG_DIR, 0755);                        // there already on any iPhone
        gLogDirChecked = YES;
    }
    struct stat st;
    if (stat(KL_LOG, &st) == 0 && st.st_size > kKLLogMax) {
        // the newest half stays, from the start of a line
        NSData *all = [NSData dataWithContentsOfFile:@(KL_LOG)];
        NSUInteger keep = (NSUInteger)(kKLLogMax / 2);
        if (all.length > keep) {
            const char *bytes = all.bytes;
            NSUInteger from = all.length - keep;
            const char *newline = memchr(bytes + from, '\n', keep);
            if (newline) from = (NSUInteger)(newline - bytes) + 1;
            [[all subdataWithRange:NSMakeRange(from, all.length - from)] writeToFile:@(KL_LOG) atomically:YES];
        }
    }
    NSString *line = [NSString stringWithFormat:@"%@  %@\n", [gLogClock stringFromDate:when], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
    if (data.length) KLAppend(KL_LOG, data, NO, NULL);
}

static void KLLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void KLLog(NSString *format, ...) {
    va_list ap;
    va_start(ap, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    NSDate *when = [NSDate date];
    dispatch_async(KLQueue(), ^{
        @autoreleasepool {
            @try { KLLogWrite(when, message); } @catch (__unused id e) {}
        }
    });
}

// What was thrown, for the log: the exception's name and the start of its reason.
static NSString *KLWhy(id thrown) {
    if ([thrown isKindOfClass:NSException.class]) {
        NSException *exception = thrown;
        NSString *reason = exception.reason ?: @"";
        if (reason.length > 160) reason = [reason substringToIndex:160];
        return [NSString stringWithFormat:@"%@: %@", exception.name, reason];
    }
    return NSStringFromClass([thrown class]) ?: @"?";
}

#pragma mark - reading a request (the hook's thread: only copies strings out)

static const char *KLBareType(const char *type) {       // skips const, in, out, oneway...
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type;
}

// The value of an object-returning method that takes no arguments, or nil.
static id KLGet(id target, NSString *name) {
    if (!target) return nil;
    SEL sel = NSSelectorFromString(name);
    @try {
        if (![target respondsToSelector:sel]) return nil;
        NSMethodSignature *sig = [target methodSignatureForSelector:sel];
        if (!sig || sig.numberOfArguments != 2) return nil;
        const char *returns = KLBareType(sig.methodReturnType);
        if (!returns || *returns != '@') return nil;
        return ((id (*)(id, SEL))objc_msgSend)(target, sel);
    } @catch (__unused id e) {}
    return nil;
}

static NSString *KLText(id target, NSString *name) {
    id value = KLGet(target, name);
    if ([value isKindOfClass:NSAttributedString.class]) value = [(NSAttributedString *)value string];
    return [value isKindOfClass:NSString.class] ? [(NSString *)value copy] : nil;
}

#pragma mark - what is kept (queue only)

static BOOL gEnabled = YES;
static NSSet<NSString *> *gApps;                        // lower case
static NSMutableSet<NSString *> *gSeen;                 // app | id | hash of the body
static NSMutableArray<NSString *> *gSeenOrder;          // the same, oldest first

// Indian payment, UPI, wallet, bank, broker, telecom and mail apps. listener.json replaces it.
static NSSet<NSString *> *KLDefaultApps(void) {
    static NSSet<NSString *> *apps;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *ids = @[
            // common Indian payment, bank, broker, telecom and mail apps
            @"com.google.paisa",                        // Google Pay
            @"in.org.npci.ios.upiapp",                  // BHIM
            @"com.amazon.AmazonIN",                     // Amazon India, Amazon Pay
            @"com.dhan.live",                           // Dhan
            @"com.zerodha.kite3",                       // Kite
            @"com.kotak.neo",                           // Kotak Neo
            @"com.BhartiMobile.myairtel",               // Airtel Thanks
            @"com.jio.myjio",                           // MyJio
            @"com.google.Gmail",                        // mail
            @"com.apple.mobilemail",                    // mail
            // more of the same; some ids are best guesses: a wrong one costs nothing.
            @"com.microsoft.Office.Outlook",            // mail
            @"com.phonepe.PhonePeApp",                  // PhonePe
            @"net.one97.paytm",                         // Paytm
            @"com.dreamplug.cred", @"club.cred.app",    // CRED
            @"com.snapwork.hdfc", @"com.hdfcbank.mobilebanking", @"com.hdfcbank.hdfcmobilebanking",   // HDFC Bank
            @"com.enstage.wibmo.hdfc", @"com.hdfcbank.payzapp",                                     // PayZapp
            @"com.csam.icici.bank.imobile", @"com.icicibank.imobile",                               // ICICI iMobile Pay
            @"com.sbi.lotusintouch", @"com.sbi.yono", @"com.sbi.sbifreedomplus",                    // SBI YONO, YONO Lite
            @"com.axis.mobile", @"com.axisbank.axismobile", @"com.axisbank.mobile",                 // Axis Mobile
            @"com.msf.kbank.mobile", @"com.kotak.mobilebanking", @"com.kotak.kotak811",             // Kotak Bank, Kotak 811
            @"in.upstox.pro", @"in.upstox.app", @"com.upstox.pro",                                  // Upstox
            @"com.nextbillion.groww", @"com.groww.app", @"in.groww.app",                            // Groww
            @"com.msf.angelmobile", @"com.angelbroking.angelmobile", @"com.angelone.app"            // Angel One
        ];
        NSMutableSet<NSString *> *set = [NSMutableSet setWithCapacity:ids.count];
        for (NSString *bundleID in ids) [set addObject:bundleID.lowercaseString];
        apps = set;
    });
    return apps;
}

static BOOL KLIsMail(NSString *lowerApp) {
    return [lowerApp isEqualToString:@"com.google.gmail"] || [lowerApp isEqualToString:@"com.apple.mobilemail"] ||
           [lowerApp isEqualToString:@"com.microsoft.office.outlook"];
}

// The rupee sign (U+20B9), the old rupee sign (U+20A8), Rs, Rs., INR; then spaces or a colon, if
// any; then a digit. "\b" keeps the "rs" of "hours 5" out.
static NSRegularExpression *KLAmountPattern(void) {
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [NSRegularExpression regularExpressionWithPattern:@"(?:\\u20B9|\\u20A8|\\bRs\\.?|\\bINR\\.?)[\\s:]*\\d"
                                                            options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    return pattern;
}

// Mail must also say what happened to the money.
static NSRegularExpression *KLDealPattern(void) {
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [NSRegularExpression regularExpressionWithPattern:
                       @"\\b(?:debited|credited|spent|paid|payment|txn|transaction|upi|card|a/c|account|refund|withdrawn|received)"
                                                            options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    return pattern;
}

static BOOL KLFinds(NSRegularExpression *pattern, NSString *text) {
    if (!pattern || text.length == 0) return NO;
    return [pattern rangeOfFirstMatchInString:text options:0 range:NSMakeRange(0, text.length)].location != NSNotFound;
}

static uint64_t KLHash(NSString *text) {                // FNV-1a over the UTF-8 bytes
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
    const uint8_t *bytes = data.bytes;
    uint64_t hash = 0xcbf29ce484222325ULL;
    for (NSUInteger i = 0; i < data.length; i++) {
        hash ^= bytes[i];
        hash *= 0x100000001b3ULL;
    }
    return hash;
}

static NSString *KLSeenKey(NSString *app, NSString *requestID, NSString *body) {
    return [NSString stringWithFormat:@"%@|%@|%016llx", app.lowercaseString ?: @"", requestID ?: @"",
                                      (unsigned long long)KLHash(body ?: @"")];
}

static void KLRemember(NSString *key) {
    if (!gSeen) {
        gSeen = [NSMutableSet set];
        gSeenOrder = [NSMutableArray array];
    }
    if (key.length == 0 || [gSeen containsObject:key]) return;
    [gSeen addObject:key];
    [gSeenOrder addObject:key];
    while (gSeenOrder.count > kKLSeenMax) {
        [gSeen removeObject:gSeenOrder.firstObject];
        [gSeenOrder removeObjectAtIndex:0];
    }
}

#pragma mark - listener.json (queue only)

// listener.json is there but could not be read (half written, say): the settings stay as they
// were and the file is read again with the next notification. Only the first failure is logged.
static BOOL gConfigUnread;

static void KLLoadConfig(NSString *why) {
    if (!gApps) gApps = KLDefaultApps();
    if (access(KL_CONFIG, F_OK) != 0 && errno == ENOENT) {
        gConfigUnread = NO;
        gEnabled = YES;
        gApps = KLDefaultApps();
        KLLog(@"config (%@): no listener.json, built-in list: enabled=YES, %lu apps", why, (unsigned long)gApps.count);
        return;
    }
    NSData *data = [NSData dataWithContentsOfFile:@(KL_CONFIG)];
    NSError *error = nil;
    id root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    if (![root isKindOfClass:NSDictionary.class]) {
        if (!gConfigUnread) {
            KLLog(@"error: listener.json %@ (error %ld): settings stay enabled=%@, %lu apps; read again with the next notification",
                  data ? @"is not a JSON object" : @"cannot be read", (long)error.code, gEnabled ? @"YES" : @"NO",
                  (unsigned long)gApps.count);
        }
        gConfigUnread = YES;
        return;
    }
    gConfigUnread = NO;
    NSDictionary *config = root;
    id enabled = config[@"enabled"];
    BOOL on = [enabled respondsToSelector:@selector(boolValue)] ? [(NSNumber *)enabled boolValue] : YES;
    id list = config[@"apps"];
    BOOL hasList = [list isKindOfClass:NSArray.class];
    NSSet<NSString *> *apps = KLDefaultApps();
    if (hasList) {
        NSMutableSet<NSString *> *chosen = [NSMutableSet set];
        for (id app in (NSArray *)list) {
            if ([app isKindOfClass:NSString.class] && [(NSString *)app length]) [chosen addObject:[(NSString *)app lowercaseString]];
        }
        apps = chosen;
    }
    gEnabled = on;
    gApps = apps;
    KLLog(@"config (%@): listener.json%@: enabled=%@, %lu apps", why, hasList ? @"" : @" has no app list, built-in list",
          on ? @"YES" : @"NO", (unsigned long)apps.count);
}

#pragma mark - start (queue only, before any notification)

static NSString *KLField(NSDictionary *entry, NSString *key) {
    id value = entry[key];
    return [value isKindOfClass:NSString.class] ? value : @"";
}

// Remembers the whole lines at the end of one inbox file. Returns how many.
static NSUInteger KLSeedFrom(const char *path) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    NSUInteger remembered = 0;
    struct stat st;
    if (fstat(fd, &st) == 0 && st.st_size > 0) {
        off_t from = st.st_size > kKLSeedBytes ? st.st_size - kKLSeedBytes : 0;
        size_t want = (size_t)(st.st_size - from);
        NSMutableData *buffer = [NSMutableData dataWithLength:want];
        ssize_t got = buffer ? pread(fd, buffer.mutableBytes, want, from) : -1;
        const char *bytes = buffer.bytes;
        size_t length = got > 0 ? (size_t)got : 0;
        size_t start = 0;
        if (from > 0 && length > 0) {                   // the first line was cut in two: skip it
            const char *newline = memchr(bytes, '\n', length);
            start = newline ? (size_t)(newline - bytes) + 1 : length;
        }
        while (start < length) {
            const char *newline = memchr(bytes + start, '\n', length - start);
            if (!newline) break;                        // no newline yet: not a whole line
            size_t end = (size_t)(newline - bytes);
            if (end > start) {
                NSData *line = [NSData dataWithBytesNoCopy:(void *)(bytes + start) length:end - start freeWhenDone:NO];
                id object = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
                if ([object isKindOfClass:NSDictionary.class]) {
                    NSDictionary *entry = object;
                    NSString *app = KLField(entry, @"app");
                    if (app.length) {
                        KLRemember(KLSeenKey(app, KLField(entry, @"id"), KLField(entry, @"body")));
                        remembered++;
                    }
                }
            }
            start = end + 1;
        }
    }
    close(fd);
    return remembered;
}

static void KLStart(void) {
    KLRemember(nil);                                    // makes the memory
    KLLoadConfig(@"start");
    if (!KLAmountPattern() || !KLDealPattern()) KLLog(@"error: the patterns did not compile: nothing will be kept");
    NSUInteger older = KLSeedFrom(KL_INBOX_OLD);        // the older file first: the newest lines stay
    NSUInteger newer = KLSeedFrom(KL_INBOX);
    if (older + newer > 0) {
        KLLog(@"remembered %lu notifications already in the inbox", (unsigned long)MIN(older + newer, kKLSeenMax));
    }
}

#pragma mark - one notification (queue only)

// Text that cannot be UTF-8 (half of a surrogate pair) is made to fit, so the JSON can be written.
static NSString *KLClean(NSString *text) {
    if (text.length == 0) return @"";
    if ([text canBeConvertedToEncoding:NSUTF8StringEncoding]) return text;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
    NSString *clean = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    return clean ?: @"";
}

// A string as JSON, quotes included. U+0085, U+2028 and U+2029 are allowed raw inside JSON
// strings but count as line breaks to some readers: they are written as escapes, so a line
// stays one line whatever splits it.
static NSString *KLJSON(NSString *text) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:(text ?: @"")
                                                   options:(NSJSONWritingFragmentsAllowed | NSJSONWritingWithoutEscapingSlashes)
                                                     error:NULL];
    NSString *json = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (!json) return nil;
    static const unichar breaks[] = { 0x0085, 0x2028, 0x2029 };
    for (size_t i = 0; i < sizeof breaks / sizeof breaks[0]; i++) {
        NSString *character = [NSString stringWithCharacters:&breaks[i] length:1];
        if ([json rangeOfString:character].location == NSNotFound) continue;
        json = [json stringByReplacingOccurrencesOfString:character
                                               withString:[NSString stringWithFormat:@"\\u%04x", (unsigned int)breaks[i]]];
    }
    return json;
}

static BOOL KLWrite(NSString *app, NSString *requestID, double t, NSString *title, NSString *subtitle, NSString *body) {
    NSString *jsonID = KLJSON(requestID), *jsonApp = KLJSON(app), *jsonTitle = KLJSON(title);
    NSString *jsonSubtitle = KLJSON(subtitle), *jsonBody = KLJSON(body);
    if (!jsonID || !jsonApp || !jsonTitle || !jsonSubtitle || !jsonBody) {
        KLLog(@"error: a notification from %@ could not be written as JSON", app);
        return NO;
    }
    // the README's order: {"v":1,"id":...,"app":...,"t":...,"title":...,"subtitle":...,"body":...}
    NSString *line = [NSString stringWithFormat:@"{\"v\":1,\"id\":%@,\"app\":%@,\"t\":%lld,\"title\":%@,\"subtitle\":%@,\"body\":%@}\n",
                                                jsonID, jsonApp, (long long)floor(t), jsonTitle, jsonSubtitle, jsonBody];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) {
        KLLog(@"error: a notification from %@ could not be written as UTF-8", app);
        return NO;
    }
    if (mkdir(KL_DIR, 0755) == 0) {
        chmod(KL_DIR, 0755);                            // made just now: rwxr-xr-x whatever the umask
    } else if (errno != EEXIST) {
        KLLog(@"error: cannot make %s: %s", KL_DIR, strerror(errno));
        return NO;
    }
    struct stat st;
    BOOL existed = stat(KL_INBOX, &st) == 0;
    if (existed && st.st_size >= kKLInboxMax) {
        if (rename(KL_INBOX, KL_INBOX_OLD) == 0) {
            existed = NO;
            KLLog(@"inbox.jsonl reached %lld bytes: it is inbox.1.jsonl now, a new inbox.jsonl begins", (long long)st.st_size);
        } else {
            KLLog(@"error: cannot rename inbox.jsonl to inbox.1.jsonl: %s", strerror(errno));
        }
    }
    int error = 0;
    if (!KLAppend(KL_INBOX, data, !existed, &error)) {
        KLLog(@"error: cannot write inbox.jsonl: %s", strerror(error));
        return NO;
    }
    notify_post(KL_NOTE_INBOX);
    KLLog(@"captured %@ (%lu chars)", app, (unsigned long)(title.length + subtitle.length + body.length));
    return YES;
}

// nil: keep it. Otherwise the reason it is not kept, for the diagnostic log.
static NSString *KLVerdict(NSString *app, NSString *requestID, NSString *title, NSString *subtitle, NSString *body,
                           BOOL diag, NSString **seenKey) {
    if (!gEnabled) return @"capture is off in listener.json";
    NSString *lowerApp = app.lowercaseString;
    BOOL listed = [gApps containsObject:lowerApp] || (diag && [lowerApp isEqualToString:KL_SELF_APP]);
    if (!listed) return @"not on the list";
    NSString *text = [NSString stringWithFormat:@"%@\n%@\n%@", title, subtitle, body];
    if (!KLFinds(KLAmountPattern(), text)) return @"no amount";
    if (KLIsMail(lowerApp) && !KLFinds(KLDealPattern(), text)) return @"mail without a transaction word";
    NSString *key = KLSeenKey(app, requestID, body);
    if ([gSeen containsObject:key]) return @"already in the inbox";
    *seenKey = key;
    return nil;
}

static void KLConsider(NSString *how, NSString *app, NSString *requestID, double t,
                       NSString *title, NSString *subtitle, NSString *body) {
    if (gConfigUnread) KLLoadConfig(@"again");
    requestID = KLClean(requestID);
    title = KLClean(title);
    subtitle = KLClean(subtitle);
    body = KLClean(body);
    BOOL diag = access(KL_DIAG, F_OK) == 0;
    NSString *key = nil;
    NSString *skipped = KLVerdict(app, requestID, title, subtitle, body, diag, &key);
    BOOL kept = !skipped && KLWrite(app, requestID, t, title, subtitle, body);
    if (kept) KLRemember(key);
    if (diag) {
        KLLog(@"seen %@ (%@): title %lu, subtitle %lu, body %lu chars: %@", app, how, (unsigned long)title.length,
              (unsigned long)subtitle.length, (unsigned long)body.length,
              kept ? @"kept" : [NSString stringWithFormat:@"skipped, %@", skipped ?: @"could not be written"]);
    }
}

// On the hook's thread: the strings are copied out, everything else goes to the queue.
static void KLObserve(id request, NSString *how) {
    if (!request) return;
    @try {
        NSString *app = KLText(request, @"sectionIdentifier");
        if (app.length == 0) return;
        NSString *requestID = KLText(request, @"notificationIdentifier");
        if (requestID.length == 0) {
            id uuid = KLGet(request, @"uuid");
            requestID = [uuid isKindOfClass:NSUUID.class] ? [(NSUUID *)uuid UUIDString] : @"";
        }
        id date = KLGet(request, @"timestamp");
        double t = [date isKindOfClass:NSDate.class] ? [(NSDate *)date timeIntervalSince1970] : 0;
        if (!(t > 946684800.0) || !isfinite(t)) t = [[NSDate date] timeIntervalSince1970];     // none, or before 2000: now
        id content = KLGet(request, @"content");
        NSString *title = KLText(content, @"title");
        NSString *subtitle = KLText(content, @"subtitle");
        NSString *body = KLText(content, @"message");
        if (!body) body = KLText(content, @"body");
        dispatch_async(KLQueue(), ^{
            @autoreleasepool {
                @try { KLConsider(how, app, requestID, t, title, subtitle, body); }
                @catch (id e) { KLLog(@"error: a notification from %@ threw %@", app, KLWhy(e)); }
            }
        });
    } @catch (id e) {
        KLLog(@"error: reading a notification threw %@", KLWhy(e));
    }
}

#pragma mark - the hooks

static void (*KLOriginalPost)(id, SEL, id);
static void KLPost(id self, SEL _cmd, id request) {
    KLOriginalPost(self, _cmd, request);                // first, and unchanged
    KLObserve(request, @"post");
}

static void (*KLOriginalModify)(id, SEL, id);
static void KLModify(id self, SEL _cmd, id request) {
    KLOriginalModify(self, _cmd, request);              // first, and unchanged
    KLObserve(request, @"modify");
}

// An instance method replaced with the Objective-C runtime alone, as Shani does: an inherited
// method gets an override on this class, the class's own method gets the new code. Only a
// method of the expected shape (returns nothing, takes one object) is touched.
static BOOL KLHook(NSString *className, NSString *selName, IMP replacement, IMP *original) {
    Class cls = NSClassFromString(className);
    SEL sel = NSSelectorFromString(selName);
    Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!method) {
        KLLog(@"error: -[%@ %@] is not on this iOS: not hooked", className, selName);
        return NO;
    }
    char returns[16] = { 0 };
    char argument[16] = { 0 };
    method_getReturnType(method, returns, sizeof returns);
    method_getArgumentType(method, 2, argument, sizeof argument);
    if (method_getNumberOfArguments(method) != 3 || *KLBareType(returns) != 'v' || *KLBareType(argument) != '@') {
        KLLog(@"error: -[%@ %@] has an unexpected shape (returns %s, takes %s): not hooked", className, selName, returns, argument);
        return NO;
    }
    *original = method_getImplementation(method);
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(method))) {
        *original = method_setImplementation(class_getInstanceMethod(cls, sel), replacement);
    }
    return YES;
}

#pragma mark - start

static int gConfigToken;

__attribute__((constructor)) static void KuberaListenerInit(void) {
    @autoreleasepool {
        @try {
            if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
            BOOL post = KLHook(@"NCNotificationDispatcher", @"postNotificationWithRequest:", (IMP)KLPost, (IMP *)&KLOriginalPost);
            BOOL modify = KLHook(@"NCNotificationDispatcher", @"modifyNotificationWithRequest:", (IMP)KLModify, (IMP *)&KLOriginalModify);
            KLLog(@"loaded KuberaListener %@ into SpringBoard, hooks: post=%@ modify=%@", KL_VERSION, post ? @"YES" : @"NO",
                  modify ? @"YES" : @"NO");
            // Queued now, so it runs before any notification is looked at: SpringBoard only
            // starts posting them after this library is loaded.
            dispatch_async(KLQueue(), ^{
                @autoreleasepool {
                    @try { KLStart(); } @catch (id e) { KLLog(@"error: start threw %@", KLWhy(e)); }
                }
            });
            uint32_t status = notify_register_dispatch(KL_NOTE_CONFIG, &gConfigToken, KLQueue(), ^(__unused int token) {
                @autoreleasepool {
                    @try { KLLoadConfig(@"changed"); } @catch (id e) { KLLog(@"error: reading listener.json threw %@", KLWhy(e)); }
                }
            });
            if (status != NOTIFY_STATUS_OK) KLLog(@"error: cannot listen for %s (status %u)", KL_NOTE_CONFIG, status);
        } @catch (id e) {
            KLLog(@"error: start threw %@", KLWhy(e));
        }
    }
}
