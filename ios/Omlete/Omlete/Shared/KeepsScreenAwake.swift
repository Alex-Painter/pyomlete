import SwiftUI
import UIKit

extension View {
    /// Shop and Cook are read at arm's length with full hands, so the screen must not dim.
    func keepsScreenAwake() -> some View {
        onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}
