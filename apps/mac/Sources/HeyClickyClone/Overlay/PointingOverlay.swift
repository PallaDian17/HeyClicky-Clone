import AppKit
import SwiftUI

/// A click-through window over one screen that draws a blue pointer around a
/// target rectangle, the "it's right here" part of talk mode.
@MainActor
final class PointingOverlayManager {
    private var window: NSWindow?
    private let model = PointingOverlayModel()
    private var hideTask: Task<Void, Never>?

    /// Shows the pointer around `rect`, given in Quartz global coordinates
    /// (points, top-left origin on the primary display).
    func show(quartzRect rect: CGRect, label: String?, autoHideAfter seconds: TimeInterval = 8) {
        guard let primary = NSScreen.screens.first else { return }
        let primaryHeight = primary.frame.height
        let nsPoint = CGPoint(x: rect.midX, y: primaryHeight - rect.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(nsPoint) }) ?? primary

        let window = ensureWindow(on: screen)
        // Window-local, top-left origin, which is what SwiftUI draws in.
        let local = CGRect(x: rect.minX - screen.frame.minX,
                           y: rect.minY - (primaryHeight - screen.frame.maxY),
                           width: rect.width, height: rect.height)
        model.target = local
        model.label = label
        model.visible = true
        window.orderFrontRegardless()
        Log.hud.info("pointer at \(NSStringFromRect(local), privacy: .public) on screen \(screen.localizedName, privacy: .public)")

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    /// Converts a box normalized to a screenshot of `screen` into the pointer.
    func show(normalizedBox box: CGRect, on screen: NSScreen, label: String?, autoHideAfter seconds: TimeInterval = 8) {
        guard let primary = NSScreen.screens.first else { return }
        let primaryHeight = primary.frame.height
        let quartz = CGRect(x: screen.frame.minX + box.minX * screen.frame.width,
                            y: (primaryHeight - screen.frame.maxY) + box.minY * screen.frame.height,
                            width: box.width * screen.frame.width,
                            height: box.height * screen.frame.height)
        show(quartzRect: quartz, label: label, autoHideAfter: seconds)
    }

    func hide() {
        hideTask?.cancel()
        model.visible = false
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.3))
            self?.window?.orderOut(nil)
        }
    }

    private func ensureWindow(on screen: NSScreen) -> NSWindow {
        if let window, window.frame == screen.frame { return window }
        window?.orderOut(nil)
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
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
    @Published var target: CGRect = .zero
    @Published var label: String?
    @Published var visible = false
}

struct PointingOverlayView: View {
    @ObservedObject var model: PointingOverlayModel
    private let blue = Color(red: 0.19, green: 0.49, blue: 1.0)

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                if model.visible {
                    let pad: CGFloat = 8
                    let box = model.target.insetBy(dx: -pad, dy: -pad)
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let pulse = 0.5 + 0.5 * sin(t * 4)
                        ZStack(alignment: .topLeading) {
                            // Hand-drawn style ring around the target.
                            SketchRing(seed: 3)
                                .stroke(blue, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                                .frame(width: box.width, height: box.height)
                                .offset(x: box.minX, y: box.minY)
                                .shadow(color: blue.opacity(0.6), radius: 6)
                            // Pulsing dot at the top-left corner, like a cursor.
                            Circle()
                                .fill(blue)
                                .frame(width: 14, height: 14)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                                .scaleEffect(1 + 0.25 * pulse)
                                .offset(x: box.minX - 7, y: box.minY - 7)
                            if let label = model.label, !label.isEmpty {
                                Text(label)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Capsule().fill(blue))
                                    .offset(x: box.minX, y: box.maxY + 8)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.easeOut(duration: 0.25), value: model.visible)
        }
        .ignoresSafeArea()
    }
}

/// A rounded rectangle with a slightly wobbly, sketched outline.
struct SketchRing: Shape {
    var seed: Int
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(14, rect.width / 4, rect.height / 4)
        let base = Path(roundedRect: rect, cornerRadius: r)
        // Sample the rounded rect and perturb points deterministically.
        let steps = 48
        var pts: [CGPoint] = []
        for i in 0..<steps {
            let a = Double(i) / Double(steps) * 2 * .pi
            let x = rect.midX + cos(a) * rect.width / 2
            let y = rect.midY + sin(a) * rect.height / 2
            let wobble = 1.5 * sin(Double(i * (seed + 5)) * 1.7)
            pts.append(CGPoint(x: x + wobble, y: y + wobble))
        }
        // Project onto the rounded-rect outline by clamping into the rect.
        let clamped = pts.map { CGPoint(x: min(max($0.x, rect.minX), rect.maxX), y: min(max($0.y, rect.minY), rect.maxY)) }
        p.addLines(clamped)
        p.closeSubpath()
        return rect.width < 40 || rect.height < 40 ? base : p
    }
}
