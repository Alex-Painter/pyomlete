import Foundation

nonisolated struct ParsedItem: Equatable, Sendable {
    var name: String
    var amount: Double?
    var unit: String?
}

/// Turns what someone types, pastes or dictates into list items. A port of
/// `client/src/lib/parseItems.ts`; keep the two in step.
///
///     "2 onions"          -> amount 2, name "onions"
///     "500g mince"        -> amount 500, unit "g", name "mince"
///     "milk, eggs, bread" -> three items
///
/// Deliberately forgiving: anything it cannot read as a quantity stays in the name.
nonisolated func parseItems(_ raw: String) -> [ParsedItem] {
    raw.split(whereSeparator: { $0.isNewline || $0 == "," || $0 == ";" })
        .compactMap { parseItem(String($0)) }
        .filter { !$0.name.isEmpty }
}

nonisolated func parseItem(_ raw: String) -> ParsedItem? {
    let text = raw.trimmed
        .replacing(pattern: #"^(?:[-*•·▪◦]+|\d+[.)])\s+"#, with: "")
        .trimmed
    guard !text.isEmpty else { return nil }

    // "2 onions", "500g mince", "1.5 kg potatoes", "2 tins of tomatoes"
    if let leading = text.groups(matching: "^\(numberPattern)\\s*([a-zA-Z]+\\.?)?\\s+(.+)$"),
       let rawAmount = leading[1], let rest = leading[3] {
        let unit = unit(for: leading[2])
        let name = cleanName(unit != nil ? rest : "\(leading[2] ?? "") \(rest)")
        if let amount = parseNumber(rawAmount), !name.isEmpty {
            return ParsedItem(name: name, amount: amount, unit: unit)
        }
    }

    // "milk x2", "eggs ×12", "bananas (6)"
    if let trailing = text.groups(
        matching: #"^(.+?)\s*(?:[x×]\s*(\d+(?:\.\d+)?)|\((\d+(?:\.\d+)?)\))$"#, caseInsensitive: true),
       let name = trailing[1], let amount = (trailing[2] ?? trailing[3]).flatMap(Double.init) {
        return ParsedItem(name: cleanName(name), amount: amount, unit: nil)
    }

    return ParsedItem(name: cleanName(text), amount: nil, unit: nil)
}

/// How a quantity reads on a row: "500g", "2 tins", and "1" for "1 whole".
nonisolated func formatQuantity(_ amount: Double?, _ rawUnit: String?) -> String {
    guard let amount else { return rawUnit == "whole" ? "" : rawUnit ?? "" }
    let unit = rawUnit.flatMap { $0.isEmpty ? nil : displayUnits[$0.lowercased()] ?? $0 }
    let number = formatAmount(amount)
    guard let unit, !unit.isEmpty else { return number }
    return ["g", "kg", "mg", "ml", "l", "oz", "lb"].contains(unit) ? "\(number)\(unit)" : "\(number) \(unit)"
}

/// An amount to two decimal places with no trailing zeros: "2", "0.5", "1.33".
nonisolated func formatAmount(_ amount: Double) -> String {
    let rounded = (amount * 100).rounded() / 100
    let isWhole = rounded == rounded.rounded() && abs(rounded) < 1e15
    return isWhole ? String(Int(rounded)) : String(rounded)
}

/// A quantity typed into an amount field, with either decimal mark. nil for anything that is not a finite number.
nonisolated func parseAmount(_ text: String) -> Double? {
    let text = text.trimmed
    // Digits and one decimal mark only: `Double` alone would also read "0x10" and "1e3".
    guard text.wholeMatch(of: /\d+([.,]\d*)?|[.,]\d+/) != nil else { return nil }
    return Double(text.replacingOccurrences(of: ",", with: ".")).flatMap { $0.isFinite ? $0 : nil }
}

nonisolated private let numberPattern = #"(\d+(?:[.,]\d+)?(?:\s*/\s*\d+)?|\d*\s*[½¼¾⅓⅔])"#

nonisolated private let fractions: [Character: Double] = [
    "½": 0.5, "¼": 0.25, "¾": 0.75, "⅓": 1.0 / 3, "⅔": 2.0 / 3,
]

nonisolated private let unitAliases: [String: String] = [
    "g": "g", "gram": "g", "grams": "g", "gr": "g",
    "kg": "kg", "kgs": "kg", "kilo": "kg", "kilos": "kg", "kilogram": "kg", "kilograms": "kg",
    "mg": "mg",
    "ml": "ml", "millilitre": "ml", "millilitres": "ml", "milliliter": "ml", "milliliters": "ml",
    "l": "l", "litre": "l", "litres": "l", "liter": "l", "liters": "l",
    "oz": "oz", "lb": "lb", "lbs": "lb",
    "tsp": "tsp", "teaspoon": "tsp", "teaspoons": "tsp",
    "tbsp": "tbsp", "tablespoon": "tbsp", "tablespoons": "tbsp",
    "cup": "cup", "cups": "cup", "pint": "pint", "pints": "pint",
    "pack": "pack", "packs": "pack", "packet": "pack", "packets": "pack",
    "tin": "tin", "tins": "tin", "can": "can", "cans": "can",
    "jar": "jar", "jars": "jar", "bottle": "bottle", "bottles": "bottle",
    "bag": "bag", "bags": "bag", "box": "box", "boxes": "box",
    "bunch": "bunch", "bunches": "bunch", "clove": "clove", "cloves": "clove",
    "head": "head", "heads": "head", "slice": "slice", "slices": "slice",
    "loaf": "loaf", "loaves": "loaf", "dozen": "dozen", "pinch": "pinch",
]

nonisolated private let displayUnits: [String: String] = [
    "grams": "g", "gram": "g", "kilograms": "kg",
    "millilitres": "ml", "milliliters": "ml", "litres": "l", "liters": "l",
    "whole": "",
]

nonisolated private func parseNumber(_ raw: String) -> Double? {
    let text = raw.filter { !$0.isWhitespace }
    if let fraction = text.last.flatMap({ fractions[$0] }) {
        let whole = text.dropLast()
        return whole.isEmpty ? fraction : Double(whole).map { $0 + fraction }
    }
    let value: Double?
    if let slash = text.groups(matching: #"^(\d+)/(\d+)$"#), let top = slash[1].flatMap(Double.init),
       let bottom = slash[2].flatMap(Double.init) {
        value = top / bottom
    } else {
        value = Double(text.replacingOccurrences(of: ",", with: ".")).map { ($0 * 1000).rounded() / 1000 }
    }
    // The web keeps "1/0" as Infinity, which JSON cannot carry.
    return value.flatMap { $0.isFinite ? $0 : nil }
}

nonisolated private func unit(for word: String?) -> String? {
    guard let word else { return nil }
    return unitAliases[word.lowercased().replacing(pattern: #"\.$"#, with: "")]
}

nonisolated private func cleanName(_ name: String) -> String {
    name.replacing(pattern: #"^of\s+"#, with: "", caseInsensitive: true)
        .replacing(pattern: #"\s+"#, with: " ")
        .trimmed
}

nonisolated extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Trimmed, with any line breaks inside turned into single spaces.
    var oneLine: String {
        split(whereSeparator: \.isNewline).map { String($0).trimmed }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    func replacing(pattern: String, with replacement: String, caseInsensitive: Bool = false) -> String {
        var options: String.CompareOptions = .regularExpression
        if caseInsensitive { options.insert(.caseInsensitive) }
        return replacingOccurrences(of: pattern, with: replacement, options: options)
    }

    /// Capture groups of the first match, index 0 being the whole match; nil
    /// for a group that did not take part.
    func groups(matching pattern: String, caseInsensitive: Bool = false) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? .caseInsensitive : []),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self))
        else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: self).map { String(self[$0]) } }
    }

    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
