import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Where dictation is going: the focused text element of the frontmost app.
struct FocusedField {
    var appName: String?
    var bundleID: String?
    var role: String?
    var title: String?
    var valueBefore: String?
    var element: AXUIElement?
    var isSecure: Bool { role == "AXSecureTextField" }

    static func current() -> FocusedField {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return FocusedField() }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return FocusedField(appName: app.localizedName, bundleID: app.bundleIdentifier)
        }
        let element = focused as! AXUIElement
        func str(_ attr: String) -> String? {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attr as CFString, &v) == .success else { return nil }
            return v as? String
        }
        return FocusedField(appName: app.localizedName, bundleID: app.bundleIdentifier,
                            role: str(kAXRoleAttribute), title: str(kAXTitleAttribute) ?? str(kAXPlaceholderValueAttribute),
                            valueBefore: str(kAXValueAttribute), element: element)
    }

    /// Re-reads the field's value (nil when the element is gone or unreadable).
    func currentValue() -> String? {
        guard let element else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }
}

/// Puts text into the focused field: pasteboard + ⌘V, verified by re-reading
/// the field; falls back to setting the accessibility value directly.
enum TextInsertion {
    enum Outcome { case pasted, setDirectly, unverified, failed(String) }

    @MainActor
    static func insert(_ text: String, into field: FocusedField) async -> Outcome {
        guard !text.isEmpty else { return .failed("nothing to insert") }
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.compactMap { item -> (NSPasteboard.PasteboardType, Data)? in
            guard let type = item.types.first, let data = item.data(forType: type) else { return nil }
            return (type, data)
        } ?? []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pressCommandV()

        // Give the app time to handle the key and read the pasteboard; poll the field meanwhile.
        var after: String?
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(100))
            after = field.currentValue()
            if after?.contains(text) == true { break }
        }

        // Restore what the user had on the clipboard, only once the paste has been consumed.
        if !saved.isEmpty {
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            for (type, data) in saved { item.setData(data, forType: type) }
            pasteboard.writeObjects([item])
        }

        if let after {
            if after.contains(text) { return .pasted }
            // Paste did not land: write the value through accessibility.
            if let element = field.element {
                let merged = (field.valueBefore ?? "") + text
                if AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, merged as CFTypeRef) == .success,
                   field.currentValue()?.contains(text) == true {
                    return .setDirectly
                }
            }
            return .failed("the field did not accept the text")
        }
        return .unverified   // no readable value (web views, terminals); assume the paste went through
    }

    private static func pressCommandV() {
        let src = CGEventSource(stateID: .hidSystemState)
        let v: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

/// Words the user keeps using that speech-to-text gets wrong: fed to cleanup,
/// and learned from the edits they make right after an insertion.
@MainActor
final class DictationDictionary: ObservableObject {
    static let key = "ClickyDictationDictionary"
    @Published var words: [String] {
        didSet { UserDefaults.standard.set(words, forKey: Self.key) }
    }

    init() { words = UserDefaults.standard.stringArray(forKey: Self.key) ?? [] }

    func add(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard w.count >= 2, !words.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) else { return }
        words.append(w)
    }

    /// Compares what was inserted with what the field holds a few seconds later
    /// and returns words the user changed to (capitalised or unknown tokens).
    static func learnedWords(inserted: String, edited: String) -> [String] {
        let before = Set(tokens(inserted).map { $0.lowercased() })
        var learned: [String] = []
        for token in tokens(edited) where !before.contains(token.lowercased()) {
            let isName = token.first?.isUppercase == true
            let isTerm = token.count >= 4 && token.contains(where: { $0.isLetter })
            if (isName || isTerm) && !learned.contains(token) { learned.append(token) }
        }
        return Array(learned.prefix(5))
    }

    private static func tokens(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-")).inverted).filter { !$0.isEmpty }
    }
}
