import Foundation
import OSLog

/// What is saved per recipe: one value in one file, so the step, the timers
/// and the unsent rating can never disagree after a kill.
nonisolated struct CookRecord: Codable, Equatable, Sendable {
    var session: CookSession
    /// A rating tapped but not yet confirmed by the server. The latest tap wins.
    var unsentRating: Int?
    /// `session.meal` as the server last took it.
    var loggedMeal: CookSession.Meal?

    var id: RecipeID { session.recipe.id }

    /// This cook's meal, while the server does not have it as it is here.
    var mealToSend: CookSession.Meal? { session.meal == loggedMeal ? nil : session.meal }
}

protocol CookStorage {
    func loadAll() -> [CookRecord]
    func save(_ record: CookRecord)
    func discard(_ id: RecipeID)
}

/// One JSON file per recipe under Application Support, each written atomically.
/// A failed write is logged and the cook carries on from memory.
struct CookDisk: CookStorage {
    private let cooks: URL
    private let log = Logger(subsystem: "com.alexpainter.omlete", category: "disk")

    init(root: URL = URL.applicationSupportDirectory.appending(path: "Omlete", directoryHint: .isDirectory)) {
        cooks = root.appending(path: "cooks", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: cooks, withIntermediateDirectories: true)
    }

    private func file(for id: RecipeID) -> URL {
        let name = id.rawValue.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "recipe"
        return cooks.appending(path: "\(name).json")
    }

    func loadAll() -> [CookRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: cooks, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            do {
                return try JSONDecoder().decode(CookRecord.self, from: Data(contentsOf: file))
            } catch {
                // Nothing here is worth a post-mortem: the recipe reloads from the server.
                log.error("Unreadable cook \(file.lastPathComponent): \(String(describing: error))")
                try? FileManager.default.removeItem(at: file)
                return nil
            }
        }
    }

    func save(_ record: CookRecord) {
        do {
            try JSONEncoder().encode(record).write(to: file(for: record.id), options: .atomic)
        } catch {
            log.error("Could not save cook \(record.id.rawValue): \(String(describing: error))")
        }
    }

    func discard(_ id: RecipeID) {
        try? FileManager.default.removeItem(at: file(for: id))
    }
}
