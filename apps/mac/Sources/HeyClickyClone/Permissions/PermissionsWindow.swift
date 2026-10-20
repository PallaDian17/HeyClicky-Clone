import AppKit
import SwiftUI

@MainActor
final class PermissionsWindowController {
    let window: NSWindow
    private let model: PermissionsModel
    private var pollTimer: Timer?

    init(model: PermissionsModel) {
        self.model = model
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Permissions"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PermissionsView(model: model))
        window.center()
    }

    func show() {
        model.refresh()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.window.isVisible else { self.pollTimer?.invalidate(); return }
                self.model.refresh()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }
}

struct PermissionsView: View {
    @ObservedObject var model: PermissionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Let Clicky see and hear").font(.title2.weight(.semibold))
                Text("macOS asks once per permission. Nothing runs in the background without the hotkey.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                ForEach(PermissionsModel.Kind.allCases) { kind in
                    row(kind)
                }
            }

            Spacer(minLength: 0)

            HStack {
                if model.allGranted {
                    Label("All set", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if model.allRequiredGranted {
                    Label("Enough to start. The rest unlock voice and screen features.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    Label("Accessibility is required for the hotkey.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                Spacer()
                Button("Refresh") { model.refresh() }
            }
        }
        .padding(24)
        .padding(.top, 8)
        .frame(width: 520, height: 470)
    }

    private func row(_ kind: PermissionsModel.Kind) -> some View {
        let status = model.status(kind)
        return HStack(spacing: 14) {
            Image(systemName: kind.symbol)
                .font(.system(size: 18))
                .frame(width: 30)
                .foregroundStyle(status == .granted ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(kind.title).fontWeight(.medium)
                    if kind.required {
                        Text("required").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.2))).foregroundStyle(.orange)
                    }
                }
                Text(kind.reason).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch status {
            case .granted:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .notDetermined:
                Button("Allow") { model.request(kind) }
            case .denied:
                // Request first so TCC registers this exact build, then the user flips it on in Settings.
                Button("Allow") { model.request(kind) }
                Button("Settings") { model.openSettings(kind) }.controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
