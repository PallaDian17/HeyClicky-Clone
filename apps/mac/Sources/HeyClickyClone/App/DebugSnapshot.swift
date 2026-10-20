import AppKit

/// Renders a view's layer tree to a PNG. Unlike `cacheDisplay`, this captures
/// SwiftUI's layer-hosted content, and it needs no Screen Recording grant.
enum DebugSnapshot {
    @MainActor
    static func write(view: NSView, background: NSColor?, appearance: NSAppearance?, to url: URL) -> Bool {
        guard let layer = view.layer else { return false }
        let scale = view.window?.backingScaleFactor ?? 2
        let size = view.bounds.size
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return false }
        ctx.scaleBy(x: scale, y: scale)

        let render = {
            if let background {
                ctx.setFillColor(background.cgColor)
                ctx.fill(CGRect(origin: .zero, size: size))
            }
            // CALayer renders top-down; AppKit layers are flipped relative to CG.
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            layer.render(in: ctx)
        }
        if let appearance {
            appearance.performAsCurrentDrawingAppearance(render)
        } else {
            render()
        }

        guard let cgImage = ctx.makeImage() else { return false }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url)
            return true
        } catch {
            Log.app.error("snapshot write failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
