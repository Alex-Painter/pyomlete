import AudioToolbox
import UIKit

/// A finished timer: a system sound, which a silenced phone skips, and a haptic, which it does not.
enum TimerChime {
    private static let alarm: SystemSoundID = 1005

    static func play() {
        AudioServicesPlaySystemSound(alarm)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
