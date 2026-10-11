import Foundation
import OSLog

/// What Home needs before any list is opened, and what has to outlive a kill.
nonisolated struct LibraryIndex: Codable, Equatable, Sendable {
    var summaries: [ListSummary] = []
    var aisleOrder: [String] = []
    var recipes: [RecipeSummary] = []
    var units: [String] = []
    /// Lists whose delete is committed but not yet confirmed by the server.
    var deletingLists: Set<ListID> = []
    /// The list last opened: the one Home offers to cook from.
    var currentList: ListID?
    /// Recipes whose delete is committed but not yet confirmed by the server.
    var deletingRecipes: Set<RecipeID> = []
}

nonisolated extension LibraryIndex {
    /// Written by hand so every field may be missing: an index saved by an
    /// older build still loads, with its unsent deletes and current list.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        summaries = try container.decodeIfPresent([ListSummary].self, forKey: .summaries) ?? []
        aisleOrder = try container.decodeIfPresent([String].self, forKey: .aisleOrder) ?? []
        recipes = try container.decodeIfPresent([RecipeSummary].self, forKey: .recipes) ?? []
        units = try container.decodeIfPresent([String].self, forKey: .units) ?? []
        deletingLists = try container.decodeIfPresent(Set<ListID>.self, forKey: .deletingLists) ?? []
        currentList = try container.decodeIfPresent(ListID.self, forKey: .currentList)
        deletingRecipes = try container.decodeIfPresent(Set<RecipeID>.self, forKey: .deletingRecipes) ?? []
    }
}

protocol ReplicaStorage {
    func loadAll() -> [ListReplica]
    func save(_ replica: ListReplica)
    func discard(_ id: ListID)
    func loadIndex() -> LibraryIndex?
    func save(_ index: LibraryIndex)
}

/// One JSON file per list under Application Support, each written atomically,
/// so a list's server copy and its queue can never disagree after a kill.
/// A failed write is logged and the session carries on from memory.
struct ReplicaDisk: ReplicaStorage {
    private let root: URL
    private let log = Logger(subsystem: "com.alexpainter.omlete", category: "disk")

    init(root: URL = URL.applicationSupportDirectory.appending(path: "Omlete", directoryHint: .isDirectory)) {
        self.root = root
        try? FileManager.default.createDirectory(at: lists, withIntermediateDirectories: true)
    }

    private var lists: URL { root.appending(path: "lists", directoryHint: .isDirectory) }
    private var indexFile: URL { root.appending(path: "index.json") }

    private func file(for id: ListID) -> URL {
        let name = id.rawValue.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "list"
        return lists.appending(path: "\(name).json")
    }

    func loadAll() -> [ListReplica] {
        let files = (try? FileManager.default.contentsOfDirectory(at: lists, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            do {
                return try JSONDecoder().decode(ListReplica.self, from: Data(contentsOf: file))
            } catch {
                // Kept for a post-mortem; the list reloads from the server.
                log.error("Unreadable replica \(file.lastPathComponent): \(String(describing: error))")
                let aside = file.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: file, to: aside)
                return nil
            }
        }
    }

    func save(_ replica: ListReplica) {
        write(replica, to: file(for: replica.id))
    }

    func discard(_ id: ListID) {
        try? FileManager.default.removeItem(at: file(for: id))
    }

    func loadIndex() -> LibraryIndex? {
        guard let data = try? Data(contentsOf: indexFile) else { return nil }
        return try? JSONDecoder().decode(LibraryIndex.self, from: data)
    }

    func save(_ index: LibraryIndex) {
        write(index, to: indexFile)
    }

    private func write(_ value: some Encodable, to file: URL) {
        do {
            try JSONEncoder().encode(value).write(to: file, options: .atomic)
        } catch {
            log.error("Could not save \(file.lastPathComponent): \(String(describing: error))")
        }
    }
}
