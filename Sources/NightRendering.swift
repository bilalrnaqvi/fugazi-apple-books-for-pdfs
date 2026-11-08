import Foundation
import AppKit
import PDFKit
import CoreImage
import CoreGraphics

// MARK: - Where are the pictures? (scan the page's content stream for image placements)

enum PDFImageFinder {
    private final class State {
        var ctm = CGAffineTransform.identity
        var stack: [CGAffineTransform] = []
        var rects: [CGRect] = []
        var resources: CGPDFDictionaryRef?
        var stream: CGPDFContentStreamRef?
        var depth = 0
    }

    private static func st(_ info: UnsafeMutableRawPointer?) -> State {
        Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
    }

    private static let table: CGPDFOperatorTableRef = {
        let t = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(t, "q") { _, info in let s = st(info); s.stack.append(s.ctm) }
        CGPDFOperatorTableSetCallback(t, "Q") { _, info in let s = st(info); if let c = s.stack.popLast() { s.ctm = c } }
        CGPDFOperatorTableSetCallback(t, "cm") { scanner, info in
            var v = [CGPDFReal](repeating: 0, count: 6)
            for i in stride(from: 5, through: 0, by: -1) { CGPDFScannerPopNumber(scanner, &v[i]) }
            let s = st(info)
            s.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.ctm)
        }
        CGPDFOperatorTableSetCallback(t, "Do") { scanner, info in
            let s = st(info)
            var namePtr: UnsafePointer<Int8>?
            guard CGPDFScannerPopName(scanner, &namePtr), let namePtr, let res = s.resources else { return }
            var xobjs: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(res, "XObject", &xobjs), let xobjs else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFDictionaryGetStream(xobjs, namePtr, &stream), let stream,
                  let dict = CGPDFStreamGetDictionary(stream) else { return }
            var sub: UnsafePointer<Int8>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &sub), let sub else { return }
            switch String(cString: sub) {
            case "Image":
                s.rects.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(s.ctm))
            case "Form" where s.depth < 4:
                var m = CGAffineTransform.identity
                var arr: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dict, "Matrix", &arr), let arr, CGPDFArrayGetCount(arr) == 6 {
                    var v = [CGPDFReal](repeating: 0, count: 6)
                    for i in 0..<6 { CGPDFArrayGetNumber(arr, i, &v[i]) }
                    m = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                }
                var formRes: CGPDFDictionaryRef?
                _ = CGPDFDictionaryGetDictionary(dict, "Resources", &formRes)
                guard let parentCS = s.stream else { return }
                let saved = (s.ctm, s.stack, s.resources, s.stream)
                s.ctm = m.concatenating(s.ctm); s.stack = []; s.resources = formRes ?? s.resources; s.depth += 1
                let cs = CGPDFContentStreamCreateWithStream(stream, dict, parentCS)
                s.stream = cs
                let sc = CGPDFScannerCreate(cs, table, info)
                CGPDFScannerScan(sc)
                CGPDFScannerRelease(sc); CGPDFContentStreamRelease(cs)
                s.depth -= 1
                (s.ctm, s.stack, s.resources, s.stream) = saved
            default: break
            }
        }
        return t
    }()

    /// Bounding boxes (PDF user space) of every image drawn on the page.
    static func imageRects(in page: CGPDFPage) -> [CGRect] {
        let state = State()
        if let dict = page.dictionary {
            var res: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dict, "Resources", &res) { state.resources = res }
        }
        let info = Unmanaged.passUnretained(state).toOpaque()
        let cs = CGPDFContentStreamCreateWithPage(page)
        state.stream = cs
        let sc = CGPDFScannerCreate(cs, table, info)
        CGPDFScannerScan(sc)
        CGPDFScannerRelease(sc); CGPDFContentStreamRelease(cs)
        return state.rects.map { $0.standardized }
    }
}

// MARK: - Night page: dark paper + light ink, pictures left exactly as printed

enum NightRendering {
    static var enabled = false
    static let ciContext = CIContext(options: [.cacheIntermediates: false])
    static let cache: NSCache<NSString, CGImage> = { let c = NSCache<NSString, CGImage>(); c.countLimit = 24; return c }()
    /// Scale the view last drew at; prefetches render at the same scale so they hit the cache.
    static var lastScale: CGFloat = 2
    /// Called on the main thread after a page has been drawn dark (used to lift the turn cover).
    static var onPageDrawn: ((PDFPage) -> Void)?
    /// Most recent dark render of each page at any scale (for the page-turn cover).
    static let latest: NSCache<NSString, CGImage> = { let c = NSCache<NSString, CGImage>(); c.countLimit = 24; return c }()
    static func remember(_ img: CGImage, for page: NightPage) {
        latest.setObject(img, forKey: "\(ObjectIdentifier(page).hashValue)" as NSString)
    }
    static func cachedImage(for page: NightPage, box: PDFDisplayBox) -> CGImage? {
        cache.object(forKey: page.renderJob(box: box, scale: lastScale).key as NSString)
            ?? latest.object(forKey: "\(ObjectIdentifier(page).hashValue)" as NSString)
    }
    private static let queue = DispatchQueue(label: "folio.night.prefetch", qos: .userInitiated)
    private static var inFlight = Set<String>()
    private static let lock = NSLock()

    /// Pre-render the pages around `index` in the background so turning the page never shows white.
    static func prefetch(_ doc: PDFDocument, around index: Int, box: PDFDisplayBox = .cropBox) {
        guard enabled else { return }
        let scale = lastScale
        for i in [index, index + 1, index + 2, index + 3, index - 1, index - 2, index + 4, index - 3] where i >= 0 && i < doc.pageCount {
            guard let page = doc.page(at: i) as? NightPage else { continue }
            let job = page.renderJob(box: box, scale: scale)
            let key = job.key
            if cache.object(forKey: key as NSString) != nil { continue }
            lock.lock()
            let dup = inFlight.contains(key)
            if !dup { inFlight.insert(key) }
            lock.unlock()
            if dup { continue }
            queue.async {
                if let img = NightPage.render(job) {
                    cache.setObject(img, forKey: key as NSString)
                    DispatchQueue.main.async { remember(img, for: page) }
                }
                lock.lock(); inFlight.remove(key); lock.unlock()
            }
        }
    }
}

final class NightPageDelegate: NSObject, PDFDocumentDelegate {
    static let shared = NightPageDelegate()
    func classForPage() -> AnyClass { NightPage.self }
}

final class NightPage: PDFPage {
    private var imageRects: [CGRect]?
    private let memoLock = NSLock()

    private func images() -> [CGRect] {
        memoLock.lock(); defer { memoLock.unlock() }
        if let imageRects { return imageRects }
        var rects: [CGRect] = []
        if let ref = pageRef {
            let area = bounds(for: .mediaBox).width * bounds(for: .mediaBox).height
            _ = area
            rects = PDFImageFinder.imageRects(in: ref).filter { r in r.width > 6 && r.height > 6 }
        }
        imageRects = rects
        return rects
    }

    /// Everything a background thread needs to render this page: plain values, no PDFKit objects.
    struct RenderJob {
        let key: String
        let pageRef: CGPDFPage
        let frame: CGRect
        let transform: CGAffineTransform
        let scale: CGFloat
        let imageRects: [CGRect]
    }

    func renderJob(box: PDFDisplayBox, scale: CGFloat) -> RenderJob {
        let t = transform(for: box)
        let frame = bounds(for: box).applying(t)
        return RenderJob(key: "\(ObjectIdentifier(self).hashValue)-\(box.rawValue)-\(Int(scale * 8))",
                         pageRef: pageRef!, frame: frame, transform: t, scale: scale, imageRects: images())
    }

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        guard NightRendering.enabled, pageRef != nil else {
            if NightRendering.enabled { NSLog("folio: FALLBACK no pageRef") }
            super.draw(with: box, to: context); return
        }
        let m = context.ctm
        let scale = min(4, max(0.4, hypot(m.a, m.b)))
        if ProcessInfo.processInfo.environment["FOLIO_TRACE"] != nil {
            NSLog("folio: draw page=%d scale=%.2f clip=%@ main=%d", document?.index(for: self) ?? -1, scale, NSStringFromRect(context.boundingBoxOfClipPath), Thread.isMainThread ? 1 : 0)
        }
        NightRendering.lastScale = scale
        let job = renderJob(box: box, scale: scale)
        guard job.frame.width > 0, job.frame.height > 0 else { NSLog("folio: FALLBACK bad frame"); super.draw(with: box, to: context); return }
        var img = NightRendering.cache.object(forKey: job.key as NSString)
        if img == nil {
            let t0 = CACurrentMediaTime()
            if let r = NightPage.render(job) {
                NightRendering.cache.setObject(r, forKey: job.key as NSString)
                DispatchQueue.main.async { [weak self] in if let self { NightRendering.remember(r, for: self) } }
                img = r
            }
            if ProcessInfo.processInfo.environment["FOLIO_TRACE"] != nil {
                NSLog("folio: render page=%d scale=%.2f ok=%d took=%.0fms", document?.index(for: self) ?? -1, scale, img == nil ? 0 : 1, (CACurrentMediaTime() - t0) * 1000)
            }
        }
        guard let img else { NSLog("folio: FALLBACK render failed page=%d", document?.index(for: self) ?? -1); super.draw(with: box, to: context); return }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(img, in: job.frame)
        context.restoreGState()
        DispatchQueue.main.async { [weak self] in if let self { NightRendering.onPageDrawn?(self) } }
        if displaysAnnotations {
            for a in annotations where a.shouldDisplay { a.draw(with: box, in: context) }
        }
    }

    /// Decide from the pixels whether an embedded image is a *picture* (keep as printed) or
    /// *ink on paper* (scanned text, raster diagrams: treat like text and go dark).
    ///   - any real amount of color → picture
    ///   - no color, but photographic mid-tones → picture (B&W photo)
    ///   - no color, mostly paper-white with dark marks and few mid-tones → ink on paper
    static func isPicture(in ctx: CGContext, rect: CGRect) -> Bool {
        guard let base = ctx.data else { return true }
        let bpr = ctx.bytesPerRow, w = ctx.width, h = ctx.height
        let x0 = max(0, Int(rect.minX)), x1 = min(w, Int(rect.maxX))
        let y0 = max(0, Int(CGFloat(h) - rect.maxY)), y1 = min(h, Int(CGFloat(h) - rect.minY))   // bitmap rows are top-down
        guard x1 > x0 + 2, y1 > y0 + 2 else { return true }
        let step = max(1, Int(sqrt(Double((x1 - x0) * (y1 - y0)) / 20000)))   // ~20k samples
        var n = 0, colorful = 0, white = 0, dark = 0, mid = 0
        let p = base.assumingMemoryBound(to: UInt8.self)
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                let o = y * bpr + x * 4
                let r = Int(p[o]), g = Int(p[o + 1]), b = Int(p[o + 2])
                let mx = max(r, max(g, b)), mn = min(r, min(g, b))
                let lum = (r * 54 + g * 183 + b * 19) >> 8
                n += 1
                if mx - mn > 28 && mx > 60 { colorful += 1 }
                if lum > 225 { white += 1 } else if lum < 90 { dark += 1 } else { mid += 1 }
                x += step
            }
            y += step
        }
        guard n > 0 else { return true }
        let fc = Double(colorful) / Double(n), fw = Double(white) / Double(n), fm = Double(mid) / Double(n)
        if fc > 0.02 { return true }                 // it has color: a picture
        if fw > 0.5 && fm < 0.22 { return false }    // paper with ink: transmute
        return true                                   // grayscale with real tonal range: a photo
    }

    /// Thread-safe: draws the raw page content with Core Graphics (no PDFKit), applies the night
    /// lookup, then pastes every picture back exactly as printed.
    static func render(_ job: RenderJob) -> CGImage? {
        let frame = job.frame, scale = job.scale
        let w = Int(frame.width * scale), h = Int(frame.height * scale)
        guard w > 0, h > 0 else { return nil }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        func canvas() -> CGContext? {
            CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let plain = canvas() else { return nil }
        plain.setFillColor(CGColor(gray: 1, alpha: 1))
        plain.fill(CGRect(x: 0, y: 0, width: w, height: h))
        plain.scaleBy(x: scale, y: scale)
        plain.translateBy(x: -frame.minX, y: -frame.minY)
        plain.concatenate(job.transform)          // PDF user space → display box at the origin
        plain.interpolationQuality = .high
        plain.setShouldAntialias(true)
        plain.setShouldSmoothFonts(true)
        plain.drawPDFPage(job.pageRef)
        guard let original = plain.makeImage() else { return nil }

        let filter = PageTheme.nightCube.copy() as! CIFilter   // CIFilter isn't thread-safe; use a copy
        filter.setValue(CIImage(cgImage: original), forKey: kCIInputImageKey)
        guard let out = filter.outputImage,
              let night = NightRendering.ciContext.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: cs),
              let final = canvas() else { return nil }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        final.draw(night, in: full)
        // Pictures go back as printed, with pure white nudged to 252 so the view's flash guard
        // (which only traps exact white) never touches a photo highlight.
        var source = original
        if !job.imageRects.isEmpty, let clamp = CIFilter(name: "CIColorClamp") {
            clamp.setValue(CIImage(cgImage: original), forKey: kCIInputImageKey)
            clamp.setValue(CIVector(x: 0.973, y: 0.973, z: 0.973, w: 1), forKey: "inputMaxComponents")
            if let out = clamp.outputImage,
               let clamped = NightRendering.ciContext.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: cs) {
                source = clamped
            }
        }
        for r0 in job.imageRects {
            let r = r0.applying(job.transform)
            let px = CGRect(x: (r.minX - frame.minX) * scale, y: (r.minY - frame.minY) * scale,
                            width: r.width * scale, height: r.height * scale)
                .insetBy(dx: -1, dy: -1).intersection(full)
            guard !px.isEmpty else { continue }
            // Ink-on-paper images (scanned text, raster line charts) transmute like text; pictures stay.
            guard isPicture(in: plain, rect: px) else { continue }
            let crop = CGRect(x: px.minX, y: CGFloat(h) - px.maxY, width: px.width, height: px.height)
            if let piece = source.cropping(to: crop) { final.draw(piece, in: px) }
        }
        return final.makeImage()
    }
}
