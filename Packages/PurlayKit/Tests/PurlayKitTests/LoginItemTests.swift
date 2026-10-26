import Foundation
import Testing

@testable import PurlayKit

/// Opening at login: the system keeps it, the app asks and shows what the system answered, never what it hoped for.
@MainActor
@Suite("launch at login")
struct LoginItemTests {
    @Test("it starts as the system says, and turning it on registers once and shows it on")
    func turnsOn() async {
        let h = ModelHarness()
        await h.signedIn()
        #expect(h.model.launchAtLogin == .off)
        h.model.setLaunchAtLogin(true)
        #expect(h.loginItem.calls == [true])
        #expect(h.model.launchAtLogin == .on)
        h.model.setLaunchAtLogin(false)
        #expect(h.model.launchAtLogin == .off)
    }

    @Test("what the system wants approval for is shown as that, with the way to where it is approved")
    func approval() async {
        let h = ModelHarness()
        h.loginItem.needsApproval = true
        h.model.setLaunchAtLogin(true)
        #expect(h.model.launchAtLogin == .requiresApproval)
        h.model.openLoginItemSettings()
        #expect(h.loginItem.settingsOpened == 1)
    }

    @Test("a refusal is said, and the setting shows what the system holds, not what was asked")
    func refusal() async {
        let h = ModelHarness()
        h.loginItem.refuses = true
        h.model.setLaunchAtLogin(true)
        #expect(h.model.launchAtLogin == .off)
        #expect(h.model.notices.map(\.kind).contains(.loginItemFailed))
    }

    @Test("looking again reads what the system holds now: the person may have changed it in System Settings")
    func refresh() async {
        let h = ModelHarness()
        h.model.refreshLoginItem()
        #expect(h.model.launchAtLogin == .off)
        h.loginItem.current = .on
        h.model.refreshLoginItem()
        #expect(h.model.launchAtLogin == .on)
    }

    @Test("a build that has no login item says so and offers nothing")
    func unavailable() async {
        let h = ModelHarness()
        h.loginItem.current = .unavailable
        h.model.refreshLoginItem()
        #expect(h.model.launchAtLogin == .unavailable)
    }
}
