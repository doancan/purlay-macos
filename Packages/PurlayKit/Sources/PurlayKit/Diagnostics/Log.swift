import OSLog

/// The app's log, by area, in the unified log (`log show --predicate 'subsystem == "dev.purlay.mac"'`). What goes here is what
/// happened and its code, never what a person wrote, who they are, or an address: those are `.private` when they must appear.
public enum Log {
    public static let subsystem = "dev.purlay.mac"

    /// Notices the system was asked to show, and what it refused.
    public static let attention = Logger(subsystem: subsystem, category: "attention")
    /// The session: sign-in, restore, sign-out, the keychain.
    public static let session = Logger(subsystem: subsystem, category: "session")
    /// Files on disk: the outbox, drafts, attachments saved and read.
    public static let storage = Logger(subsystem: subsystem, category: "storage")
}
