import Foundation

nonisolated enum APIEnvironment {
    /// Release talks to production. Debug reads the `apiBaseURL` default, so a
    /// launch argument (`-apiBaseURL http://127.0.0.1:8123`) points the app at
    /// a local backend, and otherwise uses the usual local port.
    static var baseURL: URL {
        #if DEBUG
        let override = UserDefaults.standard.string(forKey: "apiBaseURL").flatMap(URL.init(string:))
        return override ?? URL(string: "http://127.0.0.1:8000")!
        #else
        return URL(string: "https://omlete-api-production.up.railway.app")!
        #endif
    }
}
