import AppKit
import SwiftUI
import Combine

/// Borderless, non-activating panel that can still take keyboard focus for the prompt box.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchWindowManager {
    let model: NotchViewModel
    private let panel: NotchPanel
    private var geometry: NotchGeometry
    private var cancellables = Set<AnyCancellable>()

    init() {
        geometry = NotchGeometry.current()
        model = NotchViewModel(geometry: geometry)

        panel = NotchPanel(
            contentRect: geometry.frame(for: model.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Notch"
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: NotchRootView(model: model))
        model.isMouseInside = { [weak panel] in
            guard let panel else { return false }
            return panel.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
        }

        Publishers.CombineLatest(model.$state, model.$hovering)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.layout(animated: true) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.screenChanged() }
            .store(in: &cancellables)
    }

    func show() {
        layout(animated: false)
        panel.orderFrontRegardless()
        Log.hud.info("HUD shown; notch=\(self.geometry.hasNotch) size=\(Int(self.geometry.notchSize.width))x\(Int(self.geometry.notchSize.height))")
    }

    /// Debug aid: writes the panel's current content as a PNG.
    func snapshot(to url: URL) {
        guard let view = panel.contentView else { return }
        let ok = DebugSnapshot.write(view: view, background: nil, appearance: panel.effectiveAppearance, to: url)
        Log.hud.info("snapshot ok=\(ok) frame=\(NSStringFromRect(self.panel.frame), privacy: .public) state=\(String(describing: self.model.state), privacy: .public)")
    }

    private func screenChanged() {
        let fresh = NotchGeometry.current()
        guard fresh != geometry else { return }
        geometry = fresh
        layout(animated: false)
    }

    private var wasPrompt = false

    private func layout(animated: Bool) {
        let target = geometry.frame(for: model.size)
        Log.hud.debug("layout \(NSStringFromRect(target), privacy: .public)")
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.26
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }

        let isPrompt = model.state == .prompt
        if isPrompt {
            panel.makeKey()
        } else if wasPrompt {
            // Give keyboard focus back to whatever app had it. Re-ordering a
            // non-activating panel is the sanctioned way to drop key status.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        wasPrompt = isPrompt
    }
}
