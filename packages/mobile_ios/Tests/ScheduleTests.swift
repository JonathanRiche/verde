import XCTest
@testable import VerdeApp

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()
private let posix = Locale(identifier: "en_US_POSIX")
/// Monday 2026-10-19 10:00 UTC.
private let monday = Date(timeIntervalSince1970: 1_792_404_000)
private let mondayMs: Int64 = 1_792_404_000_000
private let companionChat = (workspace: "ws-home", thread: "web-thread-1")

private func entry(_ json: String) throws -> ScheduleEntry {
    try JSONDecoder().decode(ScheduleEntry.self, from: Data(json.utf8))
}

private func repeatText(_ kind: String, at: Int64? = nil, every: UInt32? = nil, time: String = "", days: [UInt16] = [],
                        now: Date = monday) -> String {
    scheduleRepeatText(kind: kind, atMs: at, everyMinutes: every, time: time, weekdays: days, now: now, calendar: utc, locale: posix)
}

final class ScheduleFormattingTests: XCTestCase {
    func testDailyRepeatNamesTheDays() {
        XCTAssertEqual(repeatText("daily", time: "09:00", days: [1, 2, 3, 4, 5]), "Weekdays at 09:00")
        XCTAssertEqual(repeatText("daily", time: "09:00", days: [5, 1, 3, 2, 4, 4]), "Weekdays at 09:00")
        XCTAssertEqual(repeatText("daily", time: "07:30"), "Daily at 07:30")
        XCTAssertEqual(repeatText("daily", time: "07:30", days: [0, 1, 2, 3, 4, 5, 6]), "Daily at 07:30")
        XCTAssertEqual(repeatText("daily", time: "10:00", days: [6, 0]), "Weekends at 10:00")
        XCTAssertEqual(repeatText("daily", time: "18:00", days: [3]), "Wednesdays at 18:00")
        XCTAssertEqual(repeatText("daily", time: "08:15", days: [0, 1, 5]), "Mon, Fri, Sun at 08:15")
    }

    func testIntervalRepeatUsesTheLargestWholeUnit() {
        XCTAssertEqual(repeatText("interval", every: 5), "Every 5 minutes")
        XCTAssertEqual(repeatText("interval", every: 60), "Every hour")
        XCTAssertEqual(repeatText("interval", every: 120), "Every 2 hours")
        XCTAssertEqual(repeatText("interval", every: 90), "Every 90 minutes")
        XCTAssertEqual(repeatText("interval", every: 1440), "Every day")
        XCTAssertEqual(repeatText("interval", every: 10080), "Every 7 days")
        XCTAssertEqual(repeatText("interval"), "Repeats")
    }

    func testOnceShowsTheDayAndTime() {
        XCTAssertEqual(repeatText("once", at: 1_792_420_200_000), "Once · Today 14:30")
        XCTAssertEqual(repeatText("once", at: 1_792_506_600_000), "Once · Tomorrow 14:30")
        XCTAssertEqual(repeatText("once", at: 1_792_506_600_000, now: monday.addingTimeInterval(-86_400)), "Once · Tue 14:30")
        XCTAssertEqual(repeatText("once", at: 1_792_679_400_000), "Once · Thu 14:30")
        XCTAssertEqual(repeatText("once", at: 1_796_135_400_000), "Once · Dec 1, 14:30")
        XCTAssertEqual(repeatText("once", at: 1_798_963_500_000), "Once · Jan 3, 2027, 08:05")
        XCTAssertEqual(repeatText("once"), "Once")
    }

    func testNextRunCountsFromTheDesktopClock() {
        XCTAssertEqual(scheduleNextText(enabled: true, nextMs: mondayMs + 3 * 3_600_000, nowMs: mondayMs), "Next in 3h")
        XCTAssertEqual(scheduleNextText(enabled: true, nextMs: mondayMs + 3 * 3_600_000 + 20 * 60_000, nowMs: mondayMs), "Next in 3h 20m")
        XCTAssertEqual(scheduleNextText(enabled: true, nextMs: mondayMs + 45 * 60_000, nowMs: mondayMs), "Next in 45m")
        XCTAssertEqual(scheduleNextText(enabled: true, nextMs: mondayMs + 30_000, nowMs: mondayMs), "Next in 1m")
        XCTAssertEqual(scheduleNextText(enabled: true, nextMs: mondayMs + 26 * 3_600_000, nowMs: mondayMs), "Next in 1d 2h")
        XCTAssertEqual(scheduleNextText(enabled: true, nextMs: mondayMs + 48 * 3_600_000, nowMs: mondayMs), "Next in 2d")
        XCTAssertEqual(scheduleNextText(enabled: true, nextMs: mondayMs - 1_000, nowMs: mondayMs), "Due now")
        XCTAssertEqual(scheduleNextText(enabled: true, nextMs: nil, nowMs: mondayMs), "Not scheduled")
        XCTAssertEqual(scheduleNextText(enabled: false, nextMs: mondayMs + 60_000, nowMs: mondayMs), "Paused")
    }

    func testLastStatus() {
        var row = ScheduleEntry(id: "s1")
        XCTAssertEqual(scheduleStatusText(row, nowMs: mondayMs).text, "Never run")
        XCTAssertEqual(scheduleStatusText(row, nowMs: mondayMs).tone, .quiet)
        row.last_run_ms = mondayMs - 2 * 3_600_000
        row.last_status = "ok"
        XCTAssertEqual(scheduleStatusText(row, nowMs: mondayMs).text, "Ran 2 h ago")
        XCTAssertEqual(scheduleStatusText(row, nowMs: mondayMs).tone, .ok)
        row.last_status = "queued"
        XCTAssertEqual(scheduleStatusText(row, nowMs: mondayMs).text, "Queued 2 h ago")
        XCTAssertEqual(scheduleStatusText(row, nowMs: mondayMs).tone, .attention)
        row.last_status = "late"
        XCTAssertEqual(scheduleStatusText(row, nowMs: mondayMs).text, "Ran late 2 h ago")
        row.last_status = "failed"
        XCTAssertEqual(scheduleStatusText(row, nowMs: mondayMs).text, "Failed 2 h ago")
        XCTAssertEqual(scheduleStatusText(row, nowMs: mondayMs).tone, .failure)
    }

    func testViewRowsDecodeAndFormat() throws {
        let json = #"""
        {"api_version":1,"revision":"4","data":{"loaded":true,"can_edit":true,"now_ms":1792404000000,
         "schedules":[{"id":"a","name":"","prompt":"Check CI\nthen report","repeat_kind":"interval","repeat_every_minutes":120,
          "enabled":true,"next_run_ms":1792411200000,"last_status":"failed","last_error":"provider offline","last_run_ms":1792400400000}],
         "busy_ids":["a"],"last_run":{"intent_id":"i","schedule_id":"a","workspace_id":"ws","thread_id":"t"}},"error":null}
        """#
        let view = try XCTUnwrap(JSONDecoder().decode(SchedulesQuery.self, from: Data(json.utf8)).data)
        let row = try XCTUnwrap(view.schedules.first)
        XCTAssertEqual(scheduleTitle(row), "Check CI")
        XCTAssertEqual(scheduleRepeatText(row), "Every 2 hours")
        XCTAssertEqual(scheduleNextText(enabled: row.enabled, nextMs: row.next_run_ms, nowMs: view.now_ms), "Next in 2h")
        XCTAssertEqual(scheduleStatusText(row, nowMs: view.now_ms).text, "Failed 1 h ago")
        XCTAssertEqual(row.target_kind, "thread")
        XCTAssertEqual(view.busy_ids, ["a"])
        XCTAssertEqual(view.last_run?.thread_id, "t")
    }
}

final class ScheduleFormTests: XCTestCase {
    func testCompanionChatIsTheTargetAndTheParent() throws {
        var draft = ScheduleDraft(now: monday)
        draft.prompt = "  Check CI and tell me what failed.\n"
        draft.name = "   "
        let event = try XCTUnwrap(draft.createEvent(intentID: "i1", companionChat: companionChat))
        XCTAssertEqual(event.intent_id, "i1")
        XCTAssertNil(event.name, "a blank name lets the daemon name it from the prompt")
        XCTAssertEqual(event.prompt, "Check CI and tell me what failed.")
        XCTAssertEqual(event.target.kind, "thread")
        XCTAssertEqual(event.target.workspace_id, "ws-home")
        XCTAssertEqual(event.target.thread_id, "web-thread-1")
        XCTAssertNil(event.target.provider)
        XCTAssertEqual(event.parent_workspace_id, "ws-home")
        XCTAssertEqual(event.parent_thread_id, "web-thread-1")
        XCTAssertEqual(event.`repeat`.kind, "daily")
        XCTAssertEqual(event.`repeat`.time, "09:00")
        XCTAssertEqual(event.`repeat`.weekdays, [1, 2, 3, 4, 5])
        XCTAssertNil(event.`repeat`.at_ms)
        XCTAssertNil(event.`repeat`.every_minutes)
        XCTAssertEqual(event.enabled, true)

        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Event.schedule_create(event))) as? [String: Any])
        XCTAssertEqual(wire["type"] as? String, "schedule_create")
        XCTAssertEqual((wire["target"] as? [String: Any])?["thread_id"] as? String, "web-thread-1")
        XCTAssertEqual((wire["repeat"] as? [String: Any])?["time"] as? String, "09:00")

        XCTAssertNil(draft.createEvent(intentID: "i2", companionChat: nil), "the companion's chat must exist first")
    }

    func testNewChatCarriesProviderAndOptionalModel() throws {
        var draft = ScheduleDraft(now: monday)
        draft.prompt = "Summarize yesterday's commits."
        draft.name = " Daily digest "
        draft.sendTo = .newChat
        draft.workspaceID = "ws-api"
        draft.provider = "claude"
        draft.repeatKind = .interval
        draft.unit = .hours
        draft.every = 2
        var event = try XCTUnwrap(draft.createEvent(intentID: "i3", companionChat: companionChat))
        XCTAssertEqual(event.name, "Daily digest")
        XCTAssertEqual(event.target.kind, "new_chat")
        XCTAssertEqual(event.target.workspace_id, "ws-api")
        XCTAssertEqual(event.target.provider, "claude")
        XCTAssertNil(event.target.model)
        XCTAssertNil(event.target.thread_id)
        XCTAssertEqual(event.parent_thread_id, "web-thread-1", "new chats report back to the companion")
        XCTAssertEqual(event.`repeat`.kind, "interval")
        XCTAssertEqual(event.`repeat`.every_minutes, 120)
        XCTAssertNil(event.`repeat`.time)

        draft.model = "opus"
        draft.unit = .minutes
        draft.every = 45
        event = try XCTUnwrap(draft.createEvent(intentID: "i4", companionChat: nil))
        XCTAssertEqual(event.target.model, "opus")
        XCTAssertEqual(event.`repeat`.every_minutes, 45)
        XCTAssertNil(event.parent_thread_id)
        XCTAssertNil(event.parent_workspace_id)
    }

    func testOnceAndDailyRepeats() {
        var draft = ScheduleDraft(now: monday)
        draft.repeatKind = .once
        draft.at = Date(timeIntervalSince1970: 1_792_506_642.75)
        XCTAssertEqual(draft.repeatValue().kind, "once")
        XCTAssertEqual(draft.repeatValue().at_ms, 1_792_506_600_000, "whole minutes")
        XCTAssertNil(draft.repeatValue().weekdays)

        draft.repeatKind = .daily
        draft.hour = 7
        draft.minute = 5
        draft.weekdays = Set(0...6)
        XCTAssertEqual(draft.repeatValue().time, "07:05")
        XCTAssertEqual(draft.repeatValue().weekdays, [], "all seven days is every day")
        XCTAssertEqual(draft.repeatText(now: monday), "Daily at 07:05")
        draft.weekdays = [6, 0]
        XCTAssertEqual(draft.repeatValue().weekdays, [0, 6])

        // A new task defaults to an hour ahead, on a 5-minute boundary.
        XCTAssertEqual(ScheduleDraft(now: Date(timeIntervalSince1970: 1_792_404_061)).at.timeIntervalSince1970, 1_792_407_900)
    }

    func testIntervalUnitChangeKeepsTheDuration() {
        XCTAssertEqual(scheduleConvertEvery(2, from: .hours, to: .minutes), 120)
        XCTAssertEqual(scheduleConvertEvery(90, from: .minutes, to: .hours), 2)
        XCTAssertEqual(scheduleConvertEvery(10, from: .minutes, to: .hours), 1)
        XCTAssertEqual(scheduleConvertEvery(2, from: .minutes, to: .minutes), 5, "minimum 5 minutes")
        XCTAssertEqual(scheduleConvertEvery(200, from: .hours, to: .hours), 168, "maximum 7 days")
    }

    func testCanSaveNeedsAPromptAndACompleteTarget() {
        var draft = ScheduleDraft(now: monday)
        XCTAssertFalse(draft.canSave)
        draft.prompt = "Ping"
        XCTAssertTrue(draft.canSave)
        draft.sendTo = .newChat
        XCTAssertFalse(draft.canSave)
        draft.workspaceID = "ws"
        draft.provider = "codex"
        XCTAssertTrue(draft.canSave)
    }

    func testEditSendsOnlyWhatChanged() throws {
        let row = try entry(#"{"id":"sch-1","name":"Morning CI","prompt":"Check CI.","target_kind":"thread","target_workspace_id":"ws-home","target_thread_id":"web-thread-1","repeat_kind":"daily","repeat_time":"09:00","repeat_weekdays":[1,2,3,4,5],"enabled":true}"#)
        let original = ScheduleDraft(entry: row, companionChat: companionChat, now: monday)
        XCTAssertEqual(original.sendTo, .companion)
        XCTAssertEqual(original.repeatKind, .daily)
        XCTAssertEqual(original.hour, 9)
        XCTAssertEqual(original.minute, 0)
        XCTAssertEqual(original.weekdays, [1, 2, 3, 4, 5])
        let unchanged = try XCTUnwrap(original.updateEvent(intentID: "u0", id: "sch-1", original: original, companionChat: companionChat))
        XCTAssertTrue(scheduleUpdateIsEmpty(unchanged))

        var edited = original
        edited.weekdays.insert(6)
        edited.prompt = "Check CI and lint."
        let update = try XCTUnwrap(edited.updateEvent(intentID: "u1", id: "sch-1", original: original, companionChat: companionChat))
        XCTAssertEqual(update.id, "sch-1")
        XCTAssertEqual(update.intent_id, "u1")
        XCTAssertEqual(update.prompt, "Check CI and lint.")
        XCTAssertNil(update.name)
        XCTAssertNil(update.target)
        XCTAssertNil(update.enabled)
        XCTAssertEqual(update.`repeat`?.time, "09:00")
        XCTAssertEqual(update.`repeat`?.weekdays, [1, 2, 3, 4, 5, 6])
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Event.schedule_update(update))) as? [String: Any])
        XCTAssertEqual(wire["type"] as? String, "schedule_update")

        var moved = original
        moved.sendTo = .newChat
        moved.workspaceID = "ws-api"
        moved.provider = "codex"
        moved.enabled = false
        let retarget = try XCTUnwrap(moved.updateEvent(intentID: "u2", id: "sch-1", original: original, companionChat: companionChat))
        XCTAssertEqual(retarget.target?.kind, "new_chat")
        XCTAssertEqual(retarget.target?.provider, "codex")
        XCTAssertEqual(retarget.enabled, false)
        XCTAssertNil(retarget.`repeat`)

        var renamed = original
        renamed.name = "  "
        XCTAssertTrue(scheduleUpdateIsEmpty(try XCTUnwrap(renamed.updateEvent(intentID: "u3", id: "sch-1", original: original,
                                                                              companionChat: companionChat))),
                      "a cleared name keeps the old one")
    }

    func testEditKeepsAnotherChatAndReadsIntervalsAndOnce() throws {
        let other = try entry(#"{"id":"sch-2","prompt":"Ping.","target_kind":"thread","target_workspace_id":"ws-x","target_thread_id":"t-9","repeat_kind":"interval","repeat_every_minutes":45,"enabled":false}"#)
        let draft = ScheduleDraft(entry: other, companionChat: companionChat, now: monday)
        XCTAssertEqual(draft.sendTo, .existing)
        XCTAssertEqual(draft.unit, .minutes)
        XCTAssertEqual(draft.every, 45)
        XCTAssertFalse(draft.enabled)
        let target = try XCTUnwrap(draft.target(companionChat: companionChat))
        XCTAssertEqual(target.workspace_id, "ws-x")
        XCTAssertEqual(target.thread_id, "t-9")

        let hourly = try entry(#"{"id":"sch-3","prompt":"x","target_kind":"new_chat","target_workspace_id":"ws","target_provider":"claude","target_model":"opus","repeat_kind":"interval","repeat_every_minutes":180}"#)
        let hourlyDraft = ScheduleDraft(entry: hourly, companionChat: nil, now: monday)
        XCTAssertEqual(hourlyDraft.sendTo, .newChat)
        XCTAssertEqual(hourlyDraft.model, "opus")
        XCTAssertEqual(hourlyDraft.unit, .hours)
        XCTAssertEqual(hourlyDraft.every, 3)

        let once = try entry(#"{"id":"sch-4","prompt":"x","repeat_kind":"once","repeat_at_ms":1792506600000}"#)
        let onceDraft = ScheduleDraft(entry: once, companionChat: nil, now: monday)
        XCTAssertEqual(onceDraft.repeatKind, .once)
        XCTAssertEqual(onceDraft.repeatValue().at_ms, 1_792_506_600_000)
    }
}

@MainActor
final class ScheduleModelTests: XCTestCase {
    func testRefreshSendsTheIntentAndShowsNothingBeforeAList() async throws {
        let harness = ChatHarness()
        try await harness.launch()
        let model = ScheduleModel(browse: harness.browse)
        XCTAssertNil(model.view)
        XCTAssertTrue(model.supported)
        XCTAssertFalse(model.canEdit)
        XCTAssertEqual(model.enabledCount, 0)
        await model.refresh()
        let refreshes = harness.core.events.all.compactMap { event -> EventScheduleRefresh? in
            if case .schedule_refresh(let value) = event { return value }
            return nil
        }
        XCTAssertEqual(refreshes.count, 1)
        XCTAssertNil(refreshes.first?.workspace_id)
        await harness.close()
    }
}
