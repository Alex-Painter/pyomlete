import Foundation

/// How the household feels about a subject, as Chef holds it.
nonisolated enum Stance: String, CaseIterable, Sendable {
    case never, avoid, less, more, prefer

    /// Read before the subject: "Never mushrooms", "Likes curry".
    var label: String {
        switch self {
        case .never: "Never"
        case .avoid: "Avoid"
        case .less: "Less"
        case .more: "More"
        case .prefer: "Likes"
        }
    }
}

/// Something Chef goes by when it suggests and plans: what they told it, or
/// what it noticed from what they cook, rate and dismiss.
nonisolated struct Preference: Identifiable, Equatable, Sendable {
    enum Source: String, Sendable {
        case told, inferred
    }

    let id: PreferenceID
    let subject: String
    let stance: Stance
    /// What it is based on, shown under it: "You said so on 18 Oct".
    let evidence: String
    let source: Source
}
