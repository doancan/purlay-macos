import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// Deep Work (D-15, D-108): the server keeps the state and holds back what would interrupt; here the person starts and ends it, sees until
/// when, and the badge keeps quiet. Ported from `apps/web/src/features/shell/deep-work.test.tsx`.
@Suite("how long Deep Work lasts")
struct DeepWorkLengthTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        return calendar
    }

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    @Test("a while is that long from now")
    func whiles() {
        for (length, minutes) in [(DeepWork.Length.halfHour, 30), (.hour, 60), (.twoHours, 120)] {
            #expect(
                DeepWork.end(of: length, from: at(15), calendar: calendar).timeIntervalSince(at(15))
                    == Double(minutes * 60))
        }
    }

    @Test("until tomorrow is nine tomorrow morning, in the person's own time")
    func tomorrow() {
        #expect(DeepWork.end(of: .untilTomorrow, from: at(15), calendar: calendar) == at(9, day: 10))
        #expect(DeepWork.end(of: .untilTomorrow, from: at(23), calendar: calendar) == at(9, day: 10))
    }

    @Test("after midnight and before five the night is not over: tomorrow is this morning")
    func smallHours() {
        #expect(DeepWork.end(of: .untilTomorrow, from: at(1), calendar: calendar) == at(9))
        #expect(DeepWork.end(of: .untilTomorrow, from: at(0), calendar: calendar) == at(9))
        #expect(DeepWork.end(of: .untilTomorrow, from: at(4, 59), calendar: calendar) == at(9))
        #expect(calendar.component(.day, from: DeepWork.end(of: .untilTomorrow, from: at(5), calendar: calendar)) == 10)
    }

    @Test("never further than the server allows, with room for a clock a little ahead")
    func bounded() {
        let now = at(8)
        let end = DeepWork.end(of: .untilTomorrow, from: now, calendar: calendar)
        #expect(end.timeIntervalSince(now) <= Double(ContractConstants.deepWorkMaxHours) * 3_600 - 5 * 60)
    }

    @Test("the minutes left are whole, at least one while it lasts, and none when it is over or off")
    func minutes() {
        let now = at(10)
        #expect(DeepWork.minutesLeft(until: now.addingTimeInterval(61), now: now) == 2)
        #expect(DeepWork.minutesLeft(until: now.addingTimeInterval(1), now: now) == 1)
        #expect(DeepWork.minutesLeft(until: now.addingTimeInterval(3_600), now: now) == 60)
        #expect(DeepWork.minutesLeft(until: now, now: now) == 0)
        #expect(DeepWork.minutesLeft(until: now.addingTimeInterval(-5), now: now) == 0)
        #expect(DeepWork.minutesLeft(until: nil, now: now) == 0)
    }
}

@MainActor
@Suite("starting and ending Deep Work")
struct DeepWorkModelTests {
    private func signedIn(until: String? = nil) async -> ModelHarness {
        let h = ModelHarness()
        h.server.edit { $0.deepWorkUntil = until }
        await h.signedIn()
        return h
    }

    private func puts(_ h: ModelHarness) -> [HTTPRequest] {
        h.server.requests.filter { $0.method == "PUT" && $0.url.path.hasSuffix("/deep-work") }
    }

    private func body(_ request: HTTPRequest?) -> [String: Any] {
        request?.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    @Test("off at first: nothing to read, no minutes")
    func off() async {
        let h = await signedIn()
        #expect(h.model.deepWorkEnds == nil)
        #expect(h.model.deepWorkMinutesLeft == 0)
    }

    @Test("starting asks the server for the instant the choice ends at, and is painted at once")
    func starts() async {
        let h = await signedIn()
        await h.model.startDeepWork(.hour)
        let request = body(puts(h).first)
        #expect(request["active"] as? Bool == true)
        let until = (request["until"] as? String).flatMap(Timestamp.init)
        #expect(until != nil)
        if let until { #expect(abs(until.date.timeIntervalSince(h.model.deepWorkEnds ?? .distantPast)) < 1) }
        #expect(h.model.deepWorkMinutesLeft > 0)
    }

    @Test("ending asks the server to stop, and is painted at once")
    func ends() async {
        let h = await signedIn(until: "2099-01-01T00:00:00.000Z")
        #expect(h.model.deepWorkEnds != nil)
        await h.model.endDeepWork()
        #expect(body(puts(h).first)["active"] as? Bool == false)
        #expect(h.model.deepWorkEnds == nil)
    }

    @Test("the shortcut starts it for an hour, and ends it the second time")
    func toggles() async {
        let h = await signedIn()
        await h.model.toggleDeepWork()
        #expect(h.model.deepWorkEnds != nil)
        await h.model.toggleDeepWork()
        #expect(h.model.deepWorkEnds == nil)
        #expect(puts(h).count == 2)
    }

    @Test("a refusal puts it back as it was, and says so")
    func refused() async {
        let h = await signedIn()
        h.server.edit { $0.deepWorkStatus = 400 }
        await h.model.startDeepWork(.hour)
        #expect(h.model.deepWorkEnds == nil)
        #expect(h.model.notices.map(\.kind).contains(.deepWorkFailed))
        let on = await signedIn(until: "2099-01-01T00:00:00.000Z")
        on.server.edit { $0.deepWorkStatus = 500 }
        await on.model.endDeepWork()
        #expect(on.model.deepWorkEnds != nil, "put back on")
        #expect(on.model.notices.map(\.kind).contains(.deepWorkFailed))
    }

    @Test("one that is over is not on: a Deep Work in the past reads as none")
    func over() async {
        let h = await signedIn(until: "2001-01-01T00:00:00.000Z")
        #expect(h.model.deepWorkEnds == nil)
    }

    @Test("while it lasts the badge is not drawn, and when it ends by hand the count is all there")
    func badge() async {
        let h = ModelHarness()
        h.server.edit { $0.chans = [.init(n: 1, name: "api", mentions: 3)] }
        await h.signedIn()
        #expect(h.attention.badge == 3)
        await h.model.startDeepWork(.halfHour)
        #expect(h.attention.badge == nil)
        await h.model.endDeepWork()
        #expect(h.attention.badge == 3)
    }

    @Test("signing out forgets it: the next person does not see this one's Deep Work")
    func signOut() async {
        let h = await signedIn(until: "2099-01-01T00:00:00.000Z")
        _ = await h.model.signOut(.thisDevice)
        #expect(h.model.deepWorkEnds == nil)
    }
}
