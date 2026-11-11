import CoreGraphics
import Foundation
import Vision

/// Foto im Food-Check: Apples Bilderkennung läuft auf dem Gerät, das Foto verlässt das Telefon nicht.
/// Sie liefert englische Begriffe („banana“); hier wird daraus ein Suchbegriff für die eigene Liste.
enum FoodPhoto {
    /// Bezeichner der Bilderkennung → deutscher Suchbegriff. Bewusst ein Suchbegriff und kein fester Eintrag:
    /// „Apfel“ zeigt mit und ohne Kerne, „Kastanie“ Ess- und Rosskastanie. Was hier fehlt, wird nicht vorgeschlagen.
    static let terms: [String: String] = [
        "almond": "Mandeln", "apple": "Apfel", "avocado": "Avocado", "bagel": "Brötchen",
        "banana": "Banane", "bean": "Bohnen", "bell_pepper": "Paprika", "birthday_cake": "Kuchen",
        "blueberry": "Heidelbeeren", "bread": "Brot", "broccoli": "Brokkoli", "butter": "Butter", "cake": "Kuchen",
        "cake_regular": "Kuchen", "caramel": "Zucker", "carrot": "Karotte", "cashew": "Cashewkerne",
        "cauliflower": "Blumenkohl", "celery": "Sellerie", "cereal": "Müsli", "cheese": "Käse", "cheesecake": "Kuchen",
        "cherry": "Kirsche", "chestnut": "Kastanie", "chewing_gum": "Kaugummi", "chives": "Schnittlauch",
        "chocolate": "Schokolade", "chocolate_chip": "Schokolade", "citrus_fruit": "Orange", "coconut": "Kokosnuss",
        "cookie": "Kekse", "corn": "Mais", "croissant": "Croissant", "cucumber": "Gurke", "cupcake": "Kuchen",
        "donut": "Kuchen", "egg": "Hühnerei", "fig": "Feige", "fish": "Fisch", "fried_chicken": "Huhn",
        "fried_egg": "Spiegelei", "fruitcake": "Kuchen", "garlic": "Knoblauch", "gingerbread": "Lebkuchen",
        "grape": "Trauben", "grapefruit": "Grapefruit", "green_beans": "Grüne Bohnen", "grilled_chicken": "Huhn",
        "guava": "Guave", "ham": "Kochschinken", "honey": "Honig", "kiwi": "Kiwi", "lemon": "Zitrone", "lime": "Limette",
        "macadamia": "Macadamianüsse", "mango": "Mango", "marshmallow": "Marshmallows", "meat": "Rindfleisch",
        "muffin": "Kuchen", "mussel": "Muscheln", "mustard": "Senf", "nectarine": "Nektarine", "nut": "Nüsse",
        "oatmeal": "Haferflocken", "onion": "Zwiebel", "oranges": "Orange", "oyster": "Muscheln", "papaya": "Papaya",
        "passionfruit": "Passionsfrucht", "pasta": "Nudeln", "pastry": "Kuchen", "pea": "Erbsen", "peach": "Pfirsich",
        "peanut": "Erdnüsse", "pear": "Birne", "pecan": "Pekannüsse", "pepper_veggie": "Paprika", "pepperoni": "Salami",
        "pie": "Kuchen", "pineapple": "Ananas", "pistachio": "Pistazien", "pizza": "Pizza", "plum": "Pflaume",
        "pomegranate": "Granatapfel", "potato": "Kartoffel", "pumpkin": "Kürbis", "raspberry": "Himbeeren",
        "rice": "Reis", "salmon": "Lachs", "sandwich": "Brot", "sausage": "Würstchen", "scrambled_eggs": "Rührei",
        "seafood": "Garnelen", "shellfish": "Garnelen", "shellfish_prepared": "Garnelen", "spinach": "Spinat",
        "steak": "Rindfleisch", "strawberry": "Erdbeeren", "sugar_cube": "Zucker", "sushi": "Sushi", "tuna": "Thunfisch",
        "waffle": "Kuchen", "wedding_cake": "Kuchen", "white_bread": "Weißbrot", "yogurt": "Joghurt", "zucchini": "Zucchini",
        "apricot": "Aprikose", "artichoke": "Artischocke", "asparagus": "Spargel", "bacon": "Speck", "beer": "Bier",
        "beet": "Rote Bete", "blackberry": "Brombeeren", "candy": "Bonbons", "candy_cane": "Bonbons", "coffee": "Kaffee",
        "coffee_bean": "Kaffee", "cranberry": "Cranberry", "eggplant": "Aubergine", "fries": "Pommes", "frozen_dessert": "Speiseeis",
        "hamburger": "Burger", "honeydew": "Honigmelone", "ice_cream": "Speiseeis", "leek": "Lauch", "lettuce": "Blattsalat",
        "lollipop": "Bonbons", "meatball": "Frikadellen", "melon": "Melone", "mushroom": "Pilze", "pancake": "Pfannkuchen",
        "popcorn": "Popcorn", "pretzel": "Brezel", "radish": "Radieschen", "red_wine": "Wein", "salad": "Blattsalat",
        "sparkling_wine": "Wein", "starfruit": "Sternfrucht", "tea_drink": "Tee", "tomato": "Tomate", "watermelon": "Wassermelone",
        "white_wine": "Wein", "wine": "Wein", "wine_bottle": "Wein",
    ]

    /// Die wahrscheinlichsten Suchbegriffe (höchstens drei, ohne Doppelte) aus den Ergebnissen der Bilderkennung.
    static func terms(from labels: [(id: String, confidence: Float)], minConfidence: Float = 0.12) -> [String] {
        var out: [String] = []
        for l in labels.sorted(by: { $0.confidence > $1.confidence }) where l.confidence >= minConfidence {
            guard let t = terms[l.id], !out.contains(t) else { continue }
            out.append(t)
            if out.count == 3 { break }
        }
        return out.map { String(localized: String.LocalizationValue($0)) }
    }

    static func recognize(_ image: CGImage) async -> [String] {
        guard let obs = try? await ClassifyImageRequest().perform(on: image) else { return [] }
        return terms(from: obs.map { ($0.identifier, $0.confidence) })
    }
}

/// Strichcode im Food-Check: Zutaten aus Open Food Facts, geprüft auf das, was Hunden gefährlich wird.
struct IngredientCheck {
    /// Eine Zutat, die auffällt. `food` ist der Eintrag aus der eigenen Liste mit Urteil und Begründung;
    /// fehlt er dort, stehen Urteil und Begründung hier.
    struct Hit: Identifiable, Equatable {
        let name: String
        let verdict: Food.Verdict
        let reason: String
        var id: String { name }
    }

    /// Wonach gesucht wird: Kennungen von Open Food Facts (sprachunabhängig, „en:onion“) und Wortteile
    /// für den Zutatentext. Bei Trauben nur die Kennung – „Traubenzucker“ ist harmloser Zucker.
    struct Rule {
        let food: String
        let tags: [String]
        let words: [String]
        var verdict: Food.Verdict? = nil
        var reason: String? = nil
    }

    static let rules: [Rule] = [
        Rule(food: "Xylit", tags: ["en:xylitol", "en:e967"], words: ["xylit", "birkenzucker", "e967", "e 967"]),
        Rule(food: "Schokolade", tags: ["en:chocolate", "en:cocoa", "en:cocoa-mass", "en:cocoa-powder", "en:fat-reduced-cocoa-powder"],
             words: ["schokolade", "kakao"]),
        Rule(food: "Rosinen", tags: ["en:raisin", "en:sultana"], words: ["rosine", "sultanine"]),
        Rule(food: "Trauben", tags: ["en:grape"], words: []),
        Rule(food: "Zwiebel", tags: ["en:onion", "en:onion-powder", "en:shallot"], words: ["zwiebel", "schalotte"]),
        Rule(food: "Knoblauch", tags: ["en:garlic", "en:garlic-powder"], words: ["knoblauch"]),
        Rule(food: "Schnittlauch", tags: ["en:chives"], words: ["schnittlauch"]),
        Rule(food: "Macadamianüsse", tags: ["en:macadamia-nut"], words: ["macadamia"]),
        Rule(food: "Walnüsse", tags: ["en:walnut"], words: ["walnuss", "walnüsse"]),
        Rule(food: "Pekannüsse", tags: ["en:pecan-nut"], words: ["pekannuss", "pekannüsse", "pecan"]),
        Rule(food: "Avocadoöl", tags: ["en:avocado"], words: ["avocado"]),
        Rule(food: "Alkohol", tags: ["en:alcohol", "en:ethanol", "en:rum", "en:wine", "en:beer", "en:liqueur"],
             words: ["alkohol", "rum", "likör", "weinbrand", "branntwein"], verdict: .bad,
             reason: String(localized: "Alkohol ist für Hunde giftig. Schon kleine Mengen können Erbrechen, Taumeln und Unterzuckerung auslösen.")),
        Rule(food: "Koffein", tags: ["en:caffeine", "en:coffee", "en:guarana"], words: ["koffein", "kaffee", "guarana"], verdict: .bad,
             reason: String(localized: "Koffein ist für Hunde giftig. Es kann Herzrasen, Unruhe und Krämpfe auslösen.")),
    ]

    let foods: [Food]

    /// Prüft Kennungen und Zutatentext. Das Schlimmste zuerst, jede Zutat nur einmal.
    func hits(tags: [String], text: String) -> [Hit] {
        let tagSet = Set(tags.map { $0.lowercased() })
        let lower = text.lowercased()
        var out: [Hit] = []
        for r in Self.rules {
            let byTag = r.tags.contains { tagSet.contains($0) }
            let byWord = r.words.contains { Self.containsWord(lower, $0) }
            guard byTag || byWord else { continue }
            if let f = foods.first(where: { $0.name == r.food }) {
                out.append(Hit(name: f.name, verdict: f.verdict, reason: f.reason))
            } else if let v = r.verdict, let reason = r.reason {
                out.append(Hit(name: String(localized: String.LocalizationValue(r.food)), verdict: v, reason: reason))
            }
        }
        let rank: [Food.Verdict: Int] = [.bad: 0, .warn: 1, .ok: 2]
        return out.sorted { rank[$0.verdict]! < rank[$1.verdict]! }
    }

    /// „rum“ soll in „Rum“ und „Rumaroma“ zählen, aber nicht in „Krume“ oder „Serum“: Wortanfang verlangt.
    /// Längere Wortteile („kakao“) dürfen auch mitten im Wort stehen („Magerkakao“, „Röstzwiebeln“).
    static func containsWord(_ text: String, _ word: String) -> Bool {
        if word.count >= 5 { return text.contains(word) }
        var rest = text[...]
        while let r = rest.range(of: word) {
            if r.lowerBound == text.startIndex || !text[text.index(before: r.lowerBound)].isLetter { return true }
            rest = rest[r.upperBound...]
        }
        return false
    }
}

/// Ein Produkt aus Open Food Facts, so knapp, wie es der Food-Check braucht.
struct ScannedProduct: Equatable {
    let code: String
    let name: String?
    let brand: String?
    let ingredientsText: String
    let ingredientTags: [String]

    var hasIngredients: Bool { !ingredientsText.isEmpty || !ingredientTags.isEmpty }

    enum LookupError: Error { case notFound, offline }

    /// Fragt Open Food Facts. Gesendet wird nur die Nummer des Strichcodes.
    static func lookup(_ code: String) async throws(LookupError) -> ScannedProduct {
        struct Answer: Decodable {
            struct Product: Decodable {
                let product_name_de: String?
                let product_name: String?
                let brands: String?
                let ingredients_text_de: String?
                let ingredients_text: String?
                let ingredients_tags: [String]?
                let additives_tags: [String]?
            }
            let status: Int?
            let product: Product?
        }
        let digits = code.filter(\.isNumber)
        guard !digits.isEmpty,
              var url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(digits).json") else { throw .notFound }
        url.append(queryItems: [URLQueryItem(name: "fields", value: "product_name_de,product_name,brands,ingredients_text_de,ingredients_text,ingredients_tags,additives_tags")])
        var req = URLRequest(url: url, timeoutInterval: 12)
        // Open Food Facts bittet darum, dass sich Apps zu erkennen geben.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        req.setValue("ThisDog/\(version) (iOS; https://thisdog.app)", forHTTPHeaderField: "User-Agent")
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: req) } catch { throw .offline }
        if (response as? HTTPURLResponse)?.statusCode == 404 { throw .notFound }
        guard let a = try? JSONDecoder().decode(Answer.self, from: data), a.status == 1, let p = a.product else { throw .notFound }
        func clean(_ s: String?) -> String? { s.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } }
        return ScannedProduct(code: digits,
                              name: clean(p.product_name_de) ?? clean(p.product_name),
                              brand: clean(p.brands?.components(separatedBy: ",").first),
                              ingredientsText: clean(p.ingredients_text_de) ?? clean(p.ingredients_text) ?? "",
                              ingredientTags: (p.ingredients_tags ?? []) + (p.additives_tags ?? []))
    }
}
