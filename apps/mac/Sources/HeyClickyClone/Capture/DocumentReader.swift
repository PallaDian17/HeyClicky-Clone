import AppKit
import ApplicationServices
import PDFKit

/// Whole-document understanding: the full text of what is in the frontmost
/// window, beyond the part the screenshot shows. A document-based app tells us
/// its file (AXDocument) and we read it — PDFs page by page, text, Markdown,
/// RTF and Word through the system readers. Otherwise we walk the window's
/// accessibility tree and collect every piece of text it exposes, which for a
/// browser or an editor is the whole page or buffer, not just the viewport.
/// Nothing leaves the Mac from here; the talk pipeline redacts and the
/// privacy guard withholds as usual.
enum DocumentReader {
    struct DocumentText: Equatable {
        var title: String?
        var kind: String          // pdf · file · web · text
        var text: String
        var truncated: Bool
        var words: Int { text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }
    }

    static let enabledKey = "ClickyReadWholeDocument"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static let maxChars = 40_000
    static let minChars = 300
    static let timeBudget: TimeInterval = 2.0

    /// Call off the main thread. `pageURL` is the browser's current page when one is frontmost.
    static func readFrontmost(pageURL: String? = nil) -> DocumentText? {
        guard isEnabled, AXIsProcessTrusted() else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = AccessibilityHarvester.copyElement(appElement, kAXFocusedWindowAttribute as CFString)
                ?? AccessibilityHarvester.copyElement(appElement, kAXMainWindowAttribute as CFString) else { return nil }
        let title = AccessibilityHarvester.stringAttribute(window, kAXTitleAttribute)

        // 1. A document the app can name: read the file itself.
        if let doc = AccessibilityHarvester.stringAttribute(window, kAXDocumentAttribute),
           let url = URL(string: doc), url.isFileURL, let text = readFile(url) {
            return finish(title: title ?? url.lastPathComponent, kind: url.pathExtension.lowercased() == "pdf" ? "pdf" : "file", text: text)
        }
        // 2. Otherwise everything the window's accessibility tree says. Safari and
        //    most apps expose their whole text; Chromium browsers expose only their
        //    own chrome (no AXWebArea at all without an assistive client).
        let isBrowser = BrowserURLProbe.isBrowser(app)
        if let text = walkText(from: window), text.count >= minChars {
            return finish(title: title, kind: isBrowser ? "web" : "text", text: text)
        }
        // 3. A browser page the tree does not expose: fetch the page itself when it is
        //    public. No cookies go with the request, so a signed-in page comes back as
        //    its public face or not at all.
        if isBrowser, let pageURL, let text = fetchPublicPage(pageURL) {
            return finish(title: title, kind: "web", text: text)
        }
        return nil
    }

    // MARK: - Public web pages

    private static func fetchPublicPage(_ urlString: String) -> String? {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh) HiDicky/1.0", "Accept": "text/html,text/plain;q=0.9,*/*;q=0.5"]
        let session = URLSession(configuration: config)
        var result: (Data, URLResponse)?
        let done = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: url) { data, response, _ in
            if let data, let response { result = (data, response) }
            done.signal()
        }
        task.resume()
        _ = done.wait(timeout: .now() + 4.5)
        task.cancel()
        guard let (data, response) = result, data.count < 3_000_000 else { return nil }
        let mime = (response as? HTTPURLResponse)?.mimeType ?? response.mimeType ?? ""
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        if mime.contains("text/plain") { return raw }
        guard mime.contains("html") || raw.lowercased().contains("<html") else { return nil }
        Log.app.info("document fetch: \(url.host ?? "?", privacy: .public) \(data.count) bytes")
        return htmlToText(raw)
    }

    /// A small, dependency-free HTML → text: drop script/style/nav/footer, turn block
    /// tags into line breaks, strip the rest, decode the common entities.
    static func htmlToText(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "noscript", "svg", "template", "nav", "footer", "header"] {
            s = s.replacingOccurrences(of: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)>", with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: "(?is)<!--.*?-->", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)<(br|/p|/div|/li|/tr|/h[1-6]|/section|/article|/blockquote|/pre)\\b[^>]*>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)<h([1-6])\\b[^>]*>", with: "\n# ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
        let entities: [(String, String)] = [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&#x27;", "'"), ("&hellip;", "…"), ("&mdash;", "—"), ("&ndash;", "–"), ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&rdquo;", "”"), ("&ldquo;", "“")]
        for (e, c) in entities { s = s.replacingOccurrences(of: e, with: c) }
        s = s.replacingOccurrences(of: "&#(\\d+);", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "[ \\t\\u00a0]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        return s
    }

    private static func finish(title: String?, kind: String, text: String) -> DocumentText? {
        let cleaned = text.replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= minChars else { return nil }
        if cleaned.count <= maxChars { return DocumentText(title: title, kind: kind, text: cleaned, truncated: false) }
        // Keep the head and the tail; the middle is what the screenshot least needs.
        let head = cleaned.prefix(maxChars * 3 / 4)
        let tail = cleaned.suffix(maxChars / 4)
        return DocumentText(title: title, kind: kind, text: head + "\n\n[… middle of the document left out …]\n\n" + tail, truncated: true)
    }

    // MARK: - Files

    private static func readFile(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 40_000_000 else { return nil }
        switch ext {
        case "pdf":
            guard let pdf = PDFDocument(url: url) else { return nil }
            var out = ""
            for i in 0..<pdf.pageCount {
                guard let page = pdf.page(at: i), let s = page.string, !s.isEmpty else { continue }
                out += "\n\n--- page \(i + 1) of \(pdf.pageCount) ---\n" + s
                if out.count > maxChars * 2 { break }
            }
            return out
        case "txt", "md", "markdown", "csv", "json", "yaml", "yml", "log", "swift", "ts", "js", "py", "rb", "go", "rs", "java", "kt", "c", "h", "m", "cpp", "sh", "toml", "ini", "cfg", "tex", "xml", "sql":
            return try? String(contentsOf: url, encoding: .utf8)
        case "rtf", "rtfd", "docx", "doc", "html", "htm", "webarchive", "odt":
            let types: [NSAttributedString.DocumentType] = ext == "html" || ext == "htm" ? [.html] : ext == "docx" ? [.officeOpenXML] : ext == "doc" ? [.docFormat] : ext == "webarchive" ? [.webArchive] : [.rtf, .rtfd]
            for t in types {
                if let s = try? NSAttributedString(url: url, options: [.documentType: t], documentAttributes: nil).string { return s }
            }
            return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        default:
            return nil
        }
    }

    // MARK: - Accessibility walk

    private static let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink", "AXCell", "AXMenuItem"]
    private static let skipRoles: Set<String> = ["AXSecureTextField", "AXMenuBar", "AXToolbar", "AXScrollBar", "AXTabGroup"]

    private static func walkText(from window: AXUIElement) -> String? {
        let deadline = Date().addingTimeInterval(timeBudget)
        var out: [String] = []
        var chars = 0
        var seen = Set<String>()
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 12_000, chars < maxChars * 2, Date() < deadline {
            let (el, depth) = queue.removeFirst()
            visited += 1
            let role = AccessibilityHarvester.stringAttribute(el, kAXRoleAttribute) ?? ""
            if skipRoles.contains(role) { continue }
            if textRoles.contains(role) {
                var piece = AccessibilityHarvester.stringAttribute(el, kAXValueAttribute) ?? ""
                if piece.isEmpty { piece = AccessibilityHarvester.stringAttribute(el, kAXTitleAttribute) ?? "" }
                if piece.isEmpty, role == "AXLink" || role == "AXHeading" { piece = AccessibilityHarvester.stringAttribute(el, kAXDescriptionAttribute) ?? "" }
                let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, seen.insert(trimmed).inserted {
                    out.append(role == "AXHeading" ? "\n# " + trimmed : trimmed)
                    chars += trimmed.count
                }
                // A text area's value is the whole buffer; its children would repeat it.
                if role == "AXTextArea" || role == "AXTextField" { continue }
            }
            if depth < 40, let kids = AccessibilityHarvester.children(of: el) { queue.append(contentsOf: kids.map { ($0, depth + 1) }) }
        }
        Log.app.info("document walk: visited=\(visited) pieces=\(out.count) chars=\(chars) timedOut=\(Date() >= deadline)")
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }
}
