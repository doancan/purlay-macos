import PurlayContract
import PurlayKit
import SwiftUI

/// What the connection is doing, said only when it is not simply working: a bar above the messages (§8).
struct ConnectionBar: View {
    let status: Connection.Status
    let degradedCount: Int
    let retry: () -> Void

    var body: some View {
        if let text {
            HStack(spacing: 8) {
                if status == .waiting || status == .connecting { ProgressView().controlSize(.small) }
                Text(text).font(.callout)
                Spacer()
                if degradedCount > 0 { Button("Retry", action: retry).buttonStyle(.link) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            .accessibilityElement(children: .combine)
        }
    }

    private var text: String? {
        switch status {
        case .waiting, .connecting:
            return String(localized: "Reconnecting… Messages you send will go when the connection is back.")
        case .ended:
            return String(localized: "Disconnected.")
        case .idle, .open:
            return degradedCount > 0 ? String(localized: "Some channels are not updating live.") : nil
        }
    }
}

struct NoticeBanner: View {
    let notice: Notice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Words.notice(notice.kind)).font(.callout)
            Spacer()
            Button("Dismiss", action: dismiss).buttonStyle(.link)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .accessibilityElement(children: .combine)
    }
}
