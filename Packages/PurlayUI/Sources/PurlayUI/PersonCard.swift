import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

/// Makes what it wraps open the card of a person: who they are, what they do, how they are, and what time it is for them.
struct PersonCardButton<Label: View>: View {
    let model: AppModel
    let user: User
    @ViewBuilder let label: () -> Label
    @State private var open = false

    var body: some View {
        Button { open = true } label: { label() }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) { PersonCard(model: model, user: user) { open = false } }
            .accessibilityHint("Shows this person’s profile")
    }
}

struct PersonCard: View {
    let model: AppModel
    let user: User
    let dismiss: () -> Void

    var body: some View {
        let card = model.memberCard(for: user.id)
        VStack(alignment: .leading, spacing: Spacing.space3) {
            HStack(spacing: Spacing.space3) {
                Avatar(user: user, size: Size.sizeAvatarLg * 1.6)
                VStack(alignment: .leading, spacing: 0) {
                    Text(user.displayName).typeStyle(Typography.title).lineLimit(2)
                    Text("@" + user.username).typeStyle(Typography.caption).foregroundStyle(.secondary)
                    if let title = card?.title { Text(title).font(.callout).foregroundStyle(.secondary) }
                }
            }
            if let card, card.status != nil || card.statusEmoji != nil {
                Label {
                    Text(card.status ?? "")
                } icon: {
                    Text(card.statusEmoji ?? "")
                }
                .font(.callout)
            }
            if let card, let zone = card.timeZone {
                TimelineView(.everyMinute) { context in
                    Label(localTime(card, zone: zone, at: context.date), systemImage: "clock")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if card?.isGuest == true {
                Label("Guest", systemImage: "person.badge.key").font(.callout).foregroundStyle(.secondary)
            }
            if user.id != model.me?.user.id {
                Button {
                    dismiss()
                    Task { await model.openConversation(with: [user]) }
                } label: {
                    Label("Message", systemImage: "bubble.left").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
        .padding(Spacing.space4)
        .frame(width: 280, alignment: .leading)
        .task { if card == nil { await model.refreshPeople() } }
    }

    /// "14:32 · 3 h ahead of you": the person's clock, and how it stands against this Mac's.
    private func localTime(_ card: MemberCard, zone: TimeZone, at date: Date) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
        guard let ahead = card.hoursAhead(of: .current, at: date), ahead != 0 else { return time }
        let hours = abs(ahead).formatted(.number.precision(.fractionLength(0...1)))
        return ahead > 0
            ? String(localized: "\(time) · \(hours) h ahead of you")
            : String(localized: "\(time) · \(hours) h behind you")
    }
}
