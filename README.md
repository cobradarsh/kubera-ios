# Kubera

A personal money app for one iPhone 14 Pro Max on iOS 16.5 (jailbroken, TrollStore), default currency INR.

- **Expenses**: read from SMS (the Messages database itself), payment-app and Gmail notifications (through
  the companion tweak) and, optionally, Gmail over IMAP. Categorised automatically (built-in Indian merchant
  list, your own rules, free web lookups, then Claude with web search for whatever is left). A check-in at
  22:00 every day sorts what is still uncategorised. Several chart types.
- **Investments & trading**: daily profit/loss read from end-of-day screenshots of broker positions
  (Dhan, Kite, Kotak Neo, Upstox, Groww, Angel One) with on-device text recognition; months start on the 1st.
  NSE trading holidays and India's gazetted holidays.
- **Net worth**: bank and broker balances read from SMS plus anything added by hand, snapshotted on the 1st.

Salutations to Sri Venkateshwara, Goddess Lakshmi and Kubera open the app.

## Using it

1. Install `Kubera.ipa` with TrollStore and open it once: it reads every bank SMS already on the phone, then new
   ones whenever it comes to the front (and in background refresh when iOS allows).
2. Optional, for payments that send no SMS (GPay / BHIM / wallet notifications, Gmail alerts): install the
   **Kubera Listener** `.deb` (respring). More → "Apps to listen to" sets which apps it watches.
3. Optional, Gmail history: More → Gmail, your address and a Google **app password** (needs 2-Step Verification).
4. Optional, smarter sorting: More → Smart sorting → your city (for local shops on OpenStreetMap) and, if you want,
   a Claude API key.
5. Every day at 22:00 (More → Check-in) a notification lists what is still unsorted. Sorting a payment with
   "Remember" on makes a rule for that payee.
6. Trading: after the close, screenshot your positions (Dhan, Kite, Kotak Neo, Upstox, Groww, Angel One…).
   Invest → the screenshot is found and read; check the number and Save. Holdings screenshots update Net Worth.

## Layout

| Path | What |
|---|---|
| `App/` | The SwiftUI app (iOS 16.0+), compiled with plain `swiftc` by `build.sh`; no Xcode project |
| `App/Core/` | Models, store, parsing and categorising: Foundation only, so the tests build for macOS too |
| `App/Mail/` | Gmail IMAP reader (Network.framework) and MIME decoding |
| `App/Resources/` | `merchants.json` (the merchant list) and other data files |
| `Tweak/` | **Kubera Listener**, a SpringBoard tweak that writes payment notifications to an inbox the app reads |
| `tests/` | Logic tests run on every build (synthetic messages only; no real data ever goes in this repo) |
| `tools/phone.sh` | Install and test over SSH (`ssh iphone-root`) |

## How the app reads SMS

TrollStore keeps any entitlement. `App/app.entitlements` has `com.apple.private.security.no-sandbox`,
`com.apple.private.security.storage.Messages` (+ `MessagesMetaData`) and
`com.apple.private.security.container-required`. With these the app opens
`/var/mobile/Library/SMS/sms.db` read-only (`SQLITE_OPEN_READONLY`, `PRAGMA query_only`), reads messages newer
than the last ROWID it saw, and never writes to it. Checked on the phone (16.5, 20F66): without the storage
entitlement even root gets "Operation not permitted" on that folder; with it, it opens.

## Contract: tweak -> app notification inbox

Folder `/var/mobile/Library/Kubera/` on the real file system (SpringBoard runs as `mobile`; the app is
unsandboxed). 

- `inbox.jsonl` — appended by the tweak, one JSON object per line, UTF-8:
  `{"v":1,"id":"<request id>","app":"<bundle id>","t":<unix seconds>,"title":"…","subtitle":"…","body":"…"}`
  At 2 MB the tweak renames it to `inbox.1.jsonl` (replacing the old one) and starts a new file.
- `listener.json` — written by the app: `{"enabled":true,"apps":["com.google.paisa", …]}`. The tweak re-reads
  it when the Darwin notification `com.cobradarsh.kubera.listener` is posted (and at start). Without the file
  the tweak uses its built-in list of Indian payment, bank, broker and mail apps.
- Only notifications from listed apps whose text contains an amount (₹ / Rs / INR followed by a number) are
  written. Mail apps additionally need a transaction word (debited, credited, spent, paid, txn, UPI, card,
  A/c…), so personal mail never reaches the inbox.
- After each write the tweak posts `com.cobradarsh.kubera.inbox`; a running app ingests at once.
- Log (no message text): `/var/mobile/Library/Logs/KuberaListener.log`.

## Contract: Gmail reader

`App/Mail/GmailIMAP.swift`: read-only IMAP over TLS to imap.gmail.com:993 with the user's address and a Google
app password (kept in the Keychain). `GmailIMAPClient.fetch(query:sinceUID:uidValidity:limit:)` runs
`UID SEARCH X-GM-RAW` in `[Gmail]/All Mail` and returns `MailMessage { uid, date, from, subject, text }`
with MIME decoded to plain text. The app passes the text to the same parser as SMS.

## Build

CI (`.github/workflows/build.yml`, macOS runner): `tests/run.sh` (logic tests on the runner), then `build.sh`
(swiftc → `Kubera.app`, actool, ad hoc signature with the entitlements, zip → `Kubera.ipa`).
The tweak: `.github/workflows/tweak.yml` (RootHide Theos, gate on the versioned arm64e slice).

## Privacy

Everything stays on the phone. Exports happen only when you tap Export. Web lookups send a merchant's name
(and the city you set) — never a person's name, an account number or an amount. Claude receives the same
merchant names only, and only when you have put your own API key in Settings.
