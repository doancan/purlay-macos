import PurlayContract

/// What a slash command came to: words to send in its place, something done, or why it was not.
public enum SlashResult: Equatable, Sendable {
    case send(String)
    case done(Done)
    case refused(Refusal)

    public enum Done: Equatable, Sendable {
        case muted, unmuted, starred, unstarred, left, deepWorkStarted, deepWorkEnded, searched
        case invited(String)
    }

    public enum Refusal: Equatable, Sendable {
        case usage(SlashCommand)
        case unknown(String)
        case notMember
        case nobody(String)
        case failed
    }
}

extension AppModel {
    /// Runs a command through what the app already does for it, as the button for it would: a mute is the channel's level, a star the
    /// sidebar's, Deep Work its controls, a search its screen. Nothing is sent unless the command is `/me` or `/shrug`.
    public func runSlash(_ line: SlashCommand.Line) async -> SlashResult {
        switch line {
        case .escaped(let text): return .send(text)
        case .unknown(let name): return .refused(.unknown(name))
        case .command(let command, let words): return await run(command, words)
        }
    }

    private func run(_ command: SlashCommand, _ words: String) async -> SlashResult {
        let channel = selectedChannel.flatMap { chat.channels[$0] }
        let member = channel.flatMap { $0.state != nil ? $0 : nil }
        switch command {
        case .me:
            return SlashCommand.meMessage(words).map(SlashResult.send) ?? .refused(.usage(.me))
        case .shrug:
            return .send(SlashCommand.shrugMessage(words))
        case .mute, .unmute:
            guard let member else { return .refused(.notMember) }
            let muting = command == .mute
            guard await setNotifications(muting ? .none : .mentions, in: member.id) else { return .refused(.failed) }
            return .done(muting ? .muted : .unmuted)
        case .star, .unstar:
            guard let member else { return .refused(.notMember) }
            await setStarred(command == .star, member)
            return .done(command == .star ? .starred : .unstarred)
        case .invite:
            guard let handle = SlashCommand.invitee(words) else { return .refused(.usage(.invite)) }
            guard let member else { return .refused(.notMember) }
            guard let person = workspacePeople.first(where: { $0.username.lowercased() == handle }) else {
                return .refused(.nobody(handle))
            }
            guard let api else { return .refused(.failed) }
            do {
                try await api.addChannelMember(
                    channelId: member.id.value, body: AddChannelMemberRequest(userId: person.id))
                return .done(.invited(person.displayName))
            } catch {
                return .refused(.failed)
            }
        case .leave:
            guard let member else { return .refused(.notMember) }
            return await leave(member) ? .done(.left) : .refused(.failed)
        case .deepwork:
            switch SlashCommand.deepWork(words) {
            case .start(let length)?:
                await startDeepWork(length)
                return .done(.deepWorkStarted)
            case .end?:
                await endDeepWork()
                return .done(.deepWorkEnded)
            case nil:
                return .refused(.usage(.deepwork))
            }
        case .search:
            guard !words.isEmpty else { return .refused(.usage(.search)) }
            openSearch(words)
            return .done(.searched)
        }
    }
}
