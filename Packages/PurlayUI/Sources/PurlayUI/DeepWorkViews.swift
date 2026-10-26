import PurlayKit
import SwiftUI

/// The quiet bar that says Deep Work is on, until when, with End (`UX.md` §8: a mode you can forget you are in is a mode that loses you
/// messages). The mention badges are not drawn while it lasts; the counts are kept, so they are all there when it ends.
struct DeepWorkBar: View {
    let model: AppModel

    var body: some View {
        if let end = model.deepWorkEnds {
            // The minutes are asked when drawn, and drawn again each half minute, and at the instant it ends the bar is gone.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                HStack(spacing: 8) {
                    Image(systemName: "moon.fill")
                    Text("Deep Work until \(end, style: .time)")
                    Text("·").foregroundStyle(.secondary)
                    Text("\(model.deepWorkMinutesLeft) min left").foregroundStyle(.secondary)
                    Spacer()
                    Button("End") { Task { await model.endDeepWork() } }.controlSize(.small)
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.indigo.opacity(0.18))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// What the person can do about Deep Work, as menu items: off, each while to start it for; on, the end and what is left. The same items
/// serve the account menu and the menu bar.
public struct DeepWorkItems: View {
    let model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        if model.deepWorkEnds != nil {
            Button("End Deep Work (\(model.deepWorkMinutesLeft) min left)") { Task { await model.endDeepWork() } }
        } else {
            Button("Deep Work for 30 Minutes") { Task { await model.startDeepWork(.halfHour) } }
            Button("Deep Work for an Hour") { Task { await model.startDeepWork(.hour) } }
            Button("Deep Work for 2 Hours") { Task { await model.startDeepWork(.twoHours) } }
            Button("Deep Work Until Tomorrow") { Task { await model.startDeepWork(.untilTomorrow) } }
        }
    }
}
