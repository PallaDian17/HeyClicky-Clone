import AppKit

/// Where the HUD anchors: the camera notch on a built-in display, or the
/// top-centre of the menu bar on displays without one.
struct NotchGeometry: Equatable {
    static let ear: CGFloat = 8          // the curved "ears" that blend into the menu bar
    let screenFrame: NSRect
    let hasNotch: Bool
    let notchSize: CGSize                // points; height == menu bar height

    var topCenter: CGPoint { CGPoint(x: screenFrame.midX, y: screenFrame.maxY) }

    static func current() -> NotchGeometry {
        let screens = NSScreen.screens
        let screen = screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? screens[0]
        let inset = screen.safeAreaInsets.top
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchGeometry(screenFrame: screen.frame, hasNotch: true,
                                 notchSize: CGSize(width: width.rounded(), height: inset))
        }
        let menuBar = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        return NotchGeometry(screenFrame: screen.frame, hasNotch: false,
                             notchSize: CGSize(width: 184, height: menuBar))
    }

    /// Window frame for a HUD body of `size`, centred under the notch, ears included.
    func frame(for size: CGSize) -> NSRect {
        let width = size.width + Self.ear * 2
        return NSRect(x: (topCenter.x - width / 2).rounded(),
                      y: topCenter.y - size.height,
                      width: width,
                      height: size.height)
    }
}
