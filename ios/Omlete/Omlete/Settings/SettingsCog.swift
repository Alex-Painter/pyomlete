import SwiftUI

/// The way into Settings from a tab's first screen. Leading on all four, so
/// it is in one place whichever tab is showing and each screen's own actions
/// keep the trailing corner.
struct SettingsCog: ToolbarContent {
    let tab: AppTab
    @Environment(AppNavigation.self) private var navigation

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Settings", systemImage: "gearshape") { navigation.push(.settings, on: tab) }
                .accessibilityIdentifier(identifier)
        }
        // Keeps the cog a button of its own beside a screen's leading action, such as Discover's Clear all.
        ToolbarSpacer(.fixed, placement: .topBarLeading)
    }

    /// Spelled out, so renaming a tab's case cannot change what the tests and the verify recipes look for.
    private var identifier: String {
        switch tab {
        case .home: "home.settingsButton"
        case .discover: "discover.settingsButton"
        case .add: "add.settingsButton"
        case .recipes: "recipes.settingsButton"
        }
    }
}
