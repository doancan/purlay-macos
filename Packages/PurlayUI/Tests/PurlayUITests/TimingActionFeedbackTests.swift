import Foundation
import PurlayKit
import Testing

@testable import PurlayUI

@MainActor
@Suite("message timing action feedback")
struct TimingActionFeedbackTests {
    @Test("a temporarily closed route has informational copy for the requested action")
    func temporarilyUnavailable() {
        #expect(TimingActionFeedback(SchedulingFailure.temporarilyUnavailable) == .schedulingUnavailable)
        #expect(TimingActionFeedback(ReminderFailure.temporarilyUnavailable) == .remindersUnavailable)
    }

    @Test("unsupported features, validation, access and connectivity still show the actual error")
    func ordinaryFailures() {
        let scheduling: [SchedulingFailure] = [.unavailable, .files, .time, .access, .failed, .sessionChanged]
        let reminders: [ReminderFailure] = [.unavailable, .time, .validation, .access, .failed, .sessionChanged]
        for failure in [scheduling as [any Error], reminders as [any Error]].joined() {
            #expect(TimingActionFeedback(failure) == .failure(failure.localizedDescription))
        }
    }
}
