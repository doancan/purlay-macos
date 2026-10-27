import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

struct SheetHeading: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let image: String

    var body: some View {
        HStack(spacing: Spacing.space3) {
            Image(systemName: image)
                .font(.title3.weight(.medium)).foregroundStyle(Colors.accentText.style)
                .frame(width: Size.sizeRailItem, height: Size.sizeRailItem)
                .background(Colors.accentSubtle.style, in: .rect(cornerRadius: Radius.radius2xl))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.space1) {
                Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// The small parts every screen is built from: a person's face, whether they are here, a count. Each takes its sizes and colours
// from the tokens, so the sidebar, the feed and the thread draw a person the same way.

/// A person's picture, or their initials on a colour of their own when there is no picture (or it does not load). The colour is
/// chosen from the person's id, so the same person is the same colour everywhere and on every launch.
struct Avatar: View {
    let name: String
    let id: String?
    let picture: String?
    var size: Double = Size.sizeAvatarLg

    init(user: User?, size: Double = Size.sizeAvatarLg) {
        name = user?.displayName ?? ""
        id = user?.id.value
        picture = user?.avatarUrl
        self.size = size
    }

    init(current: CurrentUser?, size: Double = Size.sizeAvatarLg) {
        name = current?.displayName ?? ""
        id = current?.id.value
        picture = current?.avatarUrl
        self.size = size
    }

    var body: some View {
        ZStack {
            Circle().fill(background.style)
            Text(initials)
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(Colors.ink.style)
                .minimumScaleFactor(0.5)
            if let url = pictureURL {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.15))) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                }
                .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Only an absolute web address is fetched: a relative or odd value is the initials, not a request somewhere unexpected.
    private var pictureURL: URL? {
        guard let text = picture, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http", url.host != nil
        else { return nil }
        return url
    }

    private var initials: String { Self.initials(name) }

    private var background: TokenColor {
        let colours = [Colors.avatar1, Colors.avatar2, Colors.avatar3, Colors.avatar4, Colors.avatar5, Colors.avatar6]
        guard let id else { return Colors.avatar1 }
        let sum = id.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0x7fff_ffff }
        return colours[sum % colours.count]
    }

    /// Two letters, as the web draws them: the first of the first two words, or the first two of a single word.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" || $0 == "." })
        let letters: String
        switch words.count {
        case 0: letters = "?"
        case 1: letters = String(words[0].prefix(2))
        default: letters = String(words[0].prefix(1)) + String(words[1].prefix(1))
        }
        return letters.uppercased(with: Locale.current)
    }
}

/// A person's face with whether they are here, as a dot at its corner. Presence is decoration (`UX.md` §2): it is never the
/// only way something is said, so VoiceOver hears it with the name.
struct PresenceAvatar: View {
    let avatar: Avatar
    let online: Bool

    init(user: User?, online: Bool, size: Double = Size.sizeAvatarSm) {
        avatar = Avatar(user: user, size: size)
        self.online = online
    }

    init(current: CurrentUser?, online: Bool, size: Double = Size.sizeAvatarSm) {
        avatar = Avatar(current: current, size: size)
        self.online = online
    }

    private var size: Double { avatar.size }

    var body: some View {
        avatar
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(online ? Colors.success.style : Colors.borderStrong.style)
                    .frame(width: size * 0.36, height: size * 0.36)
                    .overlay(Circle().stroke(Colors.navSurface.style, lineWidth: Stroke.strokeFocus))
                    .offset(x: Stroke.strokeHairline, y: Stroke.strokeHairline)
            }
    }
}

/// A count of what needs the person: a capsule in the accent, drawn only when there is something to count.
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(Typography.caption.font.weight(.semibold).monospacedDigit())
            .foregroundStyle(Colors.onAccent.style)
            .padding(.horizontal, Spacing.space1 + Stroke.strokeFocus)
            .frame(minWidth: Size.sizeBadge, minHeight: Size.sizeBadge)
            .background(Colors.accent.style, in: Capsule())
            .accessibilityLabel(Text("\(count)"))
    }
}

/// A day between messages: "Today", "Yesterday", or the date, with a rule on either side, as the web separates days.
struct DayDivider: View {
    let date: Date

    var body: some View {
        HStack(spacing: Spacing.space3) {
            rule
            Text(label)
                .typeStyle(Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Colors.inkMuted.style)
                .padding(.horizontal, Spacing.space3)
                .padding(.vertical, Spacing.space1)
                .background(NativePalette.raised.style, in: Capsule())
            rule
        }
        .padding(.vertical, Spacing.space2)
        .padding(.horizontal, Spacing.space4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var rule: some View {
        Rectangle().fill(NativePalette.divider.style).frame(height: Stroke.strokeHairline)
    }

    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        let sameYear = calendar.isDate(date, equalTo: .now, toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.weekday(.wide).month(.wide).day() : .dateTime.year().month().day())
    }
}

/// The rule at the first message the person has not read: "New", in the danger colour, as the web marks it (UX §6).
struct NewDivider: View {
    var body: some View {
        HStack(spacing: Spacing.space2) {
            Rectangle().fill(Colors.danger.style).frame(height: Stroke.strokeHairline)
            Text("New")
                .typeStyle(Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Colors.dangerText.style)
        }
        .padding(.horizontal, Spacing.space4)
        .padding(.vertical, Spacing.space1)
        .accessibilityLabel(Text("New messages"))
    }
}
