import Foundation

/// What a lookup found for one payee.
struct LookupAnswer {
    var category: String?
    var confident: Bool
    var person: Bool
    var name: String?
    var note: String?
}

/// Turns a description from the web ("an Indian online food ordering platform") into a category.
enum DescriptionClassifier {
    static let table: [(String, [String])] = [
        ("groceries", ["grocery", "groceries", "supermarket", "hypermarket", "quick commerce", "kirana", "dairy", "vegetables", "fruits", "meat shop", "butcher", "convenience store", "convenience"]),
        ("food", ["restaurant", "food delivery", "food ordering", "cafe", "café", "coffee", "bakery", "fast food", "fast_food", "eatery", "cuisine", "dine", "dining", "pizza", "burger", "ice cream", "ice_cream", "sweet shop", "confectionery", "food court", "bar", "pub", "brewery", "biryani", "tea shop", "juice"]),
        ("health", ["pharmacy", "chemist", "hospital", "clinic", "diagnostic", "pathology", "medical", "healthcare", "doctors", "dentist", "optician", "laboratory"]),
        ("fuel", ["fuel", "petrol", "filling station", "gas station", "petroleum"]),
        ("transport", ["ride-hailing", "ride hailing", "taxi", "cab", "bike taxi", "metro", "parking", "toll", "car rental", "bicycle rental"]),
        ("travel", ["airline", "hotel", "hostel", "resort", "travel agency", "online travel", "railway", "bus operator", "guest house", "motel", "tourism"]),
        ("subscriptions", ["streaming", "subscription", "software", "saas", "cloud storage", "news app", "music streaming", "video on demand", "newspaper"]),
        ("entertainment", ["cinema", "movie theatre", "multiplex", "theme park", "amusement", "gaming", "video game", "event ticket", "bowling", "arcade", "theatre"]),
        ("bills", ["telecommunications", "telecom", "mobile network", "internet service provider", "broadband", "electricity", "power distribution", "utility", "water supply", "gas distribution", "dth"]),
        ("shopping", ["e-commerce", "ecommerce", "online marketplace", "retailer", "retail", "clothing", "apparel", "fashion", "electronics", "department store", "jewellery", "jewelry", "footwear", "furniture store", "hardware store", "bookstore", "books", "stationery", "toy", "mobile phone", "shop", "boutique", "mall"]),
        ("home", ["home services", "real estate", "property", "rental", "interior", "furniture rental", "housekeeping", "plumber", "pest control"]),
        ("education", ["school", "college", "university", "education", "edtech", "coaching", "tutoring", "academy", "e-learning"]),
        ("personal", ["salon", "spa", "beauty", "barber", "gym", "fitness", "wellness", "hairdresser", "cosmetics"]),
        ("insurance", ["insurance", "insurer"]),
        ("emi", ["non-banking financial", "nbfc", "lender", "lending", "loan", "microfinance", "buy now pay later"]),
        (Category.investments, ["stockbroker", "brokerage", "broker", "mutual fund", "asset management", "wealth management", "depository", "clearing corporation", "stock exchange"]),
        ("donations", ["temple", "charity", "non-profit", "nonprofit", "ngo", "religious", "trust", "foundation", "church", "mosque"]),
    ]

    static let personWords = ["given name", "surname", "family name", "masculine name", "feminine name", "is a name", "personal name", "indian name", "first name"]

    static func classify(_ text: String) -> (category: String?, person: Bool, score: Int) {
        let l = text.lowercased()
        if personWords.contains(where: { l.contains($0) }) { return (nil, true, 3) }
        var best: (String, Int)?
        for (cat, words) in table {
            var s = 0
            for w in words where l.contains(w) { s += w.count > 6 ? 2 : 1 }
            if s > 0 && (best == nil || s > best!.1) { best = (cat, s) }
        }
        return (best?.0, false, best?.1 ?? 0)
    }

    /// OpenStreetMap tags: amenity=restaurant, shop=supermarket, …
    static func classifyOSM(category: String, type: String) -> String? {
        let key = category.lowercased(), v = type.lowercased()
        switch (key, v) {
        case ("amenity", "restaurant"), ("amenity", "cafe"), ("amenity", "fast_food"), ("amenity", "food_court"), ("amenity", "ice_cream"),
             ("amenity", "bar"), ("amenity", "pub"), ("shop", "bakery"), ("shop", "confectionery"), ("shop", "pastry"), ("shop", "beverages"):
            return "food"
        case ("shop", "supermarket"), ("shop", "convenience"), ("shop", "greengrocer"), ("shop", "butcher"), ("shop", "dairy"), ("shop", "general"), ("shop", "grocery"), ("shop", "seafood"):
            return "groceries"
        case ("amenity", "pharmacy"), ("amenity", "hospital"), ("amenity", "clinic"), ("amenity", "doctors"), ("amenity", "dentist"), ("shop", "chemist"), ("shop", "optician"), ("healthcare", _):
            return "health"
        case ("amenity", "fuel"): return "fuel"
        case ("amenity", "cinema"), ("amenity", "theatre"), ("leisure", _): return "entertainment"
        case ("tourism", "hotel"), ("tourism", "hostel"), ("tourism", "guest_house"), ("tourism", "motel"), ("tourism", "resort"): return "travel"
        case ("amenity", "place_of_worship"): return "donations"
        case ("amenity", "school"), ("amenity", "college"), ("amenity", "university"), ("amenity", "kindergarten"): return "education"
        case ("shop", "hairdresser"), ("shop", "beauty"), ("leisure", "fitness_centre"): return "personal"
        case ("amenity", "parking"), ("amenity", "taxi"): return "transport"
        case ("shop", _): return "shopping"
        default: return nil
        }
    }
}

/// Free lookups, in order: Wikipedia, DuckDuckGo's instant answers, OpenStreetMap (with your city).
/// Only business names are ever sent (never a person, an account number or an amount).
struct FreeLookup {
    var city: String
    var session: URLSession = .shared

    static let userAgent = "Kubera-iOS/1.0 (personal expense app)"

    func lookup(_ name: String) async -> LookupAnswer? {
        let q = Self.searchText(name)
        guard q.count >= 3 else { return nil }
        if let a = await wikipedia(q), a.category != nil || a.person { return a }
        if let a = await duckduckgo(q), a.category != nil || a.person { return a }
        if !city.trimmed.isEmpty, let a = await openStreetMap(q) { return a }
        return nil
    }

    /// "PAWAN ELECTRICALS AND LIG" -> "Pawan Electricals And"; strips legal suffixes and stray characters.
    static func searchText(_ name: String) -> String {
        var words = MerchantDB.normalize(name).split(separator: " ").map(String.init)
        let drop: Set<String> = ["pvt", "private", "ltd", "limited", "llp", "inc", "co", "rsp", "pos", "upi", "ecom", "www", "com", "in"]
        words.removeAll { drop.contains($0) }
        if words.count > 1, let last = words.last, last.count <= 3 { words.removeLast() } // truncated word
        return words.joined(separator: " ").capitalized
    }

    private func getJSON(_ url: URL) async -> Any? {
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func wikipedia(_ q: String) async -> LookupAnswer? {
        var c = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        c.queryItems = [
            .init(name: "action", value: "query"), .init(name: "list", value: "search"), .init(name: "srsearch", value: q + " India"),
            .init(name: "srlimit", value: "3"), .init(name: "format", value: "json"), .init(name: "srprop", value: "snippet"),
        ]
        guard let url = c.url, let j = await getJSON(url) as? [String: Any],
              let query = j["query"] as? [String: Any], let hits = query["search"] as? [[String: Any]] else { return nil }
        let qWords = Set(MerchantDB.normalize(q).split(separator: " ").map(String.init))
        for h in hits {
            let title = h["title"] as? String ?? ""
            let tWords = Set(MerchantDB.normalize(title).split(separator: " ").map(String.init))
            // The page must be about this name, not just mention it.
            guard !qWords.isEmpty, qWords.intersection(tWords).count * 2 >= qWords.count else { continue }
            let snippet = (h["snippet"] as? String ?? "").replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            let r = DescriptionClassifier.classify(snippet)
            if r.person { return LookupAnswer(category: nil, confident: false, person: true, name: nil, note: "Wikipedia: a personal name") }
            if let cat = r.category {
                return LookupAnswer(category: cat, confident: r.score >= 2, person: false, name: title,
                                    note: "Wikipedia: " + String(snippet.prefix(120)))
            }
        }
        return nil
    }

    private func duckduckgo(_ q: String) async -> LookupAnswer? {
        var c = URLComponents(string: "https://api.duckduckgo.com/")!
        c.queryItems = [.init(name: "q", value: q), .init(name: "format", value: "json"), .init(name: "no_html", value: "1"), .init(name: "skip_disambig", value: "1")]
        guard let url = c.url, let j = await getJSON(url) as? [String: Any] else { return nil }
        let abstract = j["AbstractText"] as? String ?? ""
        let heading = j["Heading"] as? String ?? ""
        var text = abstract
        if text.isEmpty, let topics = j["RelatedTopics"] as? [[String: Any]], let first = topics.first?["Text"] as? String { text = first }
        guard !text.isEmpty else { return nil }
        let r = DescriptionClassifier.classify(text)
        if r.person { return LookupAnswer(category: nil, confident: false, person: true, name: nil, note: "DuckDuckGo: a personal name") }
        guard let cat = r.category else { return nil }
        return LookupAnswer(category: cat, confident: r.score >= 2 && !abstract.isEmpty, person: false,
                            name: heading.isEmpty ? nil : heading, note: "DuckDuckGo: " + String(text.prefix(120)))
    }

    private func openStreetMap(_ q: String) async -> LookupAnswer? {
        var c = URLComponents(string: "https://nominatim.openstreetmap.org/search")!
        c.queryItems = [.init(name: "q", value: q + ", " + city), .init(name: "format", value: "jsonv2"),
                        .init(name: "limit", value: "3"), .init(name: "countrycodes", value: "in")]
        guard let url = c.url, let arr = await getJSON(url) as? [[String: Any]] else { return nil }
        for r in arr {
            let cat = r["category"] as? String ?? "", type = r["type"] as? String ?? ""
            if let mapped = DescriptionClassifier.classifyOSM(category: cat, type: type) {
                let name = (r["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return LookupAnswer(category: mapped, confident: true, person: false, name: name,
                                    note: "OpenStreetMap: \(cat)=\(type) in \(city)")
            }
        }
        return nil
    }
}

/// Claude with web search, for the payees free lookups could not place. Batched; your own API key.
struct ClaudeLookup {
    var apiKey: String
    var model: String
    var city: String
    var categories: [Category]
    var session: URLSession = .shared

    struct Item: Codable { var key: String; var name: String }
    struct Result: Codable { var key: String; var category: String; var confidence: String; var reason: String; var display_name: String }

    enum Failure: Error, LocalizedError {
        case http(Int, String), refused, badResponse(String)
        var errorDescription: String? {
            switch self {
            case let .http(code, msg): return "Claude API error \(code): \(msg)"
            case .refused: return "Claude declined the request"
            case let .badResponse(m): return "Unexpected answer from Claude: \(m)"
            }
        }
    }

    func categorize(_ items: [Item]) async throws -> [Result] {
        guard !items.isEmpty else { return [] }
        let ids = categories.filter { $0.id != Category.uncategorized && $0.kind != .income }.map { $0.id }
        let catList = categories.filter { ids.contains($0.id) }.map { "\($0.id) = \($0.name)" }.joined(separator: "\n")
        let system = """
        You categorise payees from an Indian user's bank alerts (SMS) into spending categories. Payee names are often \
        truncated at 25 characters, upper-cased, or a payment-gateway / legal-entity name (e.g. "BUNDL TECHNOLOGIES" is \
        Swiggy). Search the web when you are not sure what a business is. The user lives in \(city.isEmpty ? "India" : city + ", India").
        Allowed category ids:
        \(catList)
        For each payee return the category id, confidence "high" only when you know what the business sells, a short \
        reason, and the business's usual display name (or the cleaned-up name if unknown). If a payee is clearly a \
        private person, use "people".
        """
        let payload = try String(data: JSONEncoder().encode(items), encoding: .utf8) ?? "[]"
        let itemProperties: [String: Any] = [
            "key": ["type": "string"] as [String: Any],
            "category": ["type": "string", "enum": ids] as [String: Any],
            "confidence": ["type": "string", "enum": ["high", "low"]] as [String: Any],
            "reason": ["type": "string"] as [String: Any],
            "display_name": ["type": "string"] as [String: Any],
        ]
        let itemSchema: [String: Any] = [
            "type": "object",
            "properties": itemProperties,
            "required": ["key", "category", "confidence", "reason", "display_name"],
            "additionalProperties": false,
        ]
        let resultsSchema: [String: Any] = ["type": "array", "items": itemSchema]
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["results": resultsSchema] as [String: Any],
            "required": ["results"],
            "additionalProperties": false,
        ]
        let tool: [String: Any] = ["type": "web_search_20260209", "name": "web_search", "max_uses": 6]
        let format: [String: Any] = ["type": "json_schema", "schema": schema]
        let outputConfig: [String: Any] = ["effort": "low", "format": format]
        var messages: [[String: Any]] = [["role": "user", "content": "Categorise these payees (JSON):\n" + payload]]
        for _ in 0..<3 {
            let body: [String: Any] = [
                "model": model,
                "max_tokens": 16000,
                "system": system,
                "tools": [tool],
                "output_config": outputConfig,
                "fallbacks": "default",
                "messages": messages,
            ]
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 180)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.badResponse("not JSON") }
            guard code == 200 else {
                let msg = ((j["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(code)"
                throw Failure.http(code, msg)
            }
            let stop = j["stop_reason"] as? String ?? ""
            let content = j["content"] as? [[String: Any]] ?? []
            if stop == "refusal" { throw Failure.refused }
            if stop == "pause_turn" {
                // The server's tool loop paused: send its turn back as it is and let it continue.
                messages.append(["role": "assistant", "content": content])
                continue
            }
            guard let text = content.last(where: { ($0["type"] as? String) == "text" })?["text"] as? String,
                  let d = text.data(using: .utf8) else { throw Failure.badResponse("no text") }
            struct Wrapper: Codable { var results: [Result] }
            return try JSONDecoder().decode(Wrapper.self, from: d).results
        }
        throw Failure.badResponse("paused too many times")
    }
}
