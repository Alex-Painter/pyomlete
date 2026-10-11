import Foundation

nonisolated extension String {
    /// The one rule for searching by title: any part of it, whatever the case. An empty search matches everything.
    func matches(search: String) -> Bool {
        let needle = search.trimmed.lowercased()
        return needle.isEmpty || lowercased().contains(needle)
    }
}
