import AppKit
import SwiftUI

/// One shortcut row in Setup → Hotkey: the gesture, its current keys, and a
/// Record button. Recording watches the window's modifier-key events, keeps
/// the largest set of modifiers held together, and commits when they are all
/// released. Modifier combos only (that is what the gestures are built on).
struct ShortcutRecorderRow: View {
    let title: String
    let detail: String
    let flags: CGEventFlags
    let onChange: (CGEventFlags) -> Void
    @State private var recording = false
    @State private var held: CGEventFlags = []
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(recording ? (held.isEmpty ? "Press the keys…" : HotkeyMonitor.label(held)) : HotkeyMonitor.label(flags))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(recording ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08)))
            Button(recording ? "Cancel" : "Record") { recording ? stop(commit: false) : start() }
                .controlSize(.small)
        }
        .onDisappear { stop(commit: false) }
    }

    private func start() {
        recording = true
        held = []
        var maxHeld: CGEventFlags = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let now = Self.cgFlags(event.modifierFlags)
            if !now.isEmpty {
                maxHeld.formUnion(now)
                held = maxHeld
            } else if !maxHeld.isEmpty {
                let result = maxHeld
                DispatchQueue.main.async {
                    stop(commit: false)
                    onChange(result)
                }
            }
            return event
        }
    }

    private func stop(commit: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        held = []
    }

    static func cgFlags(_ m: NSEvent.ModifierFlags) -> CGEventFlags {
        var f: CGEventFlags = []
        if m.contains(.control) { f.insert(.maskControl) }
        if m.contains(.option) { f.insert(.maskAlternate) }
        if m.contains(.shift) { f.insert(.maskShift) }
        if m.contains(.command) { f.insert(.maskCommand) }
        if m.contains(.function) { f.insert(.maskSecondaryFn) }
        return f
    }
}
