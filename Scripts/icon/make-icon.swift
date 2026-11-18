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

let icon = render(size: 1024) { c in
    // soft drop shadow under the tile
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: col(0x000000, 0.35))
    c.addPath(squircle(tile)); c.setFillColor(col(0x1B1F5E)); c.fillPath()
    c.restoreGState()

    // tile background: deep indigo -> electric blue, diagonal
    c.saveGState(); c.addPath(squircle(tile)); c.clip()
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
    c.saveGState(); c.addPath(squircle(tile.insetBy(dx: 3, dy: 3))); c.setStrokeColor(col(0xFFFFFF, 0.28)); c.setLineWidth(5); c.strokePath()
    c.restoreGState()
}
save(icon, "icon_1024.png")

// Menu bar template glyph: two overlapping screens, black on clear (18pt @1x/2x/3x -> render 108 and let AppKit scale).
let glyph = render(size: 72) { c in
    c.setStrokeColor(col(0x000000)); c.setLineWidth(70); c.setLineJoin(.round)
    c.addPath(rr(CGRect(x: 90, y: 430, width: 520, height: 400), 70)); c.strokePath()
    c.setFillColor(col(0x000000)); c.addPath(rr(CGRect(x: 380, y: 170, width: 560, height: 420), 80)); c.fillPath()
    c.setBlendMode(.clear); c.setLineWidth(70)
    c.addPath(rr(CGRect(x: 380, y: 170, width: 560, height: 420).insetBy(dx: -45, dy: -45), 120)); c.strokePath()
}
save(glyph, "menubar_template.png")
