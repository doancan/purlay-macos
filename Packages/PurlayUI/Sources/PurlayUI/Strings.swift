import Foundation
import PurlayContract
import PurlayKit

/// Every sentence a person reads, in one place, so each is a key a catalogue can translate (§12.11). The model hands over what
/// happened; this says it. The server's own `message` is never shown: it is English, written for a log.
enum Words {
    static func notice(_ kind: Notice.Kind) -> String {
        switch kind {
        case .invalidAddress(let problem):
            switch problem {
            case .empty: return String(localized: "Type the address of your Purlay server.")
            case .unreadable: return String(localized: "That is not an address a browser would open.")
            case .notAWebAddress: return String(localized: "Use a web address, starting with https.")
            case .hasCredentials: return String(localized: "Leave the user name and password out of the address.")
            case .hasMoreThanAHost: return String(localized: "Give only the server's address, without a path.")
            case .insecure: return String(localized: "This server must be reached over https.")
            }
        case .signInFailed(let error): return signIn(error)
        case .sessionExpired: return String(localized: "Your session has expired. Sign in again.")
        case .sessionEndedByServer: return String(localized: "You were signed out by the server. Sign in again.")
        case .signedOutElsewhere: return String(localized: "You were signed out.")
        case .serverNotTold:
            return String(
                localized:
                    "You are signed out here. The server could not be reached, so this session stays valid there until it expires."
            )
        case .signOutEverywhereFailed:
            return String(localized: "Could not sign out everywhere. You are still signed in.")
        case .unsentLost(let count):
            return String(
                localized: "\(count) unsent messages were removed because you no longer have access to their channel.")
        case .unrestorable(let count): return String(localized: "\(count) unsent messages could not be restored.")
        case .outboxCorrupt: return String(localized: "Your unsent messages could not be read and were set aside.")
        case .storageProblem:
            return String(localized: "Unsent messages can't be saved on this Mac right now. Sending still works.")
        case .originMismatch:
            return String(localized: "The server refused this app's connection. Check the server's address.")
        case .sendTooLong: return String(localized: "That message is too long to send.")
        case .threadFailed: return String(localized: "Could not load the thread. Check your connection and try again.")
        case .resolveFailed: return String(localized: "Could not change whether this thread is resolved. Try again.")
        case .followFailed: return String(localized: "Could not change whether you follow this thread. Try again.")
        case .joinFailed: return String(localized: "Could not open that. Check your connection and try again.")
        case .leaveFailed: return String(localized: "Could not leave the channel. Check your connection and try again.")
        case .lastMember:
            return String(localized: "You are the last member of this private channel, so you can't leave it.")
        case .starFailed: return String(localized: "Could not change the star. Try again.")
        case .deepWorkFailed: return String(localized: "Could not change Deep Work. Try again.")
        case .editFailed: return String(localized: "Could not change the message. Check your connection and try again.")
        case .deleteFailed:
            return String(localized: "Could not delete the message. Check your connection and try again.")
        case .reactionFailed:
            return String(localized: "Could not react to the message. Check your connection and try again.")
        case .loadFailed: return String(localized: "Could not load messages. Check your connection.")
        }
    }

    static func signIn(_ error: SignInError) -> String {
        switch error {
        case .cancelled: return ""
        case .browserFailed: return String(localized: "The browser could not be opened.")
        case .callbackRejected: return String(localized: "The sign-in did not come back the way it should. Try again.")
        case .codeRejected: return String(localized: "That sign-in expired or was already used. Try again.")
        case .rateLimited: return String(localized: "Too many attempts. Wait a moment and try again.")
        case .refused: return String(localized: "The server did not accept this sign-in.")
        case .noSessionInAnswer: return String(localized: "The server did not start a session. Try again.")
        case .unreachable: return String(localized: "The server could not be reached.")
        case .storage: return String(localized: "The session could not be saved to your Keychain.")
        }
    }

    static func problem(_ problem: ServerProblem) -> (title: String, detail: String) {
        switch problem {
        case .unreachable:
            return (
                String(localized: "Can't reach the server"), String(localized: "Check the address and your connection.")
            )
        case .notAPurlayServer:
            return (
                String(localized: "That doesn't look like a Purlay server"),
                String(localized: "The address answered, but not as Purlay does.")
            )
        case .rateLimited:
            return (String(localized: "Too many requests"), String(localized: "The server asks you to wait a moment."))
        case .appTooOld(let minimum):
            let needed = minimum.appVersion.map { String(localized: "It needs version \($0) or newer.") } ?? ""
            return (String(localized: "This server needs a newer Purlay"), needed)
        case .serverTooOld:
            return (
                String(localized: "This server is older than this app supports"),
                String(localized: "Ask whoever runs it to update the server.")
            )
        case .unusableOrigin(let text):
            return (String(localized: "The server gave an address this app can't use"), text)
        }
    }

    static func header(_ kind: SidebarSection.Kind) -> String {
        switch kind {
        case .starred: return String(localized: "Starred")
        case .channels: return String(localized: "Channels")
        case .conversations: return String(localized: "Conversations")
        }
    }

    /// A channel is named with a hash; a conversation with people is named by them, with none.
    static func channelLabel(_ channel: Channel) -> String {
        switch channel.type {
        case .directMessage: return channel.title
        case .public, .private, .unknown: return "# \(channel.title)"
        }
    }
}

/// What a system notice says: where and why, never what was said, because a notice is read over a shoulder and stays in the notification
/// centre (D-126 §2).
public enum AttentionWords {
    public static func title(_ notice: AttentionNotice) -> String {
        switch notice.content {
        case .place(_, let label, _): label
        case .several: String(localized: "Purlay")
        }
    }

    public static func body(_ notice: AttentionNotice) -> String {
        switch notice.content {
        case .place(_, _, let reason):
            switch reason {
            case .directMessage: String(localized: "New message")
            case .everyMessage: String(localized: "New message")
            case .mention: String(localized: "Needs you: a mention or a reply")
            }
        case .several(let count): String(localized: "\(count) conversations need you")
        }
    }
}
