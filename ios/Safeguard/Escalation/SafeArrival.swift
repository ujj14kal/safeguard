import Foundation
import UserNotifications

/// "I'll be home in 30 minutes." If the person does not tap "I'm safe" by
/// then, the SOS countdown starts (they can still cancel it). This version
/// lives on the phone: a local notification wakes the person at the
/// deadline, and the countdown starts as soon as the app is open. It cannot
/// fire by itself if the phone is off or the app was force-closed.
@MainActor
public final class SafeArrivalStore: ObservableObject {
    public static let shared = SafeArrivalStore()
    static let deadlineKey = "safeArrival.deadline"
    public static let choices = [15, 30, 60, 120]
    /// A heads-up this long before the deadline.
    static let reminderLead: TimeInterval = 120

    @Published public private(set) var deadline: Date?
    private let defaults: UserDefaults
    private let schedule: @Sendable (Date, Date) -> Void
    private let cancelScheduled: @Sendable () -> Void

    public init(
        defaults: UserDefaults = .standard,
        schedule: @escaping @Sendable (Date, Date) -> Void = SafeArrivalNotifications.schedule,
        cancelScheduled: @escaping @Sendable () -> Void = SafeArrivalNotifications.cancel
    ) {
        self.defaults = defaults
        self.schedule = schedule
        self.cancelScheduled = cancelScheduled
        let stored = defaults.double(forKey: Self.deadlineKey)
        deadline = stored > 0 ? Date(timeIntervalSince1970: stored) : nil
    }

    public var isActive: Bool { deadline != nil }

    public func start(minutes: Int, now: Date = Date()) {
        let end = now.addingTimeInterval(TimeInterval(minutes * 60))
        deadline = end
        defaults.set(end.timeIntervalSince1970, forKey: Self.deadlineKey)
        schedule(end, end.addingTimeInterval(-Self.reminderLead))
    }

    /// "I'm safe": the timer ends and nothing happens.
    public func markSafe() {
        clear()
    }

    public func remaining(now: Date = Date()) -> TimeInterval? {
        deadline.map { max(0, $0.timeIntervalSince(now)) }
    }

    public func isOverdue(now: Date = Date()) -> Bool {
        guard let deadline else { return false }
        return now >= deadline
    }

    /// Called once when the deadline has passed: clears the timer and
    /// returns true so the caller starts the countdown exactly once.
    public func consumeOverdue(now: Date = Date()) -> Bool {
        guard isOverdue(now: now) else { return false }
        clear()
        return true
    }

    /// "2:05" for 125 seconds.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func clear() {
        deadline = nil
        defaults.removeObject(forKey: Self.deadlineKey)
        cancelScheduled()
    }
}

public enum SafeArrivalNotifications {
    static let deadlineID = "safeArrival.deadline"
    static let reminderID = "safeArrival.reminder"

    public static func schedule(deadline: Date, reminder: Date) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            add(center, id: deadlineID, at: deadline,
                title: String(localized: "Safe-arrival time is up"),
                body: String(localized: "Open Safeguard and tap I'm safe, or an SOS countdown will start."),
                critical: true)
            if reminder.timeIntervalSinceNow > 5 {
                add(center, id: reminderID, at: reminder,
                    title: String(localized: "Almost time"),
                    body: String(localized: "Tap I'm safe in Safeguard when you arrive."),
                    critical: false)
            }
        }
    }

    public static func cancel() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [deadlineID, reminderID])
    }

    private static func add(
        _ center: UNUserNotificationCenter, id: String, at date: Date,
        title: String, body: String, critical: Bool
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = critical ? .timeSensitive : .active
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, date.timeIntervalSinceNow), repeats: false
        )
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
