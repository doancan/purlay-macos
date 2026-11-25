import PurlayKit
import PurlayTokens
import SwiftUI

/// What the composer says about slash commands: what each one is, and what came of the one that was run.
enum SlashWords {
    static func summary(_ command: SlashCommand) -> LocalizedStringKey {
        switch command {
        case .me: "Say something as an action"
        case .shrug: "Add a shrug to your message"
        case .mute: "Mute this channel"
        case .unmute: "Get notified about mentions again"
        case .star: "Star this channel"
        case .unstar: "Remove the star from this channel"
        case .invite: "Add someone to this channel"
        case .leave: "Leave this channel"
        case .deepwork: "Start Deep Work, or end it with off"
        case .search: "Search messages"
        }
    }

    static func done(_ done: SlashResult.Done) -> LocalizedStringKey {
        switch done {
        case .muted: "Channel muted."
        case .unmuted: "Channel unmuted."
        case .starred: "Channel starred."
        case .unstarred: "Star removed."
        case .left: "You left the channel."
        case .deepWorkStarted: "Deep Work started."
        case .deepWorkEnded: "Deep Work ended."
        case .searched: "Searching…"
        case .invited(let name): "\(name) was added to the channel."
        }
    }

    static func refused(_ refusal: SlashResult.Refusal) -> LocalizedStringKey {
        switch refusal {
        case .usage(let command):
            switch command {
            case .me: "Say what you are doing: /me waves"
            case .invite: "Say who to add: /invite @handle"
            case .deepwork: "Use /deepwork for an hour, /deepwork 30m, 2h or tomorrow, or /deepwork off"
            case .search: "Say what to look for: /search words"
            default: "That command does not take words."
            }
        case .unknown(let name): "“/\(name)” is not a command. Start with // to send it as words."
        case .notMember: "You are not a member of this channel."
        case .nobody(let handle): "Nobody in this workspace has the handle @\(handle)."
        case .failed: "That did not work. Try again."
        }
    }
}

/// The commands the first word could be, above the box, as the list of people is for an `@`.
struct CommandList: View {
    let state: ComposerState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(state.commands.enumerated()), id: \.element) { index, command in
                Button {
                    state.chooseCommand?(command)
                } label: {
                    HStack(spacing: Spacing.space3) {
                        Text("/\(command.rawValue)")
                            .typeStyle(Typography.code).foregroundStyle(.primary)
                        Text(SlashWords.summary(command)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                    }
                    .typeStyle(Typography.body)
                    .padding(.horizontal, Spacing.space2)
                    .padding(.vertical, Spacing.space1)
                    .contentShape(.rect)
                    .background {
                        if index == state.highlighted {
                            RoundedRectangle(cornerRadius: Radius.radiusMd).fill(.fill.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(index == state.highlighted ? .isSelected : [])
            }
        }
        .padding(Spacing.space1)
        .modifier(ControlSurface(radius: Radius.radiusXl))
    }
}
