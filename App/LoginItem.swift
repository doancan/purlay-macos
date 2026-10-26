import PurlayKit
import ServiceManagement

/// The system's login item for this app: `SMAppService.mainApp`, which the person can also turn off in System Settings.
@MainActor
struct SystemLoginItem: LoginItemControl {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .off
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
