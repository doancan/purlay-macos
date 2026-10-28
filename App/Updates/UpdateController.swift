import Combine
import Sparkle
import SwiftUI

/// Sparkle stays in the app shell; the chat packages know nothing about updating executables.
@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates = false {
        didSet {
            if automaticallyChecksForUpdates != controller.updater.automaticallyChecksForUpdates {
                controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            }
        }
    }
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .removeDuplicates()
            .assign(to: &$automaticallyChecksForUpdates)
        #if !DEBUG
            controller.startUpdater()
        #endif
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

struct UpdateMenuItem: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        Button("Check for Updates…", action: updates.checkForUpdates)
            .disabled(!updates.canCheckForUpdates)
    }
}

struct UpdateSettings: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        Form {
            Section("Software Updates") {
                Toggle("Automatically check for updates", isOn: $updates.automaticallyChecksForUpdates)
                UpdateMenuItem(updates: updates)
                Text("Updates are downloaded from Purlay’s GitHub releases and verified before installation.")
                    .font(.caption).foregroundStyle(.secondary)
                #if DEBUG
                    Text("Update checks are disabled in development builds.")
                        .font(.caption).foregroundStyle(.secondary)
                #endif
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 220)
    }
}
