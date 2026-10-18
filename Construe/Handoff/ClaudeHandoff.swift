import Foundation

/// Builds the claude.ai link that opens a new chat prefilled with the exchange.
///
/// The `project` parameter is undocumented and may stop working; without a project ID the link falls
/// back to the documented `claude.ai/new?q=`. Keep all claude.ai URL building in this file.
enum ClaudeHandoff {
    /// claude.ai truncates longer prefills (around 14k characters), so stay safely below.
    static let maxTextLength = 12_000

    static let phrasePlaceholder = "{{phrase}}"
    static let replyPlaceholder = "{{reply}}"

    /// Fills the template's `{{phrase}}` and `{{reply}}`. The template's own text, including any
    /// trailing blank lines, is kept as is; to fit the length limit the reply is trimmed from its end.
    static func text(template: String, phrase: String, reply: String) -> String {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        func render(_ reply: String) -> String {
            template
                .replacingOccurrences(of: phrasePlaceholder, with: phrase)
                .replacingOccurrences(of: replyPlaceholder, with: reply)
        }

        let full = render(reply)
        guard full.count > maxTextLength else { return full }

        let ellipsis = "…"
        let placeholderCount = max(1, template.components(separatedBy: replyPlaceholder).count - 1)
        let room = (maxTextLength - render("").count) / placeholderCount - ellipsis.count
        guard room > 0, template.contains(replyPlaceholder) else {
            // Nothing left to trim in the reply (e.g. a very long pasted phrase): trim the whole text.
            return String(full.prefix(maxTextLength - ellipsis.count)) + ellipsis
        }
        return render(String(reply.prefix(room)) + ellipsis)
    }

    /// `https://claude.ai/new?project=<id>&q=<text>`, or without `project` when the ID is empty.
    static func url(projectID: String, text: String) -> URL? {
        var query: [String] = []
        let projectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !projectID.isEmpty {
            query.append("project=" + percentEncoded(projectID))
        }
        query.append("q=" + percentEncoded(text))
        return URL(string: "https://claude.ai/new?" + query.joined(separator: "&"))
    }

    /// Encodes everything except RFC 3986 unreserved characters. `URLQueryItem` would leave `+`, `&`
    /// and others as they are, which claude.ai would read as spaces or parameter separators.
    private static func percentEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        // `alphanumerics` includes non-ASCII letters; restrict to ASCII so accents get encoded too.
        allowed = allowed.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
