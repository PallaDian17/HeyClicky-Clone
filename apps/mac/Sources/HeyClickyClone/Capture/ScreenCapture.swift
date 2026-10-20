import AppKit
import ScreenCaptureKit

/// One-shot screenshot of a display via ScreenCaptureKit, excluding this app's
/// own windows (HUD, overlay). Needs the Screen Recording grant.
enum ScreenCapture {
    struct Shot {
        let jpegBase64: String
        let pixelSize: CGSize       // of the encoded JPEG
        let screen: NSScreen        // what was captured; frames map back to it
    }

    enum Failure: Error { case noPermission, noDisplay, encodeFailed }

    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    static func capture(screen: NSScreen? = NSScreen.main, maxWidth: CGFloat = 1600, quality: CGFloat = 0.72) async throws -> Shot {
        guard isAuthorized else { throw Failure.noPermission }
        guard let screen else { throw Failure.noDisplay }
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw Failure.noDisplay
        }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let config = SCStreamConfiguration()
        let scale = min(1, maxWidth / CGFloat(display.width))
        config.width = Int(CGFloat(display.width) * scale * (scale == 1 ? screen.backingScaleFactor : 1))
        config.height = Int(CGFloat(display.height) * scale * (scale == 1 ? screen.backingScaleFactor : 1))
        config.showsCursor = true
        config.captureResolution = .best

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            throw Failure.encodeFailed
        }
        Log.app.info("screenshot \(image.width)x\(image.height) \(jpeg.count / 1024)KB")
        return Shot(jpegBase64: jpeg.base64EncodedString(), pixelSize: CGSize(width: image.width, height: image.height), screen: screen)
    }
}
