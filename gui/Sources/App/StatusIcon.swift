import AppKit

/// Renders the menu bar battery icon.
///
/// The fill always comes from the real percentage. Modes used to hard-code
/// `battery.100.bolt` (maintain/charge) and `battery.75` (discharge), which made
/// a half-full pack look permanently full — the exact reading the system
/// battery icon sitting next to it never gives you.
///
/// Charging is drawn by compositing a bolt over the level symbol: SF Symbols
/// only ships `battery.100.bolt`, there is no `battery.50.bolt`. The bolt is
/// drawn in the contrasting colour where it crosses the fill, which is how the
/// system draws its own charging battery.
///
/// The pixels are composited by hand rather than with `CGContext` blend modes
/// or `NSImage.draw(operation:)`; both of those silently degrade to plain
/// source-over when the source is a template image, which washed the icon out.
enum StatusIcon {
    /// Rasterisation scale, oversampling past the 2× the menu bar needs. The
    /// bolt is only ~4×5pt, so at 2× its edges are visibly stepped; rendering
    /// at 4× and letting AppKit downscale keeps them smooth. The icon is only
    /// rebuilt when the level, mode or appearance changes, so the extra pixels
    /// cost nothing.
    private static let scale: CGFloat = 4

    /// The five fill buckets the system battery icon uses.
    static func level(for percentage: Int) -> Int {
        switch percentage {
        case 0..<13: return 0
        case 13..<38: return 25
        case 38..<63: return 50
        case 63..<88: return 75
        default: return 100
        }
    }

    /// Battery icon for a fill level, with a charging bolt when `charging`.
    ///
    /// - Parameters:
    ///   - tint: paints the battery in one flat colour (Low Power Mode yellow).
    ///   - dark: whether the menu bar is dark, which decides whether the
    ///     battery is white-on-dark or black-on-light.
    static func image(level: Int, charging: Bool, dark: Bool, tint: NSColor? = nil) -> NSImage? {
        // Only the five buckets have a symbol; anything else has no glyph.
        let bucket = [0, 25, 50, 75, 100].min(by: { abs($0 - level) < abs($1 - level) }) ?? 100
        guard let base = symbol("battery.\(bucket)", "Battery") else { return nil }
        // Draw at the symbol's natural size — the battery glyph is 22×11, and
        // stretching it into a square canvas distorts the outline.
        let size = base.size
        let bounds = CGRect(origin: .zero, size: size)
        guard let baseAlpha = alphaMap(base, canvas: size, rect: bounds) else { return nil }

        var boltAlpha: [UInt8]?
        if charging, let bolt = symbol("bolt.fill", nil) {
            let height = size.height * 0.55
            let width = height * bolt.size.width / bolt.size.height
            // The right ~15% of the battery symbol is the terminal nub rather
            // than body, so the bolt sits left of the geometric centre.
            let rect = CGRect(x: size.width * 0.44 - width / 2, y: (size.height - height) / 2, width: width, height: height)
            boltAlpha = alphaMap(bolt, canvas: size, rect: rect)
        }

        let body: RGB = tint.map { rgb($0) } ?? (dark ? (255, 255, 255) : (0, 0, 0))
        let accent: RGB = dark ? (0, 0, 0) : (255, 255, 255)
        return compose(canvas: size, base: baseAlpha, bolt: boltAlpha, body: body, accent: accent)
    }

    // MARK: - Compositing

    /// Alpha channel of `image` drawn into `rect` on a `canvas`-sized grid.
    private static func alphaMap(_ image: NSImage, canvas: CGSize, rect: CGRect) -> [UInt8]? {
        let width = Int(canvas.width * scale), height = Int(canvas.height * scale)
        guard let ctx = context(width: width, height: height),
              let cg = bitmap(image) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.draw(cg, in: rect)

        let bytes = ctx.data?.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var alpha = [UInt8](repeating: 0, count: width * height)
        guard let bytes else { return nil }
        for i in 0..<(width * height) { alpha[i] = bytes[i * 4 + 3] }
        return alpha
    }

    /// Battery body in `body`, charging bolt in `body` over the empty interior
    /// and in `accent` where it sits on the fill.
    private static func compose(canvas: CGSize, base: [UInt8], bolt: [UInt8]?, body: RGB, accent: RGB) -> NSImage? {
        let width = Int(canvas.width * scale), height = Int(canvas.height * scale)
        guard let ctx = context(width: width, height: height),
              let bytes = ctx.data?.bindMemory(to: UInt8.self, capacity: width * height * 4)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))

        for i in 0..<(width * height) {
            let under = Int(base[i])
            var alpha = under
            var color = body
            if let bolt, bolt[i] > 0 {
                let over = Int(bolt[i])
                alpha = under + over * (255 - under) / 255
                color = under > 0 ? accent : body
            }
            guard alpha > 0 else { continue }
            // Premultiplied RGBA.
            bytes[i * 4 + 0] = UInt8(Int(color.0) * alpha / 255)
            bytes[i * 4 + 1] = UInt8(Int(color.1) * alpha / 255)
            bytes[i * 4 + 2] = UInt8(Int(color.2) * alpha / 255)
            bytes[i * 4 + 3] = UInt8(alpha)
        }

        guard let cg = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        // The backing store is `scale`× the points; the representation has to
        // report the point size or the status item draws the icon oversized.
        rep.size = canvas
        let image = NSImage(size: canvas)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Helpers

    private typealias RGB = (UInt8, UInt8, UInt8)

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func symbol(_ name: String, _ description: String?) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    private static func bitmap(_ image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private static func rgb(_ color: NSColor) -> RGB {
        // Catalog colours (systemYellow and friends) raise on `getRed:` until
        // they are converted out of their named colour space.
        let converted = color.usingColorSpace(.deviceRGB) ?? NSColor.black
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        converted.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
    }
}
