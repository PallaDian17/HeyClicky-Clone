import AppKit
import Darwin
import Sentry

/// Crash reporting with two layers: Sentry when a DSN is configured
/// (Info.plist `SentryDSN`), and always a local report written to
/// Application Support/HeyClickyClone/crashes/ for uncaught exceptions and
/// fatal signals, surfaced in Setup on the next launch.
enum CrashReporter {
    static var directory: URL { AppConfig.appSupportDirectory.appendingPathComponent("crashes", isDirectory: true) }
    private static let lastSeenKey = "ClickyCrashLastSeen"
    static var sentryEnabled = false
    /// Set once an exception report is written so the SIGABRT that follows is not reported twice.
    nonisolated(unsafe) static var exceptionReported = false

    static func install() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let dsn = Bundle.main.infoDictionary?["SentryDSN"] as? String, !dsn.isEmpty, dsn.hasPrefix("http") {
            SentrySDK.start { options in
                options.dsn = dsn
                options.releaseName = "heyclickyclone@\(AppConfig.version)"
                options.enableAutoSessionTracking = true
                options.tracesSampleRate = 0
                options.beforeSend = { event in
                    // Never ship transcript or screen content: the event carries the stack and app state only.
                    event.message = nil
                    event.breadcrumbs = nil
                    return event
                }
            }
            sentryEnabled = true
            Log.app.info("crash reporting: sentry on + local")
        } else {
            Log.app.info("crash reporting: local only (no SentryDSN)")
        }

        NSSetUncaughtExceptionHandler { exception in
            let text = "Uncaught exception \(exception.name.rawValue): \(exception.reason ?? "")\n\n" + exception.callStackSymbols.joined(separator: "\n")
            CrashReporter.exceptionReported = true
            CrashReporter.write(kind: "exception", text: text)
        }
        for sig in [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP] {
            signal(sig) { s in
                if CrashReporter.exceptionReported { signal(s, SIG_DFL); raise(s); return }
                // Async-signal-safe enough for a last-ditch note: write the signal and a raw backtrace.
                var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
                let n = backtrace(&frames, Int32(frames.count))
                let path = CrashReporter.directory.appendingPathComponent("signal-\(Int(Date().timeIntervalSince1970)).txt").path
                let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
                if fd >= 0 {
                    let header = "Fatal signal \(s)\n\n"
                    header.withCString { _ = Darwin.write(fd, $0, strlen($0)) }
                    backtrace_symbols_fd(&frames, n, fd)
                    close(fd)
                }
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    static func write(kind: String, text: String) {
        let url = directory.appendingPathComponent("\(kind)-\(Int(Date().timeIntervalSince1970)).txt")
        let body = "Hi Dicky \(AppConfig.version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(Date().formatted())\n\n\(text)\n"
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Crash files newer than the last one the user saw.
    static func unseenReports() -> [URL] {
        let last = UserDefaults.standard.double(forKey: lastSeenKey)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { url in
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
            return url.pathExtension == "txt" && m > last
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func markSeen() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastSeenKey)
    }

    static func allReports() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Sends a local report through Sentry when it is on; returns whether it went anywhere.
    static func send(_ url: URL) -> Bool {
        guard sentryEnabled, let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        SentrySDK.capture(message: "Crash report \(url.lastPathComponent)") { scope in
            scope.setExtra(value: String(text.prefix(8000)), key: "report")
        }
        return true
    }

    /// Debug hook: `heyclickyclone://crash/test?kind=exception|signal`.
    static func simulate(_ kind: String) {
        switch kind {
        case "signal": raise(SIGSEGV)
        default: NSException(name: .internalInconsistencyException, reason: "test crash from debug route", userInfo: nil).raise()
        }
    }
}
