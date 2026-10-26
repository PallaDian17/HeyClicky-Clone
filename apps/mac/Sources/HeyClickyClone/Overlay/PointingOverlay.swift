import AppKit
import SwiftUI

/// What the model wants drawn on screen while it speaks.
struct AnnotationTarget: Identifiable, Equatable {
    enum Kind: String { case marker, underline, box }
    let id: Int                 // 1-based number shown in the badge
    var rect: CGRect            // window-local, top-left origin
    var kind: Kind
    var label: String?
}

/// A click-through window over one screen that annotates what Clicky is
/// talking about: one pointed-at box (the single-pointer reply), or a numbered
/// set of markers and underlines revealed one by one as the explanation goes.
@MainActor
final class PointingOverlayManager {
    private var window: NSWindow?
    private let model = PointingOverlayModel()
    private var hideTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?

    func show(quartzRect rect: CGRect, label: String?, autoHideAfter seconds: TimeInterval = 8) {
        guard let (screen, local) = place(quartzRect: rect) else { return }
        let window = ensureWindow(on: screen)
        model.targets = [AnnotationTarget(id: 1, rect: local, kind: .box, label: label)]
        model.revealed = 1
        model.visible = true
        window.orderFrontRegardless()
        Log.hud.info("pointer at \(NSStringFromRect(local), privacy: .public) on screen \(screen.localizedName, privacy: .public)")
        scheduleHide(after: seconds)
    }

    func show(normalizedBox box: CGRect, on screen: NSScreen, label: String?, autoHideAfter seconds: TimeInterval = 8) {
        show(quartzRect: Self.quartz(normalized: box, on: screen), label: label, autoHideAfter: seconds)
    }

    /// Several targets, revealed progressively over `duration` seconds (about
    /// how long the explanation takes to say). They stay until `clear()`.
    func showTargets(_ targets: [(rect: CGRect, kind: AnnotationTarget.Kind, label: String?)], over duration: TimeInterval) {
        hideTask?.cancel()
        revealTask?.cancel()
        guard let first = targets.first, let (screen, _) = place(quartzRect: first.rect) else { return }
        let window = ensureWindow(on: screen)
        model.targets = targets.enumerated().compactMap { i, t in
            guard let (_, local) = place(quartzRect: t.rect, on: screen) else { return nil }
            return AnnotationTarget(id: i + 1, rect: local, kind: t.kind, label: t.label)
        }
        model.revealed = 0
        model.visible = true
        window.orderFrontRegardless()
        let n = model.targets.count
        Log.hud.info("annotations: \(n) target(s) over \(duration, format: .fixed(precision: 1))s")
        revealTask = Task { [weak self] in
            for i in 1...max(1, n) {
                guard let self, !Task.isCancelled else { return }
                self.model.revealed = i
                try? await Task.sleep(for: .seconds(max(0.4, duration / Double(max(1, n)))))
            }
        }
    }

    var hasAnnotations: Bool { model.visible && !model.targets.isEmpty }
    var targetCount: Int { model.targets.count }

    /// The "✕ Clear" chip and Esc.
    func clear() { hide() }

    func hide() {
        hideTask?.cancel()
        revealTask?.cancel()
        model.visible = false
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.3))
            guard let self, !self.model.visible else { return }
            self.window?.orderOut(nil)
        }
    }

    func snapshot(to url: URL) {
        guard let view = window?.contentView else { return }
        let ok = DebugSnapshot.write(view: view, background: .clear, appearance: NSAppearance(named: .darkAqua), to: url)
        Log.hud.info("annotation snapshot -> \(url.path, privacy: .public) ok=\(ok) targets=\(self.model.targets.count) revealed=\(self.model.revealed)")
    }

    // MARK: - Geometry

    private func place(quartzRect rect: CGRect, on forced: NSScreen? = nil) -> (NSScreen, CGRect)? {
        guard let primary = NSScreen.screens.first else { return nil }
        let primaryHeight = primary.frame.height
        let nsPoint = CGPoint(x: rect.midX, y: primaryHeight - rect.midY)
        let screen = forced ?? NSScreen.screens.first(where: { $0.frame.contains(nsPoint) }) ?? primary
        let local = CGRect(x: rect.minX - screen.frame.minX,
                           y: rect.minY - (primaryHeight - screen.frame.maxY),
                           width: rect.width, height: rect.height)
        return (screen, local)
    }

    static func quartz(normalized box: CGRect, on screen: NSScreen) -> CGRect {
        guard let primary = NSScreen.screens.first else { return .zero }
        let primaryHeight = primary.frame.height
        return CGRect(x: screen.frame.minX + box.minX * screen.frame.width,
                      y: (primaryHeight - screen.frame.maxY) + box.minY * screen.frame.height,
                      width: box.width * screen.frame.width,
                      height: box.height * screen.frame.height)
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func ensureWindow(on screen: NSScreen) -> NSWindow {
        if let window, window.frame == screen.frame { return window }
        window?.orderOut(nil)
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.title = "Annotations"
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: PointingOverlayView(model: model))
        window = w
        return w
    }
}

@MainActor
final class PointingOverlayModel: ObservableObject {
    @Published var targets: [AnnotationTarget] = []
    @Published var revealed = 0
    @Published var visible = false
}

struct PointingOverlayView: View {
    @ObservedObject var model: PointingOverlayModel
    private let blue = Color(red: 0.19, green: 0.49, blue: 1.0)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.visible {
                ForEach(model.targets.prefix(model.revealed)) { target in
                    annotation(target)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.3), value: model.revealed)
        .animation(.easeOut(duration: 0.25), value: model.visible)
        .ignoresSafeArea()
    }

    @ViewBuilder private func annotation(_ t: AnnotationTarget) -> some View {
        let r = t.rect
        switch t.kind {
        case .underline:
            ZStack(alignment: .topLeading) {
                SketchLine(seed: t.id)
                    .stroke(blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: max(12, r.width), height: 6)
                    .offset(x: r.minX, y: r.maxY + 1)
                    .shadow(color: blue.opacity(0.5), radius: 3)
                numberBadge(t.id).offset(x: r.minX - 26, y: r.midY - 9)
            }
        case .marker:
            // A heading or section: just the numbered badge beside it (an underline under a tall block looks wrong).
            numberBadge(t.id).offset(x: r.minX - 26, y: r.minY + min(r.height / 2, 11) - 9)
        case .box:
            let box = r.insetBy(dx: -8, dy: -8)
            ZStack(alignment: .topLeading) {
                SketchRing(seed: t.id + 2)
                    .stroke(blue, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
                    .shadow(color: blue.opacity(0.6), radius: 6)
                numberBadge(t.id).offset(x: box.minX - 9, y: box.minY - 9)
                if let label = t.label, !label.isEmpty {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(blue))
                        .offset(x: box.minX, y: box.maxY + 8)
                }
            }
        }
    }

    private func numberBadge(_ n: Int) -> some View {
        ZStack {
            Circle().fill(Color.white)
            Circle().stroke(blue, lineWidth: 1.5)
            Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(blue)
        }
        .frame(width: 18, height: 18)
        .shadow(color: blue.opacity(0.4), radius: 3)
    }
}

/// A slightly wavy horizontal line, like a quick pen underline.
struct SketchLine: Shape {
    var seed: Int
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let steps = max(4, Int(rect.width / 24))
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        for i in 1...steps {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(steps)
            let wobble = CGFloat(((seed * 31 + i * 17) % 7) - 3) * 0.35
            p.addLine(to: CGPoint(x: x, y: rect.midY + wobble))
        }
        return p
    }
}

/// A rounded rectangle traced with a little deterministic jitter, like a sketch.
struct SketchRing: Shape {
    var seed: Int
    func path(in rect: CGRect) -> Path {
        let r = min(14, rect.width / 4, rect.height / 4)
        let perimeter = Path(roundedRect: rect, cornerRadius: r)
        var points: [CGPoint] = []
        let segs = 64
        for i in 0..<segs {
            let t = CGFloat(i) / CGFloat(segs)
            let pt = perimeter.trimmedPath(from: 0, to: max(t, 0.0001)).currentPoint ?? CGPoint(x: rect.minX, y: rect.minY)
            let j = CGFloat(((seed * 11 + i * 5) % 5) - 2) * 0.6
            points.append(CGPoint(x: pt.x + j, y: pt.y + j))
        }
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: first)
        for pt in points.dropFirst() { p.addLine(to: pt) }
        p.closeSubpath()
        return p
    }
}
