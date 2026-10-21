import SwiftUI

/// The mascot: an original soft "blob" creature (a rounded body with two
/// expressive eyes) that the user customises once and that every surface
/// renders with the same rig: the notch, the Home sidebar, onboarding.
struct ClickyCharacter: Codable, Equatable, Hashable {
    enum Body: String, Codable, CaseIterable, Identifiable {
        case blob, cloud, bean, square
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }
    enum Eyes: String, Codable, CaseIterable, Identifiable {
        case round, tall, sleepy, sparkle
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }
    enum Hat: String, Codable, CaseIterable, Identifiable {
        case none, tuft, antenna, beanie, halo
        var id: String { rawValue }
        var label: String { self == .none ? "Nothing" : rawValue.capitalized }
    }
    enum Mood { case awake, thinking, happy, listening }

    struct Colorway: Codable, Equatable, Hashable, Identifiable {
        var name: String
        var hex: String
        var accentHex: String
        var id: String { name }
        var color: Color { Color(hex: hex) }
        var accent: Color { Color(hex: accentHex) }
    }

    static let colorways: [Colorway] = [
        .init(name: "Lilac", hex: "#A78BFA", accentHex: "#6D28D9"),
        .init(name: "Sky", hex: "#60A5FA", accentHex: "#1D4ED8"),
        .init(name: "Mint", hex: "#5EEAD4", accentHex: "#0F766E"),
        .init(name: "Peach", hex: "#FDBA74", accentHex: "#C2410C"),
        .init(name: "Rose", hex: "#F9A8D4", accentHex: "#BE185D"),
        .init(name: "Lemon", hex: "#FDE68A", accentHex: "#A16207"),
        .init(name: "Slate", hex: "#94A3B8", accentHex: "#334155"),
        .init(name: "Ink", hex: "#1F2937", accentHex: "#E5E7EB"),
    ]

    var body: Body = .blob
    var eyes: Eyes = .round
    var hat: Hat = .none
    var colorway: String = "Lilac"
    var blush = true

    var color: Color { (Self.colorways.first { $0.name == colorway } ?? Self.colorways[0]).color }
    var accent: Color { (Self.colorways.first { $0.name == colorway } ?? Self.colorways[0]).accent }

    static let `default` = ClickyCharacter()
    static let storageKey = "ClickyCharacter"

    static func random() -> ClickyCharacter {
        ClickyCharacter(body: Body.allCases.randomElement()!, eyes: Eyes.allCases.randomElement()!,
                        hat: Hat.allCases.randomElement()!, colorway: colorways.randomElement()!.name, blush: Bool.random())
    }

    /// A stable look for a Clicky that has none chosen: derived from its slug.
    static func derived(from seed: String) -> ClickyCharacter {
        var h: UInt64 = 1469598103934665603
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        func pick<T>(_ all: [T], _ shift: UInt64) -> T { all[Int((h >> shift) % UInt64(all.count))] }
        return ClickyCharacter(body: pick(Body.allCases, 3), eyes: pick(Eyes.allCases, 11), hat: pick(Hat.allCases, 19),
                               colorway: pick(colorways, 27).name, blush: (h >> 35) & 1 == 1)
    }

    // MARK: - The user's own character

    static func loadUser() -> ClickyCharacter {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let c = try? JSONDecoder().decode(ClickyCharacter.self, from: data) else { return .default }
        return c
    }

    func saveAsUser() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
        NotificationCenter.default.post(name: .clickyCharacterChanged, object: nil)
    }
}

extension Notification.Name {
    static let clickyCharacterChanged = Notification.Name("ClickyCharacterChanged")
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// Publishes the user's character to SwiftUI views.
@MainActor
final class CharacterStore: ObservableObject {
    @Published var character: ClickyCharacter {
        didSet { if character != oldValue { character.saveAsUser() } }
    }
    init() { character = ClickyCharacter.loadUser() }
}
