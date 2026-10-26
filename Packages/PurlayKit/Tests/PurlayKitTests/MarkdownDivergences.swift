/// Corpus cases the reader is known to read differently from the server, each with why. Empty is the aim.
enum MarkdownDivergences {
    /// Foundation's inline reader is the engine, and it drops what it does not model:
    /// - `link/label-emphasis`: emphasis inside a link's label is lost (the label reads as plain text);
    /// - `link/empty-label`: a link with no label produces no run at all, so it does not appear.
    static let names: Set<String> = ["link/label-emphasis", "link/empty-label"]
}
