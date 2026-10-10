import Foundation

/// Finds cooking times in a step so Cook can offer a one-tap timer. A port of
/// `client/src/lib/timers.ts`; keep the two in step.
///
///     "simmer 10–12 mins"   -> 12 minutes (the upper bound: it is a "check by" time)
///     "roast 1 hr 20 min"   -> 80 minutes
///     "rest for 30 seconds" -> 30 seconds
nonisolated func detectTimers(in step: String) -> [DetectedTimer] {
    var found: [DetectedTimer] = []
    let text = step as NSString
    for match in timerPattern.matches(in: step, range: NSRange(location: 0, length: text.length)) {
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : text.substring(with: range)
        }
        guard let low = group(1).flatMap(timerNumber), let unit = group(3) else { continue }
        let whole = text.substring(with: match.range)
        // A bare "m", "s" or "h" is too easy to mistake ("2 m long"), so it only counts straight after a digit.
        if unit.count == 1, !whole.matches(#"\d[hms]"#) { continue }
        let high = group(2).flatMap(timerNumber) ?? low
        var seconds = max(low, high) * unitSeconds(unit)
        if let extra = group(4).flatMap(Double.init), let extraUnit = group(5) {
            seconds += extra * unitSeconds(extraUnit)
        }
        guard seconds.isFinite, seconds > 0, seconds <= 24 * 3600 else { continue }
        found.append(DetectedTimer(label: whole.trimmed, seconds: Int(seconds.rounded()), id: found.count))
    }
    return found
}

/// "1:15", or "1:01:40" from an hour up.
nonisolated func formatClock(_ totalSeconds: Int) -> String {
    let seconds = max(0, totalSeconds)
    let (hours, minutes, rest) = (seconds / 3600, seconds % 3600 / 60, seconds % 60)
    let padded = { (number: Int) in number < 10 ? "0\(number)" : "\(number)" }
    return hours > 0 ? "\(hours):\(padded(minutes)):\(padded(rest))" : "\(minutes):\(padded(rest))"
}

/// Scales an amount and keeps it readable: whole from 10 up, one decimal below.
/// A port of `client/src/lib/scale.ts`.
nonisolated func scaleAmount(_ amount: Double?, by factor: Double) -> Double? {
    guard let amount else { return nil }
    let scaled = amount * factor
    return scaled >= 10 ? scaled.rounded() : (scaled * 10).rounded() / 10
}

/// Scales the quantities written into a step: "add the 500g pasta".
nonisolated func scaleText(_ text: String, by factor: Double) -> String {
    guard factor != 1 else { return text }
    var result = text
    let whole = NSRange(location: 0, length: (text as NSString).length)
    // Back to front, so earlier ranges still point at the right place.
    for match in amountInTextPattern.matches(in: text, range: whole).reversed() {
        guard let range = Range(match.range(at: 1), in: result),
              let scaled = scaleAmount(Double(result[range]), by: factor)
        else { continue }
        result.replaceSubrange(range, with: formatAmount(scaled))
    }
    return result
}

/// The ingredients a step mentions, as indices into `all`, matched loosely on
/// their main words. A port of `ingredientsForStep` in the web's Cook route.
nonisolated func ingredients(forStep step: String, in all: [Recipe.Ingredient]) -> [Int] {
    let text = step.lowercased()
    return all.indices.filter { index in
        all[index].name.lowercased().unicodeScalars
            .split(whereSeparator: { !isWordLetter($0) })
            .filter { $0.count > 3 }
            .contains { text.contains(String($0).replacing(pattern: "(es|s)$", with: "")) }
    }
}

// The web pattern leans on JavaScript's ASCII-only `\b`, which finds no
// boundary before "½" and finds one inside an accented word ("2 más" reads as
// two minutes). These lookarounds treat every letter and digit as part of a word.
nonisolated private let wordStart = #"(?<![\p{L}\p{N}_])"#
nonisolated private let wordEnd = #"(?![\p{L}\p{N}_])"#
nonisolated private let timerNumberPattern = #"\d+(?:\.\d+)?|\d*½|an?|one|two|three|four|five|ten|fifteen|twenty|thirty"#

nonisolated private let timerPattern: NSRegularExpression = {
    let range = "(\(timerNumberPattern))(?:\\s*(?:-|–|—|to|or)\\s*(\(timerNumberPattern)))?"
    let unit = "(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\(wordEnd)"
    let extraMinutes = "(?:\\s*(?:and\\s*)?(\\d+)\\s*(minutes?|mins?|m)\(wordEnd))?"
    return try! NSRegularExpression(pattern: "\(wordStart)\(range)\\s*\(unit)\(extraMinutes)", options: .caseInsensitive)
}()

nonisolated private let amountInTextPattern = try! NSRegularExpression(
    pattern: #"(\d+(?:\.\d+)?)(\s*(?:g|kg|mg|ml|l|oz|lb|lbs|tsp|tbsp|cups?|teaspoons?|tablespoons?)\b)"#,
    options: .caseInsensitive)

nonisolated private let timerWords: [String: Double] = [
    "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30,
]

nonisolated private func timerNumber(_ raw: String) -> Double? {
    let lower = raw.lowercased()
    if let word = timerWords[lower] { return word }
    guard lower.hasSuffix("½") else { return Double(lower) }
    let whole = lower.dropLast()
    return whole.isEmpty ? 0.5 : Double(whole).map { $0 + 0.5 }
}

nonisolated private func unitSeconds(_ unit: String) -> Double {
    switch unit.lowercased().first {
    case "h": 3600
    case "s": 1
    default: 60
    }
}

/// a to z and the accented Latin letters à to ÿ, as the web's `[^a-zà-ÿ]` split has it.
nonisolated private func isWordLetter(_ scalar: Unicode.Scalar) -> Bool {
    ("a"..."z").contains(scalar) || ("\u{E0}"..."\u{FF}").contains(scalar)
}
