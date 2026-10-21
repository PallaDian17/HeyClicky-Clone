import SwiftUI

/// Renders a ClickyCharacter at any size. Pure vector: body shape, hat,
/// eyes (with a blink), optional blush and a small mouth that follows the mood.
struct ClickyCharacterView: View {
    var character: ClickyCharacter
    var mood: ClickyCharacter.Mood = .awake
    var size: CGFloat = 96
    var animated = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 3.1)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.1)
            let blink = animated && t < 0.11
            canvas(blink: blink)
        }
        .frame(width: size, height: size)
    }

    private func canvas(blink: Bool) -> some View {
        ZStack {
            hat
            bodyShape
                .fill(LinearGradient(colors: [character.color.opacity(0.95), character.color.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                .overlay(bodyShape.stroke(character.accent.opacity(0.25), lineWidth: size * 0.02))
                .frame(width: size * 0.82, height: size * 0.72)
                .offset(y: size * 0.08)
            face(blink: blink)
                .offset(y: size * 0.06)
        }
    }

    private var bodyShape: AnyShape {
        switch character.body {
        case .blob: return AnyShape(BlobShape())
        case .cloud: return AnyShape(CloudShape())
        case .bean: return AnyShape(BeanShape())
        case .square: return AnyShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        }
    }

    @ViewBuilder private var hat: some View {
        let w = size * 0.82
        switch character.hat {
        case .none: EmptyView()
        case .tuft:
            Path { p in
                p.move(to: CGPoint(x: w * 0.5, y: 0))
                p.addQuadCurve(to: CGPoint(x: w * 0.62, y: -size * 0.16), control: CGPoint(x: w * 0.48, y: -size * 0.12))
                p.addQuadCurve(to: CGPoint(x: w * 0.56, y: 0), control: CGPoint(x: w * 0.7, y: -size * 0.04))
            }
            .fill(character.accent)
            .frame(width: w, height: size * 0.2)
            .offset(y: -size * 0.32)
        case .antenna:
            VStack(spacing: 0) {
                Circle().fill(character.accent).frame(width: size * 0.11, height: size * 0.11)
                Rectangle().fill(character.accent).frame(width: size * 0.03, height: size * 0.14)
            }
            .offset(y: -size * 0.4)
        case .beanie:
            VStack(spacing: -size * 0.02) {
                Circle().fill(Color.white.opacity(0.9)).frame(width: size * 0.1, height: size * 0.1)
                UnevenRoundedRectangle(topLeadingRadius: size * 0.3, bottomLeadingRadius: size * 0.04, bottomTrailingRadius: size * 0.04, topTrailingRadius: size * 0.3)
                    .fill(character.accent)
                    .frame(width: size * 0.7, height: size * 0.26)
            }
            .offset(y: -size * 0.33)
        case .halo:
            Ellipse().stroke(Color.yellow.opacity(0.9), lineWidth: size * 0.035)
                .frame(width: size * 0.5, height: size * 0.14)
                .offset(y: -size * 0.38)
        }
    }

    private func face(blink: Bool) -> some View {
        VStack(spacing: size * 0.05) {
            HStack(spacing: size * 0.14) {
                eye(blink: blink)
                eye(blink: blink)
            }
            mouth
        }
        .overlay(alignment: .center) {
            if character.blush {
                HStack(spacing: size * 0.36) {
                    Circle().fill(Color.pink.opacity(0.35)).frame(width: size * 0.1, height: size * 0.07)
                    Circle().fill(Color.pink.opacity(0.35)).frame(width: size * 0.1, height: size * 0.07)
                }
                .offset(y: size * 0.04)
            }
        }
    }

    private func eye(blink: Bool) -> some View {
        let open: CGFloat
        switch character.eyes {
        case .round: open = size * 0.14
        case .tall: open = size * 0.2
        case .sleepy: open = size * 0.08
        case .sparkle: open = size * 0.15
        }
        let height = blink ? size * 0.02 : (mood == .happy ? open * 0.55 : open)
        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                .fill(Color.white)
                .frame(width: size * 0.13, height: height)
            if character.eyes == .sparkle, !blink {
                Circle().fill(Color.white).frame(width: size * 0.04, height: size * 0.04)
                    .offset(x: size * 0.045, y: -height * 0.3)
                    .blendMode(.plusLighter)
            }
            if !blink {
                Circle().fill(character.accent.opacity(0.9))
                    .frame(width: size * 0.06, height: size * 0.06)
                    .offset(x: mood == .thinking ? size * 0.025 : 0, y: mood == .thinking ? -height * 0.2 : height * 0.12)
            }
        }
        .offset(y: mood == .thinking ? -size * 0.02 : 0)
    }

    @ViewBuilder private var mouth: some View {
        switch mood {
        case .happy:
            Path { p in
                p.move(to: .zero)
                p.addQuadCurve(to: CGPoint(x: size * 0.18, y: 0), control: CGPoint(x: size * 0.09, y: size * 0.1))
            }
            .stroke(character.accent, style: StrokeStyle(lineWidth: size * 0.025, lineCap: .round))
            .frame(width: size * 0.18, height: size * 0.08)
        case .listening:
            Circle().fill(character.accent.opacity(0.9)).frame(width: size * 0.06, height: size * 0.07)
        case .thinking:
            Capsule().fill(character.accent.opacity(0.9)).frame(width: size * 0.08, height: size * 0.025).offset(x: size * 0.03)
        case .awake:
            Capsule().fill(character.accent.opacity(0.9)).frame(width: size * 0.12, height: size * 0.025)
        }
    }
}

// MARK: - Body shapes

struct BlobShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.midY), control1: CGPoint(x: r.maxX * 0.85, y: r.minY), control2: CGPoint(x: r.maxX, y: r.midY * 0.6))
        p.addCurve(to: CGPoint(x: r.midX, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.maxY * 0.95), control2: CGPoint(x: r.midX * 1.4, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.minX, y: r.midY), control1: CGPoint(x: r.midX * 0.5, y: r.maxY), control2: CGPoint(x: r.minX, y: r.maxY * 0.9))
        p.addCurve(to: CGPoint(x: r.midX, y: r.minY), control1: CGPoint(x: r.minX, y: r.midY * 0.5), control2: CGPoint(x: r.midX * 0.4, y: r.minY))
        return p
    }
}

struct CloudShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let base = CGRect(x: r.minX, y: r.midY * 0.9, width: r.width, height: r.height * 0.55)
        p.addRoundedRect(in: base, cornerSize: CGSize(width: base.height / 2, height: base.height / 2))
        p.addEllipse(in: CGRect(x: r.minX + r.width * 0.12, y: r.minY + r.height * 0.18, width: r.width * 0.42, height: r.height * 0.5))
        p.addEllipse(in: CGRect(x: r.minX + r.width * 0.42, y: r.minY, width: r.width * 0.48, height: r.height * 0.6))
        return p
    }
}

struct BeanShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.3, y: r.minY))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.midY), control1: CGPoint(x: r.maxX * 0.7, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + r.height * 0.1))
        p.addCurve(to: CGPoint(x: r.midX, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.maxY), control2: CGPoint(x: r.midX * 1.3, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.minX, y: r.midY * 1.2), control1: CGPoint(x: r.minX + r.width * 0.1, y: r.maxY), control2: CGPoint(x: r.minX, y: r.maxY * 0.8))
        p.addCurve(to: CGPoint(x: r.minX + r.width * 0.3, y: r.minY), control1: CGPoint(x: r.minX, y: r.midY * 0.5), control2: CGPoint(x: r.minX, y: r.minY))
        return p
    }
}

// MARK: - Editor

struct CharacterEditorView: View {
    @Binding var character: ClickyCharacter
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(spacing: 10) {
                ClickyCharacterView(character: character, mood: .happy, size: compact ? 110 : 150)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.25)))
                Button("Surprise me") { character = .random() }.controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 10) {
                picker("Body", selection: $character.body, all: ClickyCharacter.Body.allCases) { $0.label }
                picker("Eyes", selection: $character.eyes, all: ClickyCharacter.Eyes.allCases) { $0.label }
                picker("On top", selection: $character.hat, all: ClickyCharacter.Hat.allCases) { $0.label }
                HStack(spacing: 8) {
                    Text("Colour").font(.caption).frame(width: 52, alignment: .leading)
                    ForEach(ClickyCharacter.colorways) { cw in
                        Circle().fill(cw.color).frame(width: 20, height: 20)
                            .overlay(Circle().stroke(Color.white, lineWidth: character.colorway == cw.name ? 2 : 0))
                            .onTapGesture { character.colorway = cw.name }
                            .help(cw.name)
                    }
                }
                Toggle("Blush", isOn: $character.blush).font(.caption)
            }
        }
    }

    private func picker<T: Hashable & Identifiable>(_ title: String, selection: Binding<T>, all: [T], label: @escaping (T) -> String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).frame(width: 52, alignment: .leading)
            Picker("", selection: selection) {
                ForEach(all) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}
