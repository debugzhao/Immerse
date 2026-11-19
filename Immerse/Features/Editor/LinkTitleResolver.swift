import Foundation

/// Turns a pasted URL into a readable page mention: an instant title guessed from the URL,
/// then the page's real title fetched in the background.
enum LinkTitleResolver {
    /// The pasted text as a web URL, or nil if it is anything else (a sentence, a path, several lines…)
    static func webURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Markdown for a page mention: `[@Title](url)`
    static func mention(title: String, url: String) -> String {
        "[@\(sanitized(title))](\(url))"
    }

    /// Link text can't contain brackets or newlines
    static func sanitized(_ title: String) -> String {
        title
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// A title guessed from the URL alone, shown until (or instead of) the fetched one
    static func provisionalTitle(for url: URL) -> String {
        let host = (url.host ?? "").lowercased()
        if isNotion(host) {
            // Notion slugs look like `Page-Title-<32 hex id>`
            let slug = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            let title = slug
                .replacingOccurrences(of: #"-?[0-9a-fA-F]{32}$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "-", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? "Notion 页面" : title
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Pulls the page title out of HTML: og:title, then twitter:title, then <title>
    static func title(fromHTML html: String) -> String? {
        for property in ["og:title", "twitter:title"] {
            let tag = #"<meta[^>]+(?:property|name)\s*=\s*["']"# + NSRegularExpression.escapedPattern(for: property) + #"["'][^>]*>"#
            if let meta = firstMatch(tag, in: html, group: 0),
               let content = firstMatch(#"content\s*=\s*(?:"([^"]*)"|'([^']*)')"#, in: meta, group: 1),
               let title = cleaned(content) {
                return title
            }
        }
        return firstMatch(#"<title[^>]*>([\s\S]*?)</title>"#, in: html, group: 1).flatMap(cleaned)
    }

    /// Titles a site serves when it can't show the page (login walls), which would be worse than the guess
    static func isGeneric(_ title: String, for url: URL) -> Bool {
        let lowered = title.lowercased()
        if isNotion((url.host ?? "").lowercased()) {
            return lowered == "notion" || lowered.hasPrefix("notion |") || lowered.hasPrefix("notion –") || lowered.hasPrefix("notion -")
        }
        return ["login", "log in", "sign in", "登录", "just a moment..."].contains(lowered)
    }

    /// Fetches the page title; nil when offline, not HTML, or only a generic title is available
    static func fetchTitle(for url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.mimeType?.contains("html") ?? true else { return nil }
        let head = data.prefix(512 * 1024)
        guard let html = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1),
              let title = title(fromHTML: html), !isGeneric(title, for: url) else { return nil }
        return title
    }

    // MARK: - Helpers

    private static func isNotion(_ host: String) -> Bool {
        host == "notion.so" || host.hasSuffix(".notion.so") || host.hasSuffix(".notion.site")
            || host == "notion.com" || host.hasSuffix(".notion.com")
    }

    private static func firstMatch(_ pattern: String, in text: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        // Alternation: take the first group that participated
        for index in group..<max(match.numberOfRanges, group + 1) {
            let range = match.range(at: index)
            if range.location != NSNotFound { return (text as NSString).substring(with: range) }
        }
        return nil
    }

    private static func cleaned(_ raw: String) -> String? {
        let collapsed = decodeEntities(raw)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        let regex = try! NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);"#)
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let entity = ns.substring(with: match.range(at: 1))
            var replacement: String?
            if entity.hasPrefix("#x"), let code = UInt32(entity.dropFirst(2), radix: 16) {
                replacement = Unicode.Scalar(code).map { String(Character($0)) }
            } else if entity.hasPrefix("#"), let code = UInt32(entity.dropFirst()) {
                replacement = Unicode.Scalar(code).map { String(Character($0)) }
            } else {
                replacement = named[entity.lowercased()]
            }
            result += replacement ?? ns.substring(with: match.range)
            cursor = match.range.upperBound
        }
        return result + ns.substring(from: cursor)
    }
}
