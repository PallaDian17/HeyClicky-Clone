import AppKit
import SwiftUI

/// Circle-to-ask. While the talk key is held the overlay covers the screen and
/// takes the mouse: drag or circle something and the stroke is drawn as you go.
/// On release the bounding box becomes the selection and a small bar offers
/// Ask · Hand to a Clicky · Copy. Esc or ✕ dismisses. Releasing the key with
/// no stroke just takes the overlay away again.
@MainActor
final class RegionSelectOverlayManager {
    enum Action: Equatable { case ask, handoff(UUID?), copy }

    /// Normalized selection (0..1, top-left origin) on the armed screen.
    private(set) var selection: CGRect?
    private(set) var screen: NSScreen?
    var isArmed: Bool { panel?.isVisible ?? false }
    var hasSelection: Bool { selection != nil || canvas?.isDragging == true }

    var onAction: ((Action, CGRect) -> Void)?
    var onDismiss: (() -> Void)?
    /// Supplies the Clickys for the "Hand to" menu.
    var agentsProvider: () -> [(id: UUID, name: String)] = { [] }

    private var panel: RegionPanel?
    private var canvas: RegionCanvasView?
    private var bar: NSHostingView<RegionActionBar>?

    func arm(on screen: NSScreen? = NSScreen.main) {
        guard let screen else { return }
        if panel == nil || self.screen != screen { build(on: screen) }
        self.screen = screen
        selection = nil
        canvas?.reset()
        bar?.isHidden = true
        panel?.ignoresMouseEvents = false
        panel?.orderFrontRegardless()
        Log.hud.info("region overlay armed on \(screen.localizedName, privacy: .public)")
    }

    /// The key came up: keep the overlay only if the user drew something.
    func disarmIfIdle() {
        guard !hasSelection else { return }
        dismiss(notify: false)
    }

    func dismiss(notify: Bool = true) {
        selection = nil
        canvas?.reset()
        bar?.isHidden = true
        panel?.ignoresMouseEvents = true
        panel?.orderOut(nil)
        if notify { onDismiss?() }
    }

    /// Frame of the action bar in Quartz coordinates (debug: where to click).
    var actionBarQuartzFrame: CGRect? {
        guard let bar, !bar.isHidden, let panel, let primary = NSScreen.screens.first else { return nil }
        let inWindow = bar.convert(bar.bounds, to: nil)
        let onScreen = panel.convertToScreen(inWindow)
        return CGRect(x: onScreen.minX, y: primary.frame.height - onScreen.maxY, width: onScreen.width, height: onScreen.height)
    }

    private func build(on screen: NSScreen) {
        panel?.orderOut(nil)
        let panel = RegionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let canvas = RegionCanvasView(frame: NSRect(origin: .zero, size: screen.frame.size))
        canvas.onSelection = { [weak self] rect in self?.selected(rect) }
        canvas.onEscape = { [weak self] in self?.dismiss() }
        panel.contentView = canvas
        panel.onEscape = { [weak self] in self?.dismiss() }

        let bar = NSHostingView(rootView: RegionActionBar(manager: self))
        bar.isHidden = true
        canvas.addSubview(bar)
        self.panel = panel
        self.canvas = canvas
        self.bar = bar
    }

    /// `rect` is in view coordinates (bottom-left origin, points).
    private func selected(_ rect: CGRect) {
        guard let canvas, let bar else { return }
        let size = canvas.bounds.size
        selection = CGRect(x: rect.minX / size.width, y: 1 - rect.maxY / size.height,
                           width: rect.width / size.width, height: rect.height / size.height)
        bar.rootView = RegionActionBar(manager: self)
        let barSize = bar.fittingSize
        var origin = CGPoint(x: rect.maxX - barSize.width, y: rect.minY - barSize.height - 10)
        if origin.y < 8 { origin.y = rect.maxY + 10 }
        origin.x = max(8, min(origin.x, size.width - barSize.width - 8))
        bar.frame = CGRect(origin: origin, size: barSize)
        bar.isHidden = false
        panel?.makeKey()   // so Esc reaches us
        Log.hud.info("region selected \(NSStringFromRect(self.selection ?? .zero), privacy: .public) bar=\(NSStringFromRect(bar.frame), privacy: .public)")
    }

    fileprivate func choose(_ action: Action) {
        guard let selection else { return }
        let box = selection
        dismiss(notify: false)
        onAction?(action, box)
    }

    fileprivate func agents() -> [(id: UUID, name: String)] { agentsProvider() }
}

final class RegionPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

/// Draws the stroke and the selection; reports the bounding box on mouse up.
final class RegionCanvasView: NSView {
    var onSelection: ((CGRect) -> Void)?
    var onEscape: (() -> Void)?
    private(set) var isDragging = false
    private var points: [CGPoint] = []
    private let stroke = CAShapeLayer()
    private let dim = CAShapeLayer()
    private let box = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.18).cgColor
        dim.isHidden = true
        stroke.fillColor = nil
        stroke.strokeColor = NSColor.systemPurple.cgColor
        stroke.lineWidth = 4
        stroke.lineCap = .round
        stroke.lineJoin = .round
        stroke.shadowColor = NSColor.systemPurple.cgColor
        stroke.shadowOpacity = 0.7
        stroke.shadowRadius = 6
        box.fillColor = nil
        box.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        box.lineWidth = 1.5
        box.lineDashPattern = [6, 4]
        box.isHidden = true
        layer?.addSublayer(dim)
        layer?.addSublayer(stroke)
        layer?.addSublayer(box)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    func reset() {
        points = []
        isDragging = false
        stroke.path = nil
        box.isHidden = true
        dim.isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        reset()
        isDragging = true
        points = [convert(event.locationInWindow, from: nil)]
        redrawStroke()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        points.append(convert(event.locationInWindow, from: nil))
        redrawStroke()
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        points.append(convert(event.locationInWindow, from: nil))
        redrawStroke()
        var rect = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        guard rect.width > 14 || rect.height > 14 else { reset(); return }
        rect = rect.insetBy(dx: -8, dy: -8).intersection(bounds)
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRoundedRect(in: rect, cornerWidth: 10, cornerHeight: 10)
        dim.path = path
        dim.isHidden = false
        box.path = CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
        box.isHidden = false
        onSelection?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }

    private func redrawStroke() {
        guard points.count > 1 else { stroke.path = nil; return }
        let path = CGMutablePath()
        path.move(to: points[0])
        for p in points.dropFirst() { path.addLine(to: p) }
        stroke.path = path
    }
}

struct RegionActionBar: View {
    let manager: RegionSelectOverlayManager

    var body: some View {
        HStack(spacing: 6) {
            Button { manager.choose(.ask) } label: { Label("Ask", systemImage: "sparkles") }
                .buttonStyle(.borderedProminent).controlSize(.small)
            Menu {
                ForEach(manager.agents(), id: \.id) { agent in
                    Button("Hand to \(agent.name)") { manager.choose(.handoff(agent.id)) }
                }
                if manager.agents().isEmpty { Button("Hand to a Clicky") { manager.choose(.handoff(nil)) } }
            } label: { Label("Hand to", systemImage: "person.fill.badge.plus") }
                .menuStyle(.borderlessButton).controlSize(.small).fixedSize()
            Button { manager.choose(.copy) } label: { Label("Copy", systemImage: "doc.on.doc") }
                .controlSize(.small)
            Button { manager.dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).controlSize(.small).padding(.leading, 2)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.ultraThickMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.15)))
        .fixedSize()
    }
}

extension ScreenCapture.Shot {
    /// Crops the screenshot to a normalized box (top-left origin) and re-encodes it.
    func crop(normalized box: CGRect, quality: CGFloat = 0.85) -> (jpegBase64: String, data: Data)? {
        guard let data = Data(base64Encoded: jpegBase64), let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let rect = CGRect(x: box.minX * w, y: box.minY * h, width: box.width * w, height: box.height * h)
            .insetBy(dx: -8, dy: -8).intersection(CGRect(x: 0, y: 0, width: w, height: h)).integral
        guard rect.width >= 4, rect.height >= 4, let cropped = cg.cropping(to: rect) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cropped)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { return nil }
        return (jpeg.base64EncodedString(), jpeg)
    }

    func cropPNG(normalized box: CGRect) -> Data? {
        guard let data = Data(base64Encoded: jpegBase64), let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let rect = CGRect(x: box.minX * w, y: box.minY * h, width: box.width * w, height: box.height * h).integral
        guard let cropped = cg.cropping(to: rect) else { return nil }
        return NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
    }
}
