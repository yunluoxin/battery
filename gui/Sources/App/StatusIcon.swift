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
/// punched out of the battery rather than painted on top of it — the fill and
/// the outline are cleared around it and the bolt itself is drawn solid, which
/// is how the system's own charging battery is drawn. Painting it on top meant
/// the part of the bolt over the fill had to be flipped to the background
/// colour to stay visible, which read as a blob rather than a bolt.
///
/// The pixels are composited by hand rather than with `CGContext` blend modes
/// or `NSImage.draw(operation:)`; both of those silently degrade to plain
/// source-over when the source is a template image, which washed the icon out.
enum StatusIcon {
    /// Rasterisation scale, oversampling past the 2× the menu bar needs. The
    /// bolt and the gap around it are only a handful of points across, so at 2×
    /// their edges are visibly stepped; rendering at 4× and letting AppKit
    /// downscale keeps them smooth. The icon is only rebuilt when the level,
    /// mode or appearance changes, so the extra pixels cost nothing.
    private static let scale: CGFloat = 4

    /// The battery glyph's natural size. The status item needs a canvas size up
    /// front to attach a drawing handler to, and the icon must never be
    /// stretched away from this.
    static let canvasSize = CGSize(width: 22, height: 11)

    /// The charging bolt's shape as the system draws it: 6pt across for every
    /// 9pt of battery height. It is scaled off the measured body rather than
    /// given a fixed size, so it stays flush with the top and bottom strokes —
    /// and keeps doing so if Apple revises the symbol.
    private static let boltAspect: CGFloat = 6.0 / 9.0

    /// How much of the battery is cleared around the bolt. Without it the bolt
    /// merges into the fill block it crosses and stops reading as a bolt.
    private static let boltClearance: CGFloat = 0.75

    /// Apple's charging bolt, drawn in a 16 × 24 box with y running down, traced
    /// off the system's menu bar icon. SF Symbols has no symbol for it: `bolt.fill`
    /// is a different and heavier bolt, and the real one only ever shows up as the
    /// hole punched out of `battery.100.bolt` — which arrives already merged with
    /// the clearance around it, and carrying no level of its own.
    private static var boltPath: CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 10, y: 0))
        path.addLine(to: CGPoint(x: 12, y: 0))   // tip
        path.addLine(to: CGPoint(x: 9, y: 9))
        path.addLine(to: CGPoint(x: 16, y: 10))  // right wing of the waist
        path.addLine(to: CGPoint(x: 14, y: 13))
        path.addLine(to: CGPoint(x: 6, y: 24))   // down to the tail
        path.addLine(to: CGPoint(x: 4, y: 24))
        path.addLine(to: CGPoint(x: 7, y: 14))
        path.addLine(to: CGPoint(x: 0, y: 13))   // left wing of the waist
        path.addLine(to: CGPoint(x: 0, y: 12))
        path.addLine(to: CGPoint(x: 2, y: 10))
        path.closeSubpath()
        return path
    }

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
        guard let baseAlpha = alphaMap(base, canvas: size, rect: bounds),
              let outline = bodyBox(baseAlpha, canvas: size) else { return nil }

        var boltAlpha: [UInt8]?
        if charging {
            // Centred on the body, not on the canvas: the terminal nub takes the
            // right third, so the canvas centre would push the bolt off to the
            // right of where the system puts it.
            let height = outline.height
            let width = height * boltAspect
            let rect = CGRect(x: outline.midX - width / 2, y: outline.minY, width: width, height: height)
            boltAlpha = pathAlpha(boltPath, canvas: size, rect: rect, from: CGSize(width: 16, height: 24))
        }

        let body: RGB = tint.map { rgb($0) } ?? (dark ? (255, 255, 255) : (0, 0, 0))
        return compose(canvas: size, base: baseAlpha, bolt: boltAlpha, color: body)
    }

    // MARK: - Compositing

    /// The battery body in points, with the terminal nub excluded.
    ///
    /// The nub is the only part of the symbol that is not joined to the body —
    /// there is a clear column between the two — so walking in from the left and
    /// stopping at the first empty column lands exactly on the body's right
    /// edge. Measuring it beats hard-coding the 22×11 artwork's insets, which
    /// change whenever Apple revises the symbol.
    private static func bodyBox(_ alpha: [UInt8], canvas: CGSize) -> CGRect? {
        let width = Int(canvas.width * scale), height = Int(canvas.height * scale)
        // The half-covered contour is the artwork's real edge; anything paler
        // than that is antialiasing, and testing for mere presence would let it
        // bridge the gap between the body and the nub.
        let edge: UInt8 = 128
        var minX = -1, maxX = -1, minY = height, maxY = -1
        for x in 0..<width {
            var occupied = false
            for y in 0..<height where alpha[y * width + x] > edge {
                occupied = true
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
            guard occupied else {
                if minX >= 0 { break }   // the gap before the nub
                continue
            }
            if minX < 0 { minX = x }
            maxX = x
        }
        guard minX >= 0, maxX >= minX else { return nil }
        // The bitmap stores its first row at the top while the context's origin
        // is bottom-left, so the row range has to be flipped back into points.
        let bottom = canvas.height - CGFloat(maxY + 1) / scale
        let top = canvas.height - CGFloat(minY) / scale
        return CGRect(x: CGFloat(minX) / scale, y: bottom,
                      width: CGFloat(maxX - minX + 1) / scale,
                      height: top - bottom)
    }

    /// Alpha channel of `image` drawn into `rect` on a `canvas`-sized grid.
    private static func alphaMap(_ image: NSImage, canvas: CGSize, rect: CGRect) -> [UInt8]? {
        guard let cg = bitmap(image) else { return nil }
        return alphaGrid(canvas: canvas) { ctx in
            ctx.draw(cg, in: rect)
        }
    }

    /// Alpha channel of `path` — authored in a `from`-sized box with y running
    /// down — placed into `rect` on a `canvas`-sized grid.
    private static func pathAlpha(_ path: CGPath, canvas: CGSize, rect: CGRect, from size: CGSize) -> [UInt8]? {
        alphaGrid(canvas: canvas) { ctx in
            // The grid's origin is bottom-left and the path is authored top-down,
            // so the placement mirrors y and anchors to the rect's top edge.
            var place = CGAffineTransform(
                scaleX: rect.width / size.width,
                y: -rect.height / size.height
            )
            place = place.concatenating(CGAffineTransform(translationX: rect.minX, y: rect.maxY))
            ctx.concatenate(place)
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            ctx.fillPath()
        }
    }

    /// Runs `draw` on a cleared, oversampled grid and lifts its alpha channel out.
    private static func alphaGrid(canvas: CGSize, _ draw: (CGContext) -> Void) -> [UInt8]? {
        let width = Int(canvas.width * scale), height = Int(canvas.height * scale)
        guard let ctx = context(width: width, height: height) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        draw(ctx)

        let bytes = ctx.data?.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var alpha = [UInt8](repeating: 0, count: width * height)
        guard let bytes else { return nil }
        for i in 0..<(width * height) { alpha[i] = bytes[i * 4 + 3] }
        return alpha
    }

    /// Battery body in `color`, charging bolt punched through it: the battery is
    /// cleared within `boltClearance` of the bolt, then the bolt is drawn back
    /// in the same colour.
    private static func compose(canvas: CGSize, base: [UInt8], bolt: [UInt8]?, color: RGB) -> NSImage? {
        let width = Int(canvas.width * scale), height = Int(canvas.height * scale)
        guard let ctx = context(width: width, height: height),
              let bytes = ctx.data?.bindMemory(to: UInt8.self, capacity: width * height * 4)
        else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))

        let clearance = bolt.map { dilate($0, width: width, height: height, radius: boltClearance) }
        for i in 0..<(width * height) {
            var alpha = Int(base[i])
            if let bolt, let clearance {
                // Carve first, then fill the bolt back in. Doing it in this order
                // keeps the bolt's own edge at full strength — the clearance
                // never eats into it.
                alpha = alpha * (255 - Int(clearance[i])) / 255
                alpha += Int(bolt[i]) * (255 - alpha) / 255
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

    /// Grows `alpha` by `radius` points on every side — the clearance the
    /// charging bolt needs around itself. Separable, so a box this big costs
    /// two linear passes rather than one per neighbour.
    private static func dilate(_ alpha: [UInt8], width: Int, height: Int, radius: CGFloat) -> [UInt8] {
        let r = max(1, Int((radius * scale).rounded()))
        var out = alpha
        // Horizontal, into a scratch buffer, then vertical back into `out`.
        var scratch = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var best: UInt8 = 0
                let lo = max(0, x - r), hi = min(width - 1, x + r)
                for nx in lo...hi { best = max(best, alpha[y * width + nx]) }
                scratch[y * width + x] = best
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                var best: UInt8 = 0
                let lo = max(0, y - r), hi = min(height - 1, y + r)
                for ny in lo...hi { best = max(best, scratch[ny * width + x]) }
                out[y * width + x] = best
            }
        }
        return out
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
