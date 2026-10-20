import AppKit

// Top-level code is nonisolated; hop onto the main actor explicitly.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let appDelegate = AppDelegate()
    app.delegate = appDelegate
    // Menubar-only app: no Dock icon, no app menu. Windows are opened on demand.
    app.setActivationPolicy(.accessory)
    app.run()
}
