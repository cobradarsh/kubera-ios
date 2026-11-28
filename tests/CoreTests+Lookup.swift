import Foundation

// Synthetic data only: never put real messages, names, amounts or accounts here.

extension CoreTests {
    static func extraLookupTests() {
        print("\n# lookups (review fixes)")

        // Free lookups never send a word with a digit (phone, account or reference numbers).
        check(FreeLookup.searchText("DEMO TRADERS 1234567890") == "Demo Traders", "lookup text drops a phone-like number")
        check(FreeLookup.searchText("SAMPLE STORES Q123456789") == "Sample Stores", "lookup text drops a code with digits")

        // Claude gets short ids and names, never the payee keys (a key can hold a UPI ID).
        let items = [ClaudeLookup.Item(key: "vpa:demo.shop42@okexample", name: "DEMO TRADERS"),
                     ClaudeLookup.Item(key: "name:sample bakers", name: "SAMPLE BAKERS")]
        guard let m = try? ClaudeLookup.payeeMessage(items) else {
            check(false, "Claude payee list builds")
            return
        }
        check(m.keys["p0"] == "vpa:demo.shop42@okexample" && m.keys["p1"] == "name:sample bakers", "short ids map to the payee keys")
        check(m.text.contains("\"p0\"") && m.text.contains("\"p1\"") && m.text.contains("DEMO TRADERS"), "Claude list has the short ids and names")

        let c = ClaudeLookup(apiKey: "test", model: "claude-opus-5-5", city: "Testpur", categories: Category.builtIns)
        let first = c.requestBody(messages: [["role": "user", "content": m.text]], ids: ["p0", "p1"], container: nil)
        let sent = (try? JSONSerialization.data(withJSONObject: first)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check(!sent.isEmpty && !sent.contains("vpa:") && !sent.contains("demo.shop42") && !sent.contains("@"), "Claude request holds no UPI ID")
        check(first["container"] == nil, "first Claude request names no container")
        let resumed = c.requestBody(messages: [], ids: ["p0"], container: "container_test_1")
        check(resumed["container"] as? String == "container_test_1", "a paused turn resumes in the same container")

        let answer = #"{"results":[{"key":"p1","category":"food","confidence":"high","reason":"a bakery","display_name":"Sample Bakers"},"# +
            #"{"key":"p7","category":"food","confidence":"low","reason":"not sent","display_name":"Other"}]}"#
        let back = (try? ClaudeLookup.results(from: answer, keys: m.keys)) ?? []
        check(back.count == 1 && back.first?.key == "name:sample bakers" && back.first?.category == "food",
              "Claude answers map back to payee keys; an id that was not sent is dropped")
    }
}
