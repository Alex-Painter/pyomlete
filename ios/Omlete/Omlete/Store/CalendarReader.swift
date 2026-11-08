import EventKit
import Foundation
import Observation

/// Reads busy time from the phone's own calendar with EventKit, for the week
/// on Plan. The web connects Google Calendar on the server; the phone already
/// has the person's calendars, so it needs no sign-in.
///
/// It only reads, and only while Use my calendar is on: nothing here writes to
/// a list or to a calendar, and access is asked for only when that row is
/// tapped. Denied, it stays off without a word, and Plan looks as it does with
/// no calendar.
@Observable final class CalendarReader {
    /// Asking for access without this key in Info.plist ends the app, so
    /// without it the setting is not offered at all.
    static let usageKey = "NSCalendarsFullAccessUsageDescription"
    private static let wantedKey = "useCalendar"

    /// The build can ask for calendar access.
    let canAsk: Bool
    /// What the person chose in Settings, kept across launches.
    private(set) var wanted: Bool
    private(set) var status: EKAuthorizationStatus
    /// Bumped whenever the calendar database changes, so Plan reads it again.
    private(set) var changes = 0

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        canAsk = bundle.object(forInfoDictionaryKey: Self.usageKey) != nil
        wanted = defaults.bool(forKey: Self.wantedKey)
        status = EKEventStore.authorizationStatus(for: .event)
    }

    /// Plan reads the calendar.
    var isOn: Bool { canAsk && wanted && status == .fullAccess }

    /// Use my calendar. Turning it on asks for access the first time; a no
    /// leaves it off.
    func setUseCalendar(_ on: Bool) async {
        guard on else {
            set(wanted: false)
            return
        }
        guard canAsk else { return }
        if status != .fullAccess {
            _ = try? await store.requestFullAccessToEvents()
            status = EKEventStore.authorizationStatus(for: .event)
        }
        set(wanted: status == .fullAccess)
    }

    /// The busy time between two instants, from every calendar on the phone
    /// but birthdays, counting what a calendar marks busy, tentative or away.
    func busy(from start: Date, to end: Date) -> [CalendarDays.BusyBlock] {
        guard isOn else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { Self.counts(availability: $0.availability, isAllDay: $0.isAllDay, calendar: $0.calendar?.type) }
            .map { CalendarDays.BusyBlock(start: $0.startDate, end: $0.endDate) }
    }

    /// Whether an event takes the time, as free/busy would read it. One marked
    /// free never does, nor a birthday. An all-day event that says nothing
    /// about availability (a holiday, a reminder of a trip) is not a busy day.
    nonisolated static func counts(availability: EKEventAvailability, isAllDay: Bool, calendar: EKCalendarType?) -> Bool {
        if calendar == .birthday { return false }
        switch availability {
        case .free: return false
        case .notSupported: return !isAllDay
        case .busy, .tentative, .unavailable: return true
        @unknown default: return !isAllDay
        }
    }

    /// Runs while the screen that started it is up: a calendar changed in the
    /// background, or access changed in iOS Settings, shows when Plan reads again.
    func watch() async {
        for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
            status = EKEventStore.authorizationStatus(for: .event)
            changes += 1
        }
    }

    /// Access can change in iOS Settings while the app is away.
    func refreshStatus() {
        status = EKEventStore.authorizationStatus(for: .event)
    }

    private func set(wanted: Bool) {
        self.wanted = wanted
        defaults.set(wanted, forKey: Self.wantedKey)
    }
}
