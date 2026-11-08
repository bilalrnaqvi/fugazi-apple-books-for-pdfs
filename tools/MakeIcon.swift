import AppKit
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let r = NSRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset)
    let bg = NSBezierPath(roundedRect: r, xRadius: s*0.18, yRadius: s*0.18)
    NSGradient(starting: NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.22, alpha: 1),
               ending: NSColor(calibratedRed: 0.93, green: 0.36, blue: 0.16, alpha: 1))!.draw(in: bg, angle: -90)
    // open book: two pages
    let w = r.width * 0.30, h = r.height * 0.52, cy = r.midY - h/2 - s*0.01
    for (i, x) in [r.midX - w - s*0.012, r.midX + s*0.012].enumerated() {
        let p = NSBezierPath(roundedRect: NSRect(x: x, y: cy, width: w, height: h), xRadius: s*0.02, yRadius: s*0.02)
        NSColor.white.setFill(); p.fill()
        // image block + text lines
        NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.55, alpha: 1).setFill()
        if i == 0 { NSBezierPath(rect: NSRect(x: x + w*0.14, y: cy + h*0.52, width: w*0.72, height: h*0.32)).fill() }
        NSColor(calibratedWhite: 0.75, alpha: 1).setFill()
        let lines = i == 0 ? 3 : 7
        for l in 0..<lines {
            let ly = cy + h*0.12 + CGFloat(l) * h*0.105
            NSBezierPath(rect: NSRect(x: x + w*0.14, y: ly, width: w*(l == lines-1 ? 0.45 : 0.72), height: h*0.035)).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    try! draw(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
