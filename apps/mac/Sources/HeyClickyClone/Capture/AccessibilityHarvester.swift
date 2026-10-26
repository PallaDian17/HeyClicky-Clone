import AppKit
import ApplicationServices

/// An interactive element of the frontmost window, as sent to the backend.
/// `frame` is in screen points with a top-left origin (Quartz global coordinates).
struct AXElement: Codable, Equatable {
    struct Frame: Codable, Equatable { var x: Double; var y: Double; var w: Double; var h: Double }
    let id: Int
    let role: String
    let title: String
    let frame: Frame

    var cgRect: CGRect { CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h) }
}

struct AXHarvest {
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    var urls: [String] = []            // page URLs seen in the tree (browsers)
    var hasSecureField = false         // an AXSecureTextField is present
    var elements: [AXElement]
    static let empty = AXHarvest(appName: nil, elements: [])

    /// Same harvest with everything the model should not see removed.
    func withheld() -> AXHarvest {
        AXHarvest(appName: appName, bundleID: bundleID, windowTitle: nil, urls: [], hasSecureField: hasSecureField, elements: [])
    }
}

/// Walks the frontmost app's focused window and lists elements worth pointing at.
/// Needs the Accessibility grant; returns an empty harvest otherwise.
enum AccessibilityHarvester {
    private static let interestingRoles: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXTextField",
        "AXTextArea", "AXSearchField", "AXComboBox", "AXLink", "AXTab", "AXTabGroup", "AXSlider",
        "AXMenuItem", "AXMenuBarItem", "AXRow", "AXCell", "AXImage", "AXStaticText", "AXDisclosureTriangle",
        "AXToolbar", "AXSwitch", "AXIncrementor", "AXColorWell", "AXHeading", "AXOutlineRow",
    ]

    static func harvestFrontmost(limit: Int = 300, maxDepth: Int = 14) -> AXHarvest {
        guard AXIsProcessTrusted() else { return .empty }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return .empty }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = copyElement(appElement, kAXFocusedWindowAttribute as CFString)
                ?? copyElement(appElement, kAXMainWindowAttribute as CFString) else {
            return AXHarvest(appName: app.localizedName, bundleID: app.bundleIdentifier, elements: [])
        }

        var out: [AXElement] = []
        var urls: [String] = []
        var hasSecureField = false
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, out.count < limit, visited < 4000 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role = stringAttribute(element, kAXRoleAttribute) ?? ""
            if role == "AXSecureTextField" { hasSecureField = true; continue }
            if role == "AXWebArea", let url = stringAttribute(element, "AXURL") { urls.append(url) }
            if role == "AXTextField" || role == "AXComboBox", let value = stringAttribute(element, kAXValueAttribute),
               value.hasPrefix("http://") || value.hasPrefix("https://") { urls.append(value) }
            if let frame = frame(of: element), frame.width >= 4, frame.height >= 4 {
                let title = bestTitle(element)
                if interestingRoles.contains(role), !(role == "AXStaticText" && title.isEmpty) {
                    out.append(AXElement(id: out.count + 1, role: role, title: String(title.prefix(80)),
                                         frame: .init(x: frame.minX, y: frame.minY, w: frame.width, h: frame.height)))
                }
            }
            if depth < maxDepth, let children = children(of: element) {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        Log.app.info("ax harvest app=\(app.localizedName ?? "?", privacy: .public) elements=\(out.count) visited=\(visited) secure=\(hasSecureField)")
        return AXHarvest(appName: app.localizedName, bundleID: app.bundleIdentifier,
                         windowTitle: stringAttribute(window, kAXTitleAttribute), urls: urls,
                         hasSecureField: hasSecureField, elements: out)
    }

    // MARK: - AX helpers

    static func copyElement(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func children(of element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let u = value as? URL { return u.absoluteString }
        return nil
    }

    private static func bestTitle(_ element: AXUIElement) -> String {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute] {
            if let s = stringAttribute(element, attr)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                return s.replacingOccurrences(of: "\n", with: " ")
            }
        }
        return ""
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
