import Foundation
import Testing
@testable import KanbanCode
import KanbanCodeCore

@Suite("Triage view helpers")
struct TriageViewHelpersTests {
    static let zone = TimeZone(identifier: "Australia/Sydney")!
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }
    /// 2026-11-17 14:30 in Sydney.
    static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 14, minute: 30))!

    @Test("timed snoozes are 15 minutes and 1 hour from now")
    func timedChoices() {
        let fifteen = TriageSnoozeChoice.fifteenMinutes.snooze(activity: .needsAttention, now: Self.now, calendar: Self.calendar)
        #expect(fifteen.until == Self.now.addingTimeInterval(15 * 60))
        #expect(fifteen.untilActivityChange == false)
        #expect(fifteen.snoozedAt == Self.now)
        let hour = TriageSnoozeChoice.oneHour.snooze(activity: .needsAttention, now: Self.now, calendar: Self.calendar)
        #expect(hour.until == Self.now.addingTimeInterval(3600))
    }

    @Test("until it changes captures the activity and has no end time")
    func untilChangeChoice() {
        let snooze = TriageSnoozeChoice.untilChange.snooze(activity: .blocked, now: Self.now, calendar: Self.calendar)
        #expect(snooze.until == nil)
        #expect(snooze.untilActivityChange)
        #expect(snooze.stateAtSnooze == .blocked)
        #expect(snooze.snoozedAt == Self.now)
    }

    @Test("tomorrow is 09:00 local on the next day")
    func tomorrowChoice() {
        let snooze = TriageSnoozeChoice.tomorrowMorning.snooze(activity: nil, now: Self.now, calendar: Self.calendar)
        let expected = Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 9))!
        #expect(snooze.until == expected)
        let parts = Self.calendar.dateComponents([.day, .hour, .minute], from: snooze.until!)
        #expect(parts.day == 18 && parts.hour == 9 && parts.minute == 0)
    }

    @Test("wait labels at the minute, hour and day boundaries")
    func waitBoundaries() {
        #expect(TriageFormat.wait(-5) == "<1m")
        #expect(TriageFormat.wait(59) == "<1m")
        #expect(TriageFormat.wait(60) == "1m")
        #expect(TriageFormat.wait(3599) == "59m")
        #expect(TriageFormat.wait(3600) == "1h")
        #expect(TriageFormat.wait(3660) == "1h 1m")
        #expect(TriageFormat.wait(86400) == "1d")
    }

    @Test("the tail keeps the last non-empty lines")
    func tail() {
        #expect(TriageFormat.tail("a\n\nb\n  \nc\nd\n\n\n") == ["b", "c", "d"])
        #expect(TriageFormat.tail("only\n\n") == ["only"])
        #expect(TriageFormat.tail("x\ny", count: 3) == ["x", "y"])
        #expect(TriageFormat.tail("") == [])
    }
}
