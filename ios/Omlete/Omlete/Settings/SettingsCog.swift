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
                .accessibilityIdentifier("\(tab).settingsButton")
        }
    }
}
