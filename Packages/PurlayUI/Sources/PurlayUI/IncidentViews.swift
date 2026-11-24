import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

extension ChannelIncident {
    /// "SEV1", the way an incident is named in the channel.
    var severityName: String {
        switch severity {
        case .v1: "SEV1"
        case .v2: "SEV2"
        case .v3: "SEV3"
        case .v4: "SEV4"
        case .unknown(let level): "SEV\(level)"
        }
    }

    var statusName: String {
        switch status {
        case .investigating: String(localized: "Investigating")
        case .mitigating: String(localized: "Mitigating")
        case .unknown: String(localized: "Open")
        }
    }

    /// The two most serious levels are red; the rest are orange.
    var tint: Color {
        switch severity {
        case .v1, .v2: .red
        default: .orange
        }
    }
}

/// An incident that is open in the channel on show: its level and state at the top of the conversation, and the way to the
/// browser where it is run (the timeline, the responders and the write-up live there).
struct IncidentBar: View {
    let model: AppModel
    let channel: Channel
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let incident = channel.incident {
            HStack(spacing: Spacing.space2) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(incident.tint)
                Text("Incident").fontWeight(.semibold)
                Text(incident.severityName).fontWeight(.semibold).foregroundStyle(incident.tint)
                Text("·").foregroundStyle(.secondary)
                Text(incident.statusName).foregroundStyle(.secondary)
                Spacer()
                if let url = model.webURL(.channel(channel.id)) {
                    Button("Open in Browser") { openURL(url) }.controlSize(.small)
                }
            }
            .font(.callout)
            .padding(.horizontal, Spacing.space4)
            .padding(.vertical, Spacing.space1 + Stroke.strokeFocus)
            .background(.bar)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Incident \(incident.severityName), \(incident.statusName)")
        }
    }
}
