// MailTests.swift - Kubera
// Checks for the IMAP response parser and the MIME decoder, on synthetic messages only. On macOS:
//   swiftc -O App/Mail/IMAPParser.swift App/Mail/MIMEDecoder.swift tests/MailTests.swift -o build-tests/mailtests
//   build-tests/mailtests
// Prints PASS/FAIL for each check and exits with status 1 when any fails.
// (@main rather than top-level code: with several input files only a file named main.swift may have that.)

import Foundation

final class Checker {
    private(set) var total = 0
    private(set) var failed = 0

    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        total += 1
        if ok {
            print("PASS  \(name)")
        } else {
            failed += 1
            let d = detail()
            print("FAIL  \(name)" + (d.isEmpty ? "" : "\n      \(d)"))
        }
    }

    func equal<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
        check(name, actual == expected, "got  \(String(reflecting: actual))\n      want \(String(reflecting: expected))")
    }

    func run(_ group: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            check("\(group): no error thrown", false, "\(error)")
        }
    }
}

func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

/// LF line ends (as in the Swift literals below) to CRLF, as on the wire.
func crlf(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: "\r\n") }

/// A message from header lines and a body, with CRLF and the blank line between them.
func message(_ headers: [String], _ body: String) -> String {
    headers.joined(separator: "\r\n") + "\r\n\r\n" + body
}

func decodeMail(_ raw: String, internalDate: Date? = nil) -> MailMessage {
    MIMEDecoder.decode(Data(raw.utf8), uid: 1, internalDate: internalDate)
}

/// Feeds `wire` to a framer `chunkSize` bytes at a time, as reads from the socket would.
func responses(_ wire: [UInt8], chunkSize: Int) throws -> [IMAPResponse] {
    var framer = IMAPResponseFramer()
    var out: [IMAPResponse] = []
    var i = 0
    while i < wire.count {
        framer.append(Array(wire[i..<min(i + chunkSize, wire.count)]))
        while let r = try framer.next() {
            out.append(try IMAPParser.parseResponse(r))
        }
        i += chunkSize
    }
    return out
}

func parse(_ s: String) throws -> IMAPResponse {
    guard let r = try responses(bytes(s), chunkSize: 1 << 16).first else { throw IMAPParseError("no response") }
    return r
}

func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

func testFramer(_ t: Checker) {
    t.run("framer") {
        let wire = bytes("* 1 FETCH (UID 7 INTERNALDATE \" 5-Nov-2026 10:15:30 +0530\" BODY[]<0> {11}\r\nHi\r\nthere\r\n)\r\nK1 OK Success\r\n")
        for size in [1, 2, 3, 7, 50, wire.count] {
            let rs = try responses(wire, chunkSize: size)
            t.equal("framer: literal split over \(size)-byte reads gives 2 responses", rs.count, 2)
            guard rs.count == 2 else { continue }
            t.equal("framer: literal intact after \(size)-byte reads", IMAPParser.fetchResult(rs[0])?.body ?? Data(),
                    Data("Hi\r\nthere\r\n".utf8))
            t.check("framer: tagged reply after \(size)-byte reads", rs[1].kind == .tagged("K1") && rs[1].status == "OK")
        }
        let tricky = try responses(bytes("* 2 FETCH (UID 8 BODY[] {8}\r\na {5}\r\nb)\r\n"), chunkSize: 1)
        t.equal("framer: '{5}' CRLF inside a literal is data", tricky.count, 1)
        t.equal("framer: literal with braces and CRLF", tricky.first.flatMap { IMAPParser.fetchResult($0) }?.body ?? Data(),
                Data("a {5}\r\nb".utf8))
        let several = try responses(bytes("* 2 EXISTS\r\n* 0 RECENT\r\nK2 OK [READ-ONLY] EXAMINE completed\r\n"), chunkSize: 4096)
        t.equal("framer: three responses in one read", several.count, 3)
        t.check("framer: response code and text", several.last?.code == "READ-ONLY" && several.last?.text == "EXAMINE completed")
    }
}

func testFetch(_ t: Checker) {
    t.run("fetch") {
        let mail = bytes(crlf("From: \"Example Bank\" <alerts@example-bank.test>\nSubject: Alert\n\nINR 10.00 debited\n"))
        var wire = bytes("* 3 FETCH (UID 1001 BODY[]<0> {\(mail.count)}\r\n")
        wire += mail
        wire += bytes(" INTERNALDATE \"05-Nov-2026 10:15:30 +0530\" FLAGS (\\Seen))\r\n")
        let rs = try responses(wire, chunkSize: 4096)
        guard rs.count == 1, let f = IMAPParser.fetchResult(rs[0]) else {
            t.check("FETCH: parsed", false, "\(rs)")
            return
        }
        t.equal("FETCH: sequence number", f.sequence, 3)
        t.equal("FETCH: UID", f.uid ?? 0, 1001)
        t.equal("FETCH: body literal", f.body.map { [UInt8]($0) } ?? [], mail)
        t.equal("FETCH: INTERNALDATE", f.internalDate, utc(2026, 11, 5, 4, 45, 30))
        t.equal("INTERNALDATE with a space-padded day", IMAPParser.parseInternalDate(" 5-Nov-2026 10:15:30 +0530"),
                utc(2026, 11, 5, 4, 45, 30))
        let m = MIMEDecoder.decode(f.body ?? Data(), uid: f.uid ?? 0, internalDate: f.internalDate)
        t.equal("FETCH -> MailMessage", m, MailMessage(uid: 1001, date: utc(2026, 11, 5, 4, 45, 30),
                                                       from: "Example Bank <alerts@example-bank.test>",
                                                       subject: "Alert", text: "INR 10.00 debited"))
    }
}

func testResponses(_ t: Checker) {
    t.run("responses") {
        let search = try parse("* SEARCH 3 10 42\r\n")
        t.equal("SEARCH: UIDs", IMAPParser.searchResults(search) ?? [], [3, 10, 42])
        let none = try parse("* SEARCH\r\n")
        t.equal("SEARCH: no matches", IMAPParser.searchResults(none) ?? [99], [])
        let modseq = try parse("* SEARCH 5 6 (MODSEQ 917162500)\r\n")
        t.equal("SEARCH: MODSEQ ignored", IMAPParser.searchResults(modseq) ?? [], [5, 6])
        let exists = try parse("* 5 EXISTS\r\n")
        t.check("SEARCH: other responses are not search results", IMAPParser.searchResults(exists) == nil)

        let all = try parse("* LIST (\\HasNoChildren \\All) \"/\" \"[Gmail]/All Mail\"\r\n")
        let box = IMAPParser.listResult(all)
        t.equal("LIST: name", box?.name ?? "", "[Gmail]/All Mail")
        t.check("LIST: \\All attribute", box?.hasAttribute("\\All") == true)
        t.equal("LIST: delimiter", box?.delimiter ?? "", "/")
        let parent = try parse("* LIST (\\HasChildren \\Noselect) \"/\" \"[Gmail]\"\r\n")
        t.check("LIST: no \\All on [Gmail]", IMAPParser.listResult(parent)?.hasAttribute("\\All") == false)
        let literalName = try parse("* LIST (\\HasNoChildren \\All) \"/\" {12}\r\n[Gmail]/Tous\r\n")
        t.equal("LIST: name sent as a literal", IMAPParser.listResult(literalName)?.name ?? "", "[Gmail]/Tous")
        let inbox = try parse("* LIST (\\HasNoChildren) \"/\" INBOX\r\n")
        t.equal("LIST: atom name", IMAPParser.listResult(inbox)?.name ?? "", "INBOX")

        let validity = try parse("* OK [UIDVALIDITY 654321] UIDs valid.\r\n")
        t.equal("UIDVALIDITY", IMAPParser.uidValidity(validity) ?? 0, 654321)
        t.equal("status text", validity.text, "UIDs valid.")
        let no = try parse("K5 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n")
        t.check("tagged NO with code", no.kind == .tagged("K5") && no.status == "NO" && no.code == "AUTHENTICATIONFAILED")
        t.equal("tagged NO text", no.text, "Invalid credentials (Failure)")
        let plus = try parse("+ go ahead\r\n")
        t.check("continuation", plus.kind == .continuation && plus.text == "go ahead")
        let bare = try parse("+\r\n")
        t.check("bare continuation", bare.kind == .continuation && bare.text.isEmpty)
        let caps = try parse("* CAPABILITY IMAP4rev1 SASL-IR AUTH=PLAIN AUTH=XOAUTH2\r\n")
        t.check("CAPABILITY", IMAPParser.capabilities(caps)?.isSuperset(of: ["SASL-IR", "AUTH=PLAIN"]) == true)
        let codeCaps = try parse("* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN] Ready\r\n")
        t.check("CAPABILITY in a response code", IMAPParser.capabilities(codeCaps)?.contains("AUTH=PLAIN") == true)

        let query = "after:2026/11/01 subject:(\"transaction alert\") a\\b"
        let quoted = IMAPParser.quoted(query)
        t.equal("quoting: \\ and \" escaped", quoted ?? "", "\"after:2026/11/01 subject:(\\\"transaction alert\\\") a\\\\b\"")
        let back = try parse("* LIST () \"/\" " + (quoted ?? "\"\"") + "\r\n")
        t.equal("quoting: parses back to the same text", IMAPParser.listResult(back)?.name ?? "", query)
        t.check("quoting: non-ASCII needs a literal", IMAPParser.quoted("₹ alert") == nil)
        t.check("quoting: CR LF needs a literal", IMAPParser.quoted("a\r\nb") == nil)
    }
}

func testHeaders(_ t: Checker) {
    let b = Data("₹500 debited".utf8).base64EncodedString()
    t.equal("RFC 2047: B, UTF-8", MIMEDecoder.decodeEncodedWords("=?UTF-8?B?\(b)?="), "₹500 debited")
    t.equal("RFC 2047: Q, UTF-8 with ₹", MIMEDecoder.decodeEncodedWords("=?utf-8?Q?=E2=82=B9_1=2C234=2E00_spent?="),
            "₹ 1,234.00 spent")
    t.equal("RFC 2047: adjacent words, a character split across them",
            MIMEDecoder.decodeEncodedWords("Alert: =?UTF-8?Q?Paid_=E2=82?= =?UTF-8?Q?=B9500?= today"), "Alert: Paid ₹500 today")
    t.equal("RFC 2047: ISO-8859-1", MIMEDecoder.decodeEncodedWords("=?ISO-8859-1?Q?Caf=E9_bill?="), "Café bill")
    let hello = Data("hello".utf8).base64EncodedString()
    t.equal("RFC 2047: lower-case b, language suffix", MIMEDecoder.decodeEncodedWords("=?utf-8*en?b?\(hello)?="), "hello")
    t.equal("RFC 2047: two charsets side by side", MIMEDecoder.decodeEncodedWords("=?UTF-8?Q?A?= =?ISO-8859-1?Q?=E9?="), "Aé")
    t.equal("RFC 2047: other text untouched", MIMEDecoder.decodeEncodedWords("Rate =?% today"), "Rate =?% today")
    t.equal("From: quoted name", MIMEDecoder.formatAddress("\"Example Bank\" <alerts@example-bank.test>"),
            "Example Bank <alerts@example-bank.test>")
    t.equal("From: encoded name", MIMEDecoder.formatAddress("=?UTF-8?Q?Example_Bank_Alerts?= <alerts@example-bank.test>"),
            "Example Bank Alerts <alerts@example-bank.test>")
    t.equal("From: bare address", MIMEDecoder.formatAddress("alerts@example-bank.test"), "alerts@example-bank.test")
}

func testBodies(_ t: Checker) {
    let qp = "Rs.500.00 spent at EXAMPLE MA=\r\nRT. Avl Lmt: =E2=82=B9 12,000=\r\n.00\r\nLine two=20\r\nsoft with space= \r\nend =e2=82=b9"
    t.equal("QP: soft breaks, =E2=82=B9, lower-case hex",
            String(decoding: MIMEDecoder.decodeQuotedPrintable(bytes(qp)), as: UTF8.self),
            "Rs.500.00 spent at EXAMPLE MART. Avl Lmt: ₹ 12,000.00\r\nLine two \r\nsoft with spaceend ₹")
    let qpMail = message(["From: alerts@example-bank.test", "Subject: Card alert", "Content-Type: text/plain; charset=utf-8",
                          "Content-Transfer-Encoding: quoted-printable"], qp)
    t.equal("QP message to text", decodeMail(qpMail).text,
            "Rs.500.00 spent at EXAMPLE MART. Avl Lmt: ₹ 12,000.00\nLine two\nsoft with spaceend ₹")

    let plainBody = "Dear Customer,\nINR 2,500.00 credited to A/c XX9876 on 05-Nov-26.\n₹ symbol ok"
    let wrapped = Data(plainBody.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn,
                                                                      .endLineWithLineFeed])
    t.check("base64 test body wraps", wrapped.contains("\r\n"))
    let b64Mail = message(["From: alerts@example-bank.test", "Subject: Credit", "Content-Type: text/plain; charset=UTF-8",
                           "Content-Transfer-Encoding: base64"], wrapped + "\r\n")
    let credit = decodeMail(b64Mail)
    t.equal("base64 body", credit.text, plainBody)
    t.equal("bare From address", credit.from, "alerts@example-bank.test")

    let flat = Data(plainBody.utf8).base64EncodedString()
    let cut = message(["Content-Type: multipart/alternative; boundary=\"b1\""],
                      crlf("--b1\nContent-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: base64\n\n")
                        + String(flat.prefix(50)))
    let cutText = decodeMail(cut).text
    t.check("cut-off message: no closing boundary, base64 cut mid-group", cutText.hasPrefix("Dear Customer,\nINR 2,500.00"), cutText)

    var cp1252 = bytes("Paid ")
    cp1252.append(0x80)
    cp1252 += bytes("50 at Caf")
    cp1252.append(0xE9)
    cp1252 += bytes(" ")
    cp1252.append(0x96)
    cp1252 += bytes(" thanks")
    cp1252.append(0x92)
    cp1252 += bytes("s")
    for charset in ["windows-1252", "iso-8859-1"] {
        var raw = bytes(message(["Subject: x", "Content-Type: text/plain; charset=\(charset)", "Content-Transfer-Encoding: 8bit"], ""))
        raw += cp1252
        t.equal("charset \(charset)", MIMEDecoder.decode(Data(raw), uid: 1, internalDate: nil).text, "Paid €50 at Café – thanks’s")
    }
    t.equal("charset: ISO-8859-1 bytes labelled UTF-8", MIMEDecoder.decodeText(bytes("Caf") + [0xE9], charset: "utf-8"), "Café")
    t.equal("charset: UTF-8 cut inside the last character",
            MIMEDecoder.decodeText(Array(bytes("Total ₹5, now ₹").dropLast()), charset: "utf-8"), "Total ₹5, now ")
    t.equal("charset: undeclared UTF-8", MIMEDecoder.decodeText(bytes("₹ 10"), charset: nil), "₹ 10")

    let flowed = message(["Content-Type: text/plain; charset=utf-8; format=flowed"],
                         "Your a/c XX12 is debited \r\nfor Rs 10.00 on 05-Nov.\r\n\r\n-- \r\nExample Bank\r\n")
    t.equal("format=flowed", decodeMail(flowed).text, "Your a/c XX12 is debited for Rs 10.00 on 05-Nov.\n\n--\nExample Bank")
}

func testMultipart(_ t: Checker) {
    let nested = crlf("""
        From: Example Bank <alerts@example-bank.test>
        Subject: Transaction alert
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="outer-1"

        This is a multi-part message in MIME format.
        --outer-1
        Content-Type: multipart/alternative; boundary=inner-2

        --inner-2
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: 7bit

        Your card XX1111 was used for INR 349.00 at EXAMPLE CAFE.
        --inner-2
        Content-Type: text/html; charset=utf-8

        <p>Your card XX1111 was used for <b>INR 349.00</b> at EXAMPLE CAFE.</p>
        --inner-2--
        --outer-1
        Content-Type: application/pdf; name="statement.pdf"
        Content-Disposition: attachment; filename="statement.pdf"
        Content-Transfer-Encoding: base64

        JVBERi0xLjQK
        --outer-1--
        """)
    let n = decodeMail(nested)
    t.equal("multipart/alternative in multipart/mixed: text/plain chosen", n.text,
            "Your card XX1111 was used for INR 349.00 at EXAMPLE CAFE.")
    t.equal("multipart: subject and from", n.subject + " | " + n.from, "Transaction alert | Example Bank <alerts@example-bank.test>")

    let placeholder = crlf("""
        Subject: Debit
        Content-Type: multipart/alternative; boundary=zz

        --zz
        Content-Type: text/plain

        Please view this message in an HTML capable viewer.
        --zz
        Content-Type: text/html

        <p>Rs 75.00 debited</p>
        --zz--
        """)
    t.equal("multipart: placeholder text/plain loses to the HTML part", decodeMail(placeholder).text, "Rs 75.00 debited")

    let prefix = crlf("""
        Content-Type: multipart/mixed; boundary="b"

        --b
        Content-Type: multipart/alternative; boundary="b-2"

        --b-2
        Content-Type: text/plain

        Rs 1.00 paid
        --b-2--
        --b--
        """)
    t.equal("multipart: boundary that prefixes a nested one", decodeMail(prefix).text, "Rs 1.00 paid")

    let mislabelled = message(["Content-Type: text/plain; charset=us-ascii"],
                              "<html><body><p>INR 5.00 spent at <b>SHOP</b></p></body></html>\r\n")
    t.equal("text/plain that is really HTML", decodeMail(mislabelled).text, "INR 5.00 spent at SHOP")
}

func testHTML(_ t: Checker) {
    let w1 = Data("₹1,234 debited ".utf8).base64EncodedString()
    let w2 = Data("via UPI".utf8).base64EncodedString()
    let alert = crlf("""
        From: "Example Bank Alerts" <alerts@example-bank.test>
        Subject: =?UTF-8?B?\(w1)?=
         =?UTF-8?B?\(w2)?=
        Date: Thu, 5 Nov 2026 10:15:30 +0530 (IST)
        MIME-Version: 1.0
        Content-Type: text/html; charset="UTF-8"
        Content-Transfer-Encoding: quoted-printable

        <html><head><style>td { font-size: 12px; }</style><title>Alert</title></head>
        <body><table>
        <tr><td style=3D"padding:4px">Dear Customer,</td></tr>
        <tr><td>Rs.1,234.00 has been debited from account **1234 to VPA abc@ybl EXA=
        MPLE STORE on 05-11-26. Your UPI transaction reference number is 6123456789=
        01.</td></tr>
        <tr><td>Amount:</td><td>&#8377;&nbsp;1,234.00</td></tr>
        <tr><td>Balance:</td><td>&#x20B9; 10,000.50 &amp; more</td></tr>
        </table>
        <!-- tracking -->
        <script>var x =3D "<b>no</b>";</script>
        <p>Regards,<br/>Example&nbsp;Bank</p>
        <div>Fee: &rupee;0 =E2=80=8B</div>
        </body></html>
        """)
    let a = decodeMail(alert)
    t.equal("HTML-only bank alert to clean text", a.text, """
        Dear Customer,
        Rs.1,234.00 has been debited from account **1234 to VPA abc@ybl EXAMPLE STORE on 05-11-26. Your UPI transaction reference number is 612345678901.
        Amount: ₹ 1,234.00
        Balance: ₹ 10,000.50 & more
        Regards,
        Example Bank
        Fee: ₹0
        """)
    t.equal("HTML alert: folded encoded-word subject", a.subject, "₹1,234 debited via UPI")
    t.equal("HTML alert: from", a.from, "Example Bank Alerts <alerts@example-bank.test>")
    t.equal("HTML alert: Date header used without INTERNALDATE", a.date, utc(2026, 11, 5, 4, 45, 30))
    t.equal("HTML entities", MIMEDecoder.htmlToText("A&amp;B &lt;tag&gt; &#8377;5 &#x20b9;6 &rupee;7 &nbsp;x&copy y &unknown; &#150;"),
            "A&B <tag> ₹5 ₹6 ₹7 x© y &unknown; –")

    t.run("codable") {
        let m = MailMessage(uid: 5, date: utc(2026, 11, 5, 4, 45, 30), from: "a@example.test", subject: "s", text: "₹1")
        let json = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(MailMessage.self, from: json)
        t.equal("MailMessage Codable round trip", back, m)
    }
}

@main
struct MailTests {
    static func main() {
        let t = Checker()
        testFramer(t)
        testFetch(t)
        testResponses(t)
        testHeaders(t)
        testBodies(t)
        testMultipart(t)
        testHTML(t)
        print("\n\(t.total - t.failed) of \(t.total) checks passed")
        exit(t.failed == 0 ? 0 : 1)
    }
}
