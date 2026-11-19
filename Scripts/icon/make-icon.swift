// Renders the MacScreen app icon (1024 master) and the menu-bar template glyph.
// Usage: swift Scripts/icon/make-icon.swift <outdir>
import AppKit
import CoreGraphics

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func col(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((h>>16)&255)/255, CGFloat((h>>8)&255)/255, CGFloat(h&255)/255, a])!
}
func grad(_ cols: [CGColor], _ locs: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: locs)! }
func rr(_ r: CGRect, _ c: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: c, cornerHeight: c, transform: nil) }

func render(size: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    let c = g.cgContext
    c.scaleBy(x: CGFloat(size)/1024, y: CGFloat(size)/1024)
    draw(c)
    return rep
}
func save(_ rep: NSBitmapImageRep, _ name: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}

// macOS icon grid: 824pt squircle centred in 1024.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
func squircle(_ r: CGRect) -> CGPath {
    // continuous-corner approximation: superellipse n=5
    let p = CGMutablePath(); let n = 4.0; let steps = 360
    for i in 0...steps {
        let t = Double(i)/Double(steps)*2 * .pi
        let ct = cos(t), st = sin(t)
        let x = r.midX + CGFloat(copysign(pow(abs(ct), 2/n), ct)) * r.width/2
        let y = r.midY + CGFloat(copysign(pow(abs(st), 2/n), st)) * r.height/2
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath(); return p
}

/// The app icon artwork. `bleed` fills the whole canvas edge to edge (for apple-touch-icon); otherwise it is the
/// macOS squircle tile with a soft shadow.
func drawIcon(_ c: CGContext, bleed: Bool) {
    let shape = bleed ? CGPath(rect: tile, transform: nil) : squircle(tile)
    c.saveGState()
    if bleed {
        c.scaleBy(x: 1024 / tile.width, y: 1024 / tile.height)
        c.translateBy(x: -tile.minX, y: -tile.minY)
    } else {
        // soft drop shadow under the tile
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: col(0x000000, 0.35))
        c.addPath(shape); c.setFillColor(col(0x1B1F5E)); c.fillPath()
        c.restoreGState()
    }

    // tile background: deep indigo -> electric blue, diagonal
    c.saveGState(); c.addPath(shape); c.clip()
    c.drawLinearGradient(grad([col(0x6A5CFF), col(0x2D4BFF), col(0x0B1A7A)], [0, 0.5, 1]),
        start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    // light bloom top-left
    c.drawRadialGradient(grad([col(0xFFFFFF, 0.28), col(0xFFFFFF, 0)], [0, 1]),
        startCenter: CGPoint(x: 330, y: 860), startRadius: 0, endCenter: CGPoint(x: 330, y: 860), endRadius: 520, options: [])

    // back display (the "Mac"): translucent glass, upper-left
    let back = CGRect(x: 205, y: 475, width: 430, height: 290)
    c.setFillColor(col(0xFFFFFF, 0.20)); c.addPath(rr(back, 34)); c.fillPath()
    c.setStrokeColor(col(0xFFFFFF, 0.55)); c.setLineWidth(8); c.addPath(rr(back.insetBy(dx: 4, dy: 4), 30)); c.strokePath()

    // front display (the extended screen): bright, lower-right, with shadow
    let front = CGRect(x: 330, y: 270, width: 500, height: 340)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: col(0x050A40, 0.55))
    c.setFillColor(col(0xF4F6FF)); c.addPath(rr(front, 40)); c.fillPath()
    c.restoreGState()
    // bezel -> screen
    let screen = front.insetBy(dx: 22, dy: 22)
    c.saveGState(); c.addPath(rr(screen, 24)); c.clip()
    c.drawLinearGradient(grad([col(0x25D6FF), col(0x3A7BFF), col(0x7B4DFF)], [0, 0.55, 1]),
        start: CGPoint(x: screen.minX, y: screen.maxY), end: CGPoint(x: screen.maxX, y: screen.minY), options: [])
    // glass reflection
    c.setFillColor(col(0xFFFFFF, 0.16))
    c.move(to: CGPoint(x: screen.minX, y: screen.maxY)); c.addLine(to: CGPoint(x: screen.minX + 250, y: screen.maxY))
    c.addLine(to: CGPoint(x: screen.minX, y: screen.minY + 70)); c.closePath(); c.fillPath()
    c.restoreGState()

    // cursor arrow on the front screen
    c.saveGState()
    c.translateBy(x: 560, y: 520)
    let a = CGMutablePath()
    a.move(to: .zero); a.addLine(to: CGPoint(x: 0, y: -150)); a.addLine(to: CGPoint(x: 40, y: -113))
    a.addLine(to: CGPoint(x: 70, y: -178)); a.addLine(to: CGPoint(x: 98, y: -165))
    a.addLine(to: CGPoint(x: 68, y: -101)); a.addLine(to: CGPoint(x: 120, y: -101)); a.closeSubpath()
    c.setShadow(offset: CGSize(width: 4, height: -8), blur: 12, color: col(0x050A40, 0.5))
    c.setFillColor(col(0xFFFFFF)); c.addPath(a); c.fillPath()
    c.setShadow(offset: .zero, blur: 0)
    c.setStrokeColor(col(0x1B1F5E)); c.setLineWidth(9); c.setLineJoin(.round); c.addPath(a); c.strokePath()
    c.restoreGState()

    // inner top highlight on tile edge
    c.restoreGState()
    if !bleed {
        c.saveGState(); c.addPath(squircle(tile.insetBy(dx: 3, dy: 3))); c.setStrokeColor(col(0xFFFFFF, 0.28)); c.setLineWidth(5); c.strokePath()
        c.restoreGState()
    }
    c.restoreGState()
}
save(render(size: 1024) { drawIcon($0, bleed: false) }, "icon_1024.png")
save(render(size: 180) { drawIcon($0, bleed: true) }, "apple_touch_180.png")

// Open Graph / social preview card, 1200x630.
func renderRect(width: Int, height: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    draw(g.cgContext)
    return rep
}
func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, in rect: CGRect, lineHeight: CGFloat? = nil, kern: CGFloat = 0) {
    let style = NSMutableParagraphStyle()
    if let lh = lineHeight { style.minimumLineHeight = lh; style.maximumLineHeight = lh }
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
                                                .paragraphStyle: style, .kern: kern]
    NSAttributedString(string: s, attributes: attrs).draw(with: rect, options: [.usesLineFragmentOrigin])
}
save(renderRect(width: 1200, height: 630) { c in
    c.drawLinearGradient(grad([col(0x07081A), col(0x14186A), col(0x2D4BFF)], [0, 0.6, 1]),
        start: CGPoint(x: 0, y: 630), end: CGPoint(x: 1200, y: 0), options: [])
    c.drawRadialGradient(grad([col(0x25D6FF, 0.35), col(0x25D6FF, 0)], [0, 1]),
        startCenter: CGPoint(x: 1000, y: 120), startRadius: 0, endCenter: CGPoint(x: 1000, y: 120), endRadius: 460, options: [])
    c.drawRadialGradient(grad([col(0x6A5CFF, 0.5), col(0x6A5CFF, 0)], [0, 1]),
        startCenter: CGPoint(x: 150, y: 560), startRadius: 0, endCenter: CGPoint(x: 150, y: 560), endRadius: 420, options: [])
    // icon tile
    c.saveGState(); c.translateBy(x: 72, y: 410); c.scaleBy(x: 168 / 1024, y: 168 / 1024); drawIcon(c, bleed: false); c.restoreGState()
    text("MacScreen", size: 40, weight: .bold, color: .white, in: CGRect(x: 262, y: 440, width: 600, height: 60), kern: -0.6)
    text("Beta  \u{B7}  Free and open source", size: 24, weight: .medium, color: NSColor(white: 1, alpha: 0.7), in: CGRect(x: 262, y: 408, width: 600, height: 34))
    text("Any Mac’s screen, as if it were plugged into yours.", size: 76, weight: .bold, color: .white,
         in: CGRect(x: 72, y: 130, width: 1056, height: 250), lineHeight: 84, kern: -2)
    text("Turn any Mac into an extra display. Up to 5K, free and open source.", size: 28, weight: .regular,
         color: NSColor(white: 1, alpha: 0.78), in: CGRect(x: 72, y: 62, width: 1000, height: 70))
}, "og.png")

// Menu bar template glyph: two overlapping screens, black on clear (18pt @1x/2x/3x -> render 108 and let AppKit scale).
let glyph = render(size: 72) { c in
    c.setStrokeColor(col(0x000000)); c.setLineWidth(70); c.setLineJoin(.round)
    c.addPath(rr(CGRect(x: 90, y: 430, width: 520, height: 400), 70)); c.strokePath()
    c.setFillColor(col(0x000000)); c.addPath(rr(CGRect(x: 380, y: 170, width: 560, height: 420), 80)); c.fillPath()
    c.setBlendMode(.clear); c.setLineWidth(70)
    c.addPath(rr(CGRect(x: 380, y: 170, width: 560, height: 420).insetBy(dx: -45, dy: -45), 120)); c.strokePath()
}
save(glyph, "menubar_template.png")
