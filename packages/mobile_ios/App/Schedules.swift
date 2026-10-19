import Foundation
import Observation

/*
 * Scheduled tasks (spec: verde scheduled tasks v1). The desktop daemon owns and fires them; the
 * core's `schedule_*` intents list and edit them, validating locally with the daemon's rules, and
 * its `schedules` view is read from the host's published snapshots. Swift only formats that state
 * and maps the form onto intents. Prompts and names are never logged.
 */

// MARK: - Formatting

/// Day names by the daemon's weekday number (0 = Sunday).
let scheduleWeekdayShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
let scheduleWeekdayLong = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
/// Display and chip order: Monday first.
let scheduleWeekOrder = [1, 2, 3, 4, 5, 6, 0]

/// Canonical weekdays: valid, unique and sorted; every day is the empty list.
func scheduleWeekdays<S: Sequence>(_ days: S) -> [Int] where S.Element: BinaryInteger {
    let set = Set(days.map { Int($0) }.filter { $0 >= 0 && $0 <= 6 })
    return set.count == 7 ? [] : set.sorted()
}

/// The row title: the name, else the prompt's first line.
func scheduleTitle(_ entry: ScheduleEntry) -> String {
    let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty { return name }
    let line = entry.prompt.split(whereSeparator: \.isNewline).first.map { String($0) } ?? ""
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? "Scheduled task" : trimmed
}

/// "Every 5 minutes", "Every hour", "Every 2 hours", "Every day".
func scheduleIntervalText(_ minutes: Int) -> String {
    if minutes >= 1440 && minutes % 1440 == 0 {
        let days = minutes / 1440
        return days == 1 ? "Every day" : "Every \(days) days"
    }
    if minutes >= 60 && minutes % 60 == 0 {
        let hours = minutes / 60
        return hours == 1 ? "Every hour" : "Every \(hours) hours"
    }
    return minutes == 1 ? "Every minute" : "Every \(minutes) minutes"
}

/// A one-off run time in the phone's calendar: "Today 14:30", "Tomorrow 14:30", "Thu 14:30",
/// "Dec 1, 14:30", or with the year when it differs.
func scheduleMomentText(_ ms: Int64, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = locale
    formatter.dateFormat = "HH:mm"
    let time = formatter.string(from: date)
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    switch days {
    case 0: return "Today " + time
    case 1: return "Tomorrow " + time
    case 2...6:
        formatter.dateFormat = "EEE"
        return formatter.string(from: date) + " " + time
    default:
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        return formatter.string(from: date) + ", " + time
    }
}

/// The human repeat: "Weekdays at 09:00", "Every 2 hours", "Daily at 07:30", "Once · Tue 14:30".
/// Daily times are the desktop's local clock and are shown as the daemon stores them.
func scheduleRepeatText(kind: String, atMs: Int64?, everyMinutes: UInt32?, time: String, weekdays: [UInt16],
                        now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
    switch kind {
    case "once":
        guard let atMs, atMs > 0 else { return "Once" }
        return "Once · " + scheduleMomentText(atMs, now: now, calendar: calendar, locale: locale)
    case "interval":
        guard let everyMinutes, everyMinutes > 0 else { return "Repeats" }
        return scheduleIntervalText(Int(everyMinutes))
    case "daily":
        let at = time.isEmpty ? "" : " at " + time
        let days = scheduleWeekdays(weekdays)
        if days.isEmpty { return "Daily" + at }
        if days == [1, 2, 3, 4, 5] { return "Weekdays" + at }
        if days == [0, 6] { return "Weekends" + at }
        if days.count == 1 { return scheduleWeekdayLong[days[0]] + "s" + at }
        return scheduleWeekOrder.filter { days.contains($0) }.map { scheduleWeekdayShort[$0] }.joined(separator: ", ") + at
    default:
        return "Custom schedule"
    }
}

func scheduleRepeatText(_ entry: ScheduleEntry, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
    scheduleRepeatText(kind: entry.repeat_kind, atMs: entry.repeat_at_ms, everyMinutes: entry.repeat_every_minutes,
                       time: entry.repeat_time, weekdays: entry.repeat_weekdays, now: now, calendar: calendar, locale: locale)
}

/// "45m", "3h", "3h 20m", "2d 4h"; partial minutes round up so "Next in" never says 0.
func scheduleDurationText(_ ms: Int64) -> String {
    let minutes = max(1, (ms + 59_999) / 60_000)
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60, rest = minutes % 60
    if hours < 24 { return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m" }
    let days = hours / 24, restHours = hours % 24
    return restHours == 0 ? "\(days)d" : "\(days)d \(restHours)h"
}

/// "Next in 3h", "Due now" or "Paused", against the desktop's clock (`now_ms`).
func scheduleNextText(enabled: Bool, nextMs: Int64?, nowMs: Int64) -> String {
    guard enabled else { return "Paused" }
    guard let nextMs, nextMs > 0 else { return "Not scheduled" }
    let remaining = nextMs - nowMs
    return remaining <= 0 ? "Due now" : "Next in " + scheduleDurationText(remaining)
}

enum ScheduleStatusTone: Equatable { case quiet, ok, attention, failure }

/// The last run: "Never run", "Ran 2 h ago", "Queued 5 min ago", "Failed 1 h ago", "Ran late …".
func scheduleStatusText(_ entry: ScheduleEntry, nowMs: Int64) -> (text: String, tone: ScheduleStatusTone) {
    guard let status = entry.last_status, !status.isEmpty else { return ("Never run", .quiet) }
    let ago = entry.last_run_ms.map { " " + agoLabel($0, nowMs) } ?? ""
    switch status {
    case "ok": return ("Ran" + ago, .ok)
    case "queued": return ("Queued" + ago, .attention)
    case "late": return ("Ran late" + ago, .attention)
    case "failed": return ("Failed" + ago, .failure)
    default: return (String(status.prefix(1)).uppercased() + String(status.dropFirst()) + ago, .quiet)
    }
}

/// A settled receipt's message, nil on success.
func scheduleFailureText(_ operation: CoreOperation) -> String? {
    switch operation.state {
    case "succeeded": return nil
    case "uncertain": return "The connection dropped before verde answered. Refresh to check before retrying."
    default:
        if let message = operation.error?.message, !message.isEmpty { return message }
        return "The host couldn't save this scheduled task."
    }
}

// MARK: - Form

enum ScheduleSendTo: Hashable {
    /// The active companion's chat (also the parent).
    case companion
    /// The existing chat of a schedule being edited that isn't the companion's.
    case existing
    /// A fresh chat in a workspace on every run.
    case newChat
}

enum ScheduleRepeatKind: String, CaseIterable, Identifiable {
    case once, interval, daily
    var id: String { rawValue }
    var label: String {
        switch self {
        case .once: return "Once"
        case .interval: return "Every"
        case .daily: return "Daily"
        }
    }
}

enum ScheduleIntervalUnit: String, CaseIterable, Identifiable {
    case minutes, hours
    var id: String { rawValue }
    var title: String { self == .hours ? "Hours" : "Minutes" }
    func noun(_ count: Int) -> String {
        switch self {
        case .minutes: return count == 1 ? "minute" : "minutes"
        case .hours: return count == 1 ? "hour" : "hours"
        }
    }
    /// The daemon allows 5 minutes to 7 days.
    var range: ClosedRange<Int> { self == .hours ? 1...168 : 5...10080 }
    var step: Int { self == .hours ? 1 : 5 }
}

/// Keeps the same interval when the unit changes, clamped to that unit's range.
func scheduleConvertEvery(_ every: Int, from: ScheduleIntervalUnit, to: ScheduleIntervalUnit) -> Int {
    let minutes = from == .hours ? every * 60 : every
    let value: Int
    switch to {
    case .minutes: value = Int((Double(minutes) / 5).rounded()) * 5
    case .hours: value = Int((Double(minutes) / 60).rounded())
    }
    return min(max(value, to.range.lowerBound), to.range.upperBound)
}

/// One hour from now, on a 5-minute boundary.
func scheduleDefaultOnce(_ now: Date) -> Date {
    let step: TimeInterval = 300
    return Date(timeIntervalSince1970: ((now.timeIntervalSince1970 + 3600) / step).rounded(.up) * step)
}

/// The "New scheduled task" / edit form. Times are the desktop's clock except `at`, an instant.
struct ScheduleDraft: Equatable {
    var prompt = ""
    var name = ""
    var sendTo = ScheduleSendTo.companion
    /// The `.existing` chat.
    var threadWorkspaceID = ""
    var threadID = ""
    /// The `.newChat` workspace and brain (an empty model is the provider's default).
    var workspaceID = ""
    var provider = ""
    var model = ""
    var repeatKind = ScheduleRepeatKind.daily
    var at: Date
    var every = 1
    var unit = ScheduleIntervalUnit.hours
    var hour = 9
    var minute = 0
    var weekdays: Set<Int> = [1, 2, 3, 4, 5]
    var enabled = true

    init(now: Date = Date()) { at = scheduleDefaultOnce(now) }

    /// The empty state's example: a weekday-morning CI check.
    static func example(now: Date = Date()) -> ScheduleDraft {
        var draft = ScheduleDraft(now: now)
        draft.prompt = "Check CI for every workspace and tell me what failed."
        draft.name = "Morning CI check"
        return draft
    }

    init(entry: ScheduleEntry, companionChat: (workspace: String, thread: String)?, now: Date = Date()) {
        self.init(now: now)
        prompt = entry.prompt
        name = entry.name
        enabled = entry.enabled
        if entry.target_kind == "new_chat" {
            sendTo = .newChat
            workspaceID = entry.target_workspace_id
            provider = entry.target_provider
            model = entry.target_model
        } else if let chat = companionChat, chat.workspace == entry.target_workspace_id, chat.thread == entry.target_thread_id {
            sendTo = .companion
        } else {
            sendTo = .existing
            threadWorkspaceID = entry.target_workspace_id
            threadID = entry.target_thread_id
        }
        switch entry.repeat_kind {
        case "interval":
            repeatKind = .interval
            let minutes = Int(entry.repeat_every_minutes ?? 60)
            if minutes >= 60 && minutes % 60 == 0 { unit = .hours; every = minutes / 60 } else { unit = .minutes; every = minutes }
        case "daily":
            repeatKind = .daily
            let parts = entry.repeat_time.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2 { hour = parts[0]; minute = parts[1] }
            weekdays = entry.repeat_weekdays.isEmpty ? Set(0...6) : Set(entry.repeat_weekdays.map { Int($0) })
        default:
            repeatKind = .once
            if let ms = entry.repeat_at_ms, ms > 0 { at = Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }
        }
    }

    var cleanPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var everyMinutes: Int { unit == .hours ? every * 60 : every }
    var time: String { String(format: "%02ld:%02ld", hour, minute) }

    /// Enough to try a save; the core checks the rest and its message is shown.
    var canSave: Bool {
        guard !cleanPrompt.isEmpty else { return false }
        switch sendTo {
        case .companion: return true
        case .existing: return !threadID.isEmpty
        case .newChat: return !workspaceID.isEmpty && !provider.isEmpty
        }
    }

    func repeatValue() -> ScheduleRepeat {
        switch repeatKind {
        case .once:
            let minuteMs = (at.timeIntervalSince1970 / 60).rounded(.down) * 60_000
            return ScheduleRepeat(kind: "once", at_ms: Int64(minuteMs))
        case .interval:
            return ScheduleRepeat(kind: "interval", every_minutes: UInt32(clamping: everyMinutes))
        case .daily:
            return ScheduleRepeat(kind: "daily", time: time, weekdays: scheduleWeekdays(weekdays).map { UInt16($0) })
        }
    }

    /// The repeat preview under the picker.
    func repeatText(now: Date = Date()) -> String {
        let value = repeatValue()
        return scheduleRepeatText(kind: value.kind, atMs: value.at_ms, everyMinutes: value.every_minutes,
                                  time: value.time ?? "", weekdays: value.weekdays ?? [], now: now)
    }

    /// Where runs go; nil when the companion's chat doesn't exist yet or no chat is set.
    func target(companionChat: (workspace: String, thread: String)?) -> ScheduleTarget? {
        switch sendTo {
        case .companion:
            guard let chat = companionChat else { return nil }
            return ScheduleTarget(kind: "thread", workspace_id: chat.workspace, thread_id: chat.thread)
        case .existing:
            guard !threadID.isEmpty else { return nil }
            return ScheduleTarget(kind: "thread", workspace_id: threadWorkspaceID, thread_id: threadID)
        case .newChat:
            return ScheduleTarget(kind: "new_chat", workspace_id: workspaceID, provider: provider, model: model.isEmpty ? nil : model)
        }
    }

    /// `schedule_create`. Runs report back to the companion's chat (`parent_*`) when it exists;
    /// a blank name is omitted so the daemon names the task from the prompt.
    func createEvent(intentID: String, companionChat: (workspace: String, thread: String)?) -> EventScheduleCreate? {
        guard let target = self.target(companionChat: companionChat) else { return nil }
        return EventScheduleCreate(now_ms: 0, wall_time_ms: 0, intent_id: intentID,
                                   name: cleanName.isEmpty ? nil : cleanName,
                                   prompt: cleanPrompt, target: target, `repeat`: repeatValue(), enabled: enabled,
                                   parent_workspace_id: companionChat?.workspace, parent_thread_id: companionChat?.thread)
    }

    private var targetKey: String {
        switch sendTo {
        case .companion: return "companion"
        case .existing: return "existing|\(threadWorkspaceID)|\(threadID)"
        case .newChat: return "new_chat|\(workspaceID)|\(provider)|\(model)"
        }
    }

    private var repeatKey: String {
        let value = repeatValue()
        return [value.kind, value.at_ms.map { String($0) } ?? "", value.every_minutes.map { String($0) } ?? "",
                value.time ?? "", (value.weekdays ?? []).map { String($0) }.joined(separator: ",")].joined(separator: "|")
    }

    /// `schedule_update` with only what changed since `original`; nil when the new target can't be
    /// built. A cleared name keeps the old one (the daemon requires a name).
    func updateEvent(intentID: String, id: String, original: ScheduleDraft,
                     companionChat: (workspace: String, thread: String)?) -> EventScheduleUpdate? {
        var event = EventScheduleUpdate(now_ms: 0, wall_time_ms: 0, intent_id: intentID, id: id)
        if !cleanName.isEmpty && cleanName != original.cleanName { event.name = cleanName }
        if cleanPrompt != original.cleanPrompt { event.prompt = cleanPrompt }
        if targetKey != original.targetKey {
            guard let target = self.target(companionChat: companionChat) else { return nil }
            event.target = target
        }
        if repeatKey != original.repeatKey { event.`repeat` = repeatValue() }
        if enabled != original.enabled { event.enabled = enabled }
        return event
    }
}

/// An update that would change nothing.
func scheduleUpdateIsEmpty(_ event: EventScheduleUpdate) -> Bool {
    event.name == nil && event.prompt == nil && event.target == nil && event.`repeat` == nil && event.enabled == nil
}

// MARK: - Model

/// The `schedules` view for the selected host plus its intents. The list refreshes while the
/// Scheduled screen is visible; mutations wait for their receipt so the form can show the core's
/// validation message.
@MainActor @Observable
final class ScheduleModel {
    static let pollInterval: Duration = .seconds(15)
    static let timeout: Duration = .seconds(30)

    let browse: BrowseModel
    /// The last row action's failure (toggle, run, delete).
    var notice: String?
    @ObservationIgnored private var cache: (data: Data, view: SchedulesView)?
    /// The desktop clock of the last list and when this phone saw it.
    @ObservationIgnored private var clock: (hostMs: Int64, seenAt: Date)?

    init(browse: BrowseModel) { self.browse = browse }

    var view: SchedulesView? {
        guard let data = browse.hosts.session(browse.hostID)?.store.snapshots["schedules"] else { return nil }
        if let cache, cache.data == data { return cache.view }
        guard let decoded = (try? JSONDecoder().decode(SchedulesQuery.self, from: data))?.data else { return nil }
        cache = (data, decoded)
        if clock?.hostMs != decoded.now_ms { clock = (decoded.now_ms, Date()) }
        return decoded
    }

    /// Hosts without `schedule.*` hide the entry.
    var supported: Bool { view?.supported ?? true }
    var canEdit: Bool { view?.can_edit ?? false }
    var enabledCount: Int { view?.schedules.filter { $0.enabled }.count ?? 0 }

    func busy(_ id: String) -> Bool { view?.busy_ids.contains(id) ?? false }

    /// The chat this phone's latest Run now used, for "Open chat".
    func lastRun(_ id: String) -> ScheduleRun? {
        guard let run = view?.last_run, run.schedule_id == id, !run.workspace_id.isEmpty, !run.thread_id.isEmpty else { return nil }
        return run
    }

    /// The desktop's clock now: the last list's `now_ms` plus the time since it arrived, so
    /// "Next in …" ignores phone/desktop clock skew.
    func hostNow(_ now: Date = Date()) -> Int64 {
        _ = view
        guard let clock, clock.hostMs > 0 else { return Int64(now.timeIntervalSince1970 * 1000) }
        return clock.hostMs + Int64(max(0, now.timeIntervalSince(clock.seenAt)) * 1000)
    }

    func refresh(wait: Bool = false) async {
        let failure = await perform(wait: wait) { .schedule_refresh(EventScheduleRefresh(now_ms: 0, wall_time_ms: 0, intent_id: $0)) }
        if wait, let failure { notice = failure }
    }

    /// Refreshes every `interval` until cancelled (the screen went away or the app went inactive).
    func poll(every interval: Duration = ScheduleModel.pollInterval) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: interval)
        }
    }

    func setEnabled(_ id: String, _ enabled: Bool) async {
        notice = await perform { .schedule_update(EventScheduleUpdate(now_ms: 0, wall_time_ms: 0, intent_id: $0, id: id, enabled: enabled)) }
    }

    func run(_ id: String) async {
        notice = await perform { .schedule_run(EventScheduleRun(now_ms: 0, wall_time_ms: 0, intent_id: $0, id: id)) }
    }

    func delete(_ id: String) async {
        notice = await perform { .schedule_delete(EventScheduleDelete(now_ms: 0, wall_time_ms: 0, intent_id: $0, id: id)) }
    }

    /// Sends a create/update built for the given intent id; returns the message to show, nil on success.
    func save(_ make: (String) -> Event) async -> String? {
        await perform(make)
    }

    /// Sends one intent and, with `wait`, follows its receipt. Returns the failure text.
    private func perform(wait: Bool = true, _ make: (String) -> Event) async -> String? {
        guard let hostID = browse.hostID, let session = browse.hosts.session(hostID) else { return "Choose a paired host first." }
        await session.start()
        guard browse.hostID == hostID, let host = session.host else { return "The host is unavailable. Try again." }
        let intent = UUID().uuidString
        do { try await host.send(make(intent)) }
        catch CoreBridgeError.rejected { return "This change couldn't be sent. Update verde on the computer and try again." }
        catch { return "The host is unavailable. Try again." }
        guard wait else { return nil }
        let deadline = ContinuousClock.now.advanced(by: Self.timeout)
        while ContinuousClock.now < deadline && !Task.isCancelled {
            if let data = try? await host.query("operations"),
               let items = (try? JSONDecoder().decode(OperationsQuery.self, from: data))?.data?.items,
               let operation = items.first(where: { $0.intent_id == intent }),
               operation.state != "pending" {
                return scheduleFailureText(operation)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return Task.isCancelled ? nil : "Still waiting for the host. Refresh to check before retrying."
    }
}
