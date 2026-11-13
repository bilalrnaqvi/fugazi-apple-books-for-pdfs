import SwiftUI
import PDFKit
import AppKit
import CoreImage
import Observation

enum PageTheme: String, CaseIterable, Identifiable {
    case paper, sepia, gray, dim, night
    var id: String { rawValue }
    var label: String {
        switch self {
        case .paper: "Paper"; case .sepia: "Sepia"; case .gray: "Soft Gray"
        case .dim: "Dim"; case .night: "Night"
        }
    }
    var isDarkStyle: Bool { self == .dim || self == .night }
    static let lightStyles: [PageTheme] = [.paper, .sepia, .gray]
    static let darkStyles: [PageTheme] = [.night, .dim]

    /// Background around the page. Filters below also run over this color.
    func surround(dark: Bool) -> NSColor {
        switch self {
        case .paper: dark ? NSColor(calibratedWhite: 0.11, alpha: 1) : NSColor(calibratedWhite: 0.96, alpha: 1)
        case .sepia: dark ? NSColor(calibratedRed: 0.16, green: 0.14, blue: 0.12, alpha: 1)
                          : NSColor(calibratedRed: 0.95, green: 0.92, blue: 0.85, alpha: 1)
        case .gray: dark ? NSColor(calibratedWhite: 0.20, alpha: 1) : NSColor(calibratedWhite: 0.82, alpha: 1)
        case .dim: NSColor(calibratedWhite: 0.16, alpha: 1)
        case .night: NSColor(calibratedWhite: 0.07, alpha: 1)
        }
    }

    var filters: [CIFilter] {
        switch self {
        case .paper, .gray: return []
        case .sepia:
            let f = CIFilter(name: "CISepiaTone")!
            f.setValue(0.32, forKey: kCIInputIntensityKey)
            return [f]
        case .dim:
            let f = CIFilter(name: "CIExposureAdjust")!
            f.setValue(-0.85, forKey: kCIInputEVKey)
            return [f]
        case .night:
            // Pages render themselves dark (NightPage). This view-level lookup only traps PDFKit's
            // pure-white page placeholder (the one-frame flash on page turns) and maps it to paper.
            return [PageTheme.flashGuard]
        }
    }

    /// Identity lookup except the single pure-white corner, which becomes night paper.
    static let flashGuard: CIFilter = {
        let n = 64
        var data = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for bi in 0..<n { for gi in 0..<n { for ri in 0..<n {
            let corner = ri == n - 1 && gi == n - 1 && bi == n - 1
            data[i] = corner ? 0.022 : Float(ri) / Float(n - 1)
            data[i + 1] = corner ? 0.022 : Float(gi) / Float(n - 1)
            data[i + 2] = corner ? 0.022 : Float(bi) / Float(n - 1)
            data[i + 3] = 1
            i += 4
        }}}
        let f = CIFilter(name: "CIColorCube")!
        f.setValue(n, forKey: "inputCubeDimension")
        f.setValue(data.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: "inputCubeData")
        return f
    }()

    /// Smart invert as a 3D color lookup: colorless pixels (paper, ink, rules) have their brightness
    /// flipped; colorful pixels (figures, photos, highlights) keep their look. Blended by chroma so
    /// the transition is smooth.
    static let nightCube: CIFilter = {
        let n = 33
        var data = [Float](repeating: 0, count: n * n * n * 4)
        func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t)
        }
        var i = 0
        for bi in 0..<n { for gi in 0..<n { for ri in 0..<n {
            let r: Float = Float(ri) / Float(n - 1)
            let g: Float = Float(gi) / Float(n - 1)
            let b: Float = Float(bi) / Float(n - 1)
            let lum: Float = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let chroma: Float = max(r, max(g, b)) - min(r, min(g, b))
            let inv: Float = 0.022 + (1 - lum) * 0.72   // linear light: paper → ~#262626, ink → ~#e2e2e2
            // Only genuinely colorless pixels flip (paper, ink, gray rules, anti-aliased edges).
            // Anything with real color is left exactly as printed — no toning, no blending.
            var w: Float = smooth(0.025, 0.09, chroma)  // 0 = colorless, 1 = colored
            // Whitish tints are almost always colored ink anti-aliased against the paper (text edges):
            // treat them like paper so colored headings don't get a pale halo on the dark page.
            let minc: Float = min(r, min(g, b))
            w *= 1 - smooth(0.45, 0.85, minc)
            let base: Float = inv * (1 - w)
            data[i] = base + r * w
            data[i + 1] = base + g * w
            data[i + 2] = base + b * w
            data[i + 3] = 1
            i += 4
        }}}
        let f = CIFilter(name: "CIColorCube")!
        f.setValue(n, forKey: "inputCubeDimension")
        f.setValue(data.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: "inputCubeData")
        return f
    }()
}

/// Menu-bar commands routed to whichever reader window is key.
enum ReaderCommand {
    case previousPage, nextPage, goToPage, find, contents, notes, bookmarks, toggleSidebar
    case zoomIn, zoomOut, zoomFit, toggleBookmark
    static let name = Notification.Name("folioReaderCommand")
    static func post(_ c: ReaderCommand) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: ["cmd": c])
    }
}

enum HoverZone { case none, left, right, bottom }

struct HighlightMenuState: Identifiable {
    let id = UUID()
    var anchor: CGRect              // top-left-origin coords matching the SwiftUI overlay
    var selection: PDFSelection?    // new highlight from this selection…
    var existing: Highlight?        // …or editing this one
    var editNote = false            // open straight into the note editor (margin notes)
}

extension Highlight {
    /// One highlight per page covered by the selection, with a rect per text line.
    static func make(from sel: PDFSelection, in doc: PDFDocument, color: HighlightColor, note: String) -> [Highlight] {
        let lines = sel.selectionsByLine()
        let text = (sel.string ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
        var out: [Highlight] = []
        for page in sel.pages {
            let rects = lines.compactMap { l -> CGRect? in
                guard l.pages.contains(page) else { return nil }
                let r = l.bounds(for: page)
                return r.isEmpty ? nil : r
            }
            guard !rects.isEmpty else { continue }
            out.append(Highlight(id: UUID(), page: doc.index(for: page), rects: rects,
                                 color: color, text: text, note: note, createdAt: Date()))
        }
        return out
    }
}

@Observable
final class ReaderController {
    @ObservationIgnored weak var pdfView: PDFView?
    var currentPage = 0
    var pageCount = 0
    var hoverZone: HoverZone = .none
    /// Whether the floating top bar (and window buttons) are showing.
    var chromeVisible = true
    /// Set when the user wants to jump to a highlight so the view can flash-select it.
    var pendingHighlight: Highlight?
    /// In-window highlight bubble (Books-style), positioned in the PDF view's SwiftUI coordinates.
    var menu: HighlightMenuState?

    /// A margin note just drawn; removed again if the editor closes with nothing written.
    var pendingNewNote: UUID?

    func dismissMenu() {
        menu = nil
        pdfView?.clearSelection()
    }

    func go(to index: Int) {
        guard let v = pdfView, let doc = v.document, index >= 0, index < doc.pageCount,
              let p = doc.page(at: index) else { return }
        v.go(to: p)
    }
    func go(to selection: PDFSelection) {
        guard let v = pdfView else { return }
        v.setCurrentSelection(selection, animate: false)
        v.go(to: selection)
        v.setCurrentSelection(selection, animate: true)
    }
    func go(to h: Highlight) {
        guard let v = pdfView, let doc = v.document, let page = doc.page(at: h.page) else { return }
        v.go(to: PDFDestination(page: page, at: NSPoint(x: h.bounds.minX, y: h.bounds.maxY + 40)))
        if let sel = page.selection(for: h.bounds) { v.setCurrentSelection(sel, animate: true) }
    }
    func next() { pdfView?.goToNextPage(nil) }
    func previous() { pdfView?.goToPreviousPage(nil) }

    // MARK: Smooth zoom (⌘+ / ⌘− / ⌘0, like Books)

    @ObservationIgnored private var zoomTimer: Timer?
    var isZoomed = false

    func zoomIn() { zoom(by: 1.25) }
    func zoomOut() { zoom(by: 1 / 1.25) }

    private func zoom(by factor: CGFloat) {
        guard let v = pdfView else { return }
        let fit = v.scaleFactorForSizeToFit
        let floor = fit > 0 ? fit * 0.5 : 0.25
        let target = min(max(v.scaleFactor * factor, floor), max(fit, 1) * 6)
        // Snap back to "fit" when we land within a hair of it, so ⌘0 and ⌘− agree.
        if fit > 0, abs(target - fit) < fit * 0.03 { self.fit(); return }
        animateScale(to: target) { [weak self] in self?.isZoomed = true }
    }

    func fit() {
        guard let v = pdfView else { return }
        animateScale(to: v.scaleFactorForSizeToFit) { [weak self, weak v] in
            v?.autoScales = true
            self?.isZoomed = false
        }
    }

    private func animateScale(to target: CGFloat, completion: @escaping @MainActor () -> Void) {
        guard let v = pdfView, target > 0 else { return }
        zoomTimer?.invalidate()
        v.autoScales = false
        let start = v.scaleFactor
        let duration = 0.2
        let t0 = CACurrentMediaTime()
        zoomTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self, weak v] t in
            MainActor.assumeIsolated {
                guard let v else { t.invalidate(); return }
                let p = min(1, (CACurrentMediaTime() - t0) / duration)
                let eased = 1 - pow(1 - p, 3)
                v.scaleFactor = start + (target - start) * eased
                if p >= 1 {
                    t.invalidate()
                    self?.zoomTimer = nil
                    completion()
                }
            }
        }
    }
}

// MARK: - Margin brace annotation (drawn by hand, hit-tested by bounds)

final class BraceAnnotation: PDFAnnotation {
    private let lineRects: [CGRect]
    private let onLeft: Bool
    var ink = NSColor(calibratedWhite: 0.12, alpha: 0.9)

    init(rects: [CGRect], onLeft: Bool) {
        lineRects = rects
        self.onLeft = onLeft
        let b = rects.reduce(CGRect.null) { $0.union($1) }
        let spine = onLeft ? b.minX - 20 : b.maxX + 20
        super.init(bounds: CGRect(x: spine - 10, y: b.minY - 3, width: 20, height: b.height + 6),
                   forType: .ink, withProperties: nil)
        shouldDisplay = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let b = bounds
        let x = b.midX
        let top = b.maxY - 2, bottom = b.minY + 2, mid = b.midY
        let out: CGFloat = onLeft ? -6 : 6      // cusp points away from the text
        let hook: CGFloat = onLeft ? 5 : -5     // hooks curl toward the text
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x + hook, y: top))
        path.addQuadCurve(to: CGPoint(x: x, y: top - 7), control: CGPoint(x: x, y: top))
        path.addLine(to: CGPoint(x: x, y: mid + 7))
        path.addQuadCurve(to: CGPoint(x: x + out, y: mid), control: CGPoint(x: x, y: mid))
        path.addQuadCurve(to: CGPoint(x: x, y: mid - 7), control: CGPoint(x: x, y: mid))
        path.addLine(to: CGPoint(x: x, y: bottom + 7))
        path.addQuadCurve(to: CGPoint(x: x + hook, y: bottom), control: CGPoint(x: x, y: bottom))
        context.saveGState()
        page?.transform(context, for: box)   // custom annotations map page space themselves
        // Dark ink on paper; light ink on Night's charcoal paper (keep the draft's translucency).
        let color = NightRendering.enabled
            ? NSColor(calibratedWhite: 0.90, alpha: ink.alphaComponent) : ink
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(2.1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }
}

// MARK: - Margin note card (writing in the margin)

final class MarginNoteAnnotation: PDFAnnotation {
    private let text: String
    private let tint: NSColor
    private let isDraft: Bool

    init(box: CGRect, text: String, tint: NSColor, draft: Bool = false) {
        self.text = text
        self.tint = tint
        self.isDraft = draft
        super.init(bounds: box, forType: .freeText, withProperties: nil)
        shouldDisplay = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let night = NightRendering.enabled
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
        context.saveGState()
        page?.transform(context, for: box)   // custom annotations map page space themselves
        if isDraft {
            context.setStrokeColor((night ? NSColor(white: 0.85, alpha: 0.8) : NSColor(white: 0.25, alpha: 0.7)).cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.addPath(path); context.strokePath()
            context.restoreGState()
            return
        }
        // Card: a pale wash of the note color on paper; a dark card with a colored edge at night.
        let t = tint.usingColorSpace(.sRGB) ?? tint
        let fill = night
            ? NSColor(srgbRed: 0.17 + t.redComponent * 0.06, green: 0.17 + t.greenComponent * 0.06,
                      blue: 0.17 + t.blueComponent * 0.06, alpha: 0.96)
            : NSColor(srgbRed: 1 - (1 - t.redComponent) * 0.22, green: 1 - (1 - t.greenComponent) * 0.22,
                      blue: 1 - (1 - t.blueComponent) * 0.22, alpha: 0.96)
        context.setShadow(offset: CGSize(width: 0, height: -0.6), blur: 1.8, color: NSColor(white: 0, alpha: night ? 0.5 : 0.18).cgColor)
        context.setFillColor(fill.cgColor)
        context.addPath(path); context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(t.withAlphaComponent(night ? 0.55 : 0.45).cgColor)
        context.setLineWidth(0.8)
        context.addPath(path); context.strokePath()

        // Handwriting-style text, shrunk to fit the card.
        let inner = r.insetBy(dx: 4, dy: 3)
        let ink = night ? NSColor(white: 0.90, alpha: 1) : NSColor(white: 0.16, alpha: 1)
        let body = text.isEmpty ? "…" : text
        var size: CGFloat = 11
        var attr = NSAttributedString()
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byWordWrapping
        while true {
            let font = NSFont(name: "Noteworthy-Light", size: size) ?? NSFont.systemFont(ofSize: size)
            attr = NSAttributedString(string: body, attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: para])
            let need = attr.boundingRect(with: NSSize(width: inner.width, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            if need <= inner.height || size <= 5.5 { break }
            size -= 0.5
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.clip(to: inner)
        attr.draw(with: inner, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }
}

extension PDFPage {
    /// Lines a margin note at `box` belongs to: those beside it, or else the nearest line.
    func linesBeside(_ box: CGRect) -> (rects: [CGRect], text: String) {
        let beside = lines(betweenY: box.minY, and: box.maxY)
        if !beside.rects.isEmpty { return beside }
        let near = lines(betweenY: box.minY - 60, and: box.maxY + 60)
        guard let best = near.rects.min(by: { abs($0.midY - box.midY) < abs($1.midY - box.midY) }) else { return ([], "") }
        return lines(betweenY: best.minY + 1, and: best.maxY - 1)
    }

    /// Text-line rects (page space) between two y values, plus the text they contain.
    func lines(betweenY a: CGFloat, and b: CGFloat) -> (rects: [CGRect], text: String) {
        let pb = bounds(for: .cropBox)
        let r = CGRect(x: pb.minX, y: min(a, b), width: pb.width, height: abs(a - b))
        guard let sel = selection(for: r) else { return ([], "") }
        let rects = sel.selectionsByLine().map { $0.bounds(for: self) }.filter { !$0.isEmpty }
        let text = (sel.string ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
        return (rects, text)
    }
}

// MARK: - Night turn cover: hides PDFKit's light quick-render during page changes

final class NightCoverView: NSView {
    var tiles: [(CGRect, CGImage?)] = [] { didSet { needsDisplay = true } }
    var paper = NSColor(calibratedWhite: 0.15, alpha: 1)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for (rect, img) in tiles {
            if let img {
                ctx.saveGState(); ctx.interpolationQuality = .high
                ctx.draw(img, in: rect); ctx.restoreGState()
            } else {
                ctx.setFillColor(paper.cgColor); ctx.fill(rect)
            }
        }
    }
}

// MARK: - PDFView subclass: hover tracking, highlight hit-testing, selection end

final class FolioPDFView: PDFView {
    static let annotationPrefix = "folio:"

    var onSelectionEnd: (@MainActor (PDFSelection) -> Void)?
    var onHighlightClick: (@MainActor (UUID, NSRect) -> Void)?
    var onHover: (@MainActor (NSPoint?) -> Void)?
    var onMouseDown: (@MainActor () -> Void)?
    var onBrace: (@MainActor (PDFPage, [CGRect], String, Bool) -> Void)?
    var onMarginNote: (@MainActor (PDFPage, CGRect) -> Void)?
    private var noteStart: (page: PDFPage, point: NSPoint)?
    private var noteDraft: MarginNoteAnnotation?
    private var noteMoved = false
    private var braceStart: (page: PDFPage, y: CGFloat, left: Bool)?
    private var braceDraft: BraceAnnotation?
    var onResize: (@MainActor () -> Void)?
    var onWindow: (@MainActor () -> Void)?

    // Night turn cover
    private lazy var cover: NightCoverView = {
        let c = NightCoverView(frame: bounds)
        c.autoresizingMask = [.width, .height]
        c.isHidden = true
        addSubview(c, positioned: .above, relativeTo: nil)
        return c
    }()
    private var pendingPages = Set<ObjectIdentifier>()
    private var coverTimer: Timer?

    /// Put the dark cover over the visible pages right now (same run-loop turn as the page change),
    /// using prefetched night renders where we have them, and lift it once PDFKit has drawn them dark.
    func coverForNight() {
        guard NightRendering.enabled, let box = Optional(displayBox) else { return }
        var tiles: [(CGRect, CGImage?)] = []
        pendingPages.removeAll()
        for page in visiblePages {
            let r = convert(page.bounds(for: box), from: page)
            let img = (page as? NightPage).flatMap { NightRendering.cachedImage(for: $0, box: box) }
            tiles.append((r, img))
            pendingPages.insert(ObjectIdentifier(page))
        }
        guard !tiles.isEmpty else { return }
        cover.paper = NSColor(cgColor: CGColor(gray: 0.15, alpha: 1)) ?? cover.paper
        cover.tiles = tiles
        cover.isHidden = false
        if ProcessInfo.processInfo.environment["FOLIO_TRACE"] != nil {
            NSLog("folio: COVER shown tiles=%d cached=%d", tiles.count, tiles.filter { $0.1 != nil }.count)
        }
        coverTimer?.invalidate()
        coverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.liftCover() }
        }
    }

    // MARK: Pre-cover: put the dark cover up BEFORE PDFKit scrolls (its light preview is displayed
    // synchronously during the scroll, before any notification reaches us).

    private var lastWheelCover = Date.distantPast

    /// Indices of the pages that will be on screen after navigating to `index` (spread-aware).
    private func spread(containing index: Int) -> [Int] {
        guard let doc = document else { return [] }
        let n = doc.pageCount
        guard index >= 0, index < n else { return [] }
        if displayMode != .twoUp && displayMode != .twoUpContinuous { return [index] }
        if displaysAsBook {
            if index == 0 { return [0] }
            let first = index % 2 == 1 ? index : index - 1
            return [first, first + 1].filter { $0 < n }
        }
        let first = index - index % 2
        return [first, first + 1].filter { $0 < n }
    }

    private func preCover(targetIndex: Int) {
        guard NightRendering.enabled, let doc = document else { return }
        let targets = spread(containing: targetIndex)
        guard !targets.isEmpty else { return }
        let box = displayBox
        // Current page rects are the slots the next spread will occupy (same page size in a book).
        let slots = visiblePages.map { convert($0.bounds(for: box), from: $0) }.sorted { $0.minX < $1.minX }
        guard !slots.isEmpty else { return }
        var tiles: [(CGRect, CGImage?)] = slots.map { ($0, nil) }
        func image(_ i: Int) -> CGImage? {
            (doc.page(at: i) as? NightPage).flatMap { NightRendering.cachedImage(for: $0, box: box) }
        }
        if targets.count == slots.count {
            for (k, i) in targets.enumerated() { tiles[k].1 = image(i) }
        } else if targets.count == 1, slots.count == 2 {
            // Book mode: a lone first page sits on the right, a lone last page on the left.
            let slot = targets[0] == 0 ? 1 : 0
            tiles[slot].1 = image(targets[0])
        } else if let first = targets.first {
            tiles[0].1 = image(first)
        }
        pendingPages = Set(targets.compactMap { doc.page(at: $0).map(ObjectIdentifier.init) })
        cover.tiles = tiles
        cover.isHidden = false
        if ProcessInfo.processInfo.environment["FOLIO_TRACE"] != nil {
            NSLog("folio: PRECOVER target=%d tiles=%d cached=%d", targetIndex, tiles.count, tiles.filter { $0.1 != nil }.count)
        }
        coverTimer?.invalidate()
        coverTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.liftCover() }
        }
    }

    private var visibleRange: (first: Int, last: Int)? {
        guard let doc = document else { return nil }
        let idx = visiblePages.map { doc.index(for: $0) }
        guard let a = idx.min(), let b = idx.max() else { return nil }
        return (a, b)
    }

    override func goToNextPage(_ sender: Any?) {
        if let r = visibleRange { preCover(targetIndex: r.last + 1) }
        super.goToNextPage(sender)
    }
    override func goToPreviousPage(_ sender: Any?) {
        if let r = visibleRange { preCover(targetIndex: r.first - 1) }
        super.goToPreviousPage(sender)
    }
    override func goToFirstPage(_ sender: Any?) { preCover(targetIndex: 0); super.goToFirstPage(sender) }
    override func goToLastPage(_ sender: Any?) {
        if let doc = document { preCover(targetIndex: doc.pageCount - 1) }
        super.goToLastPage(sender)
    }
    override func go(to page: PDFPage) {
        if let doc = document { preCover(targetIndex: doc.index(for: page)) }
        super.go(to: page)
    }
    override func go(to destination: PDFDestination) {
        if let doc = document, let p = destination.page { preCover(targetIndex: doc.index(for: p)) }
        super.go(to: destination)
    }
    override func go(to selection: PDFSelection) {
        if let doc = document, let p = selection.pages.first { preCover(targetIndex: doc.index(for: p)) }
        super.go(to: selection)
    }

    override func scrollWheel(with event: NSEvent) {
        // When the page fits the view, a wheel/trackpad scroll turns the page: cover ahead of it.
        if NightRendering.enabled, displayMode == .twoUp || displayMode == .singlePage,
           abs(scaleFactor - scaleFactorForSizeToFit) < 0.01, abs(event.scrollingDeltaY) > 2,
           Date().timeIntervalSince(lastWheelCover) > 0.35, let r = visibleRange {
            lastWheelCover = Date()
            preCover(targetIndex: event.scrollingDeltaY < 0 ? r.last + 1 : r.first - 1)
        }
        super.scrollWheel(with: event)
    }

    func pageWasDrawn(_ page: PDFPage) {
        if ProcessInfo.processInfo.environment["FOLIO_TRACE"] != nil {
            NSLog("folio: drawn page=%d coverVisible=%d pending=%d", page.document?.index(for: page) ?? -1, cover.isHidden ? 0 : 1, pendingPages.count)
        }
        guard !cover.isHidden else { return }
        pendingPages.remove(ObjectIdentifier(page))
        if pendingPages.isEmpty {
            // Let the freshly drawn tiles reach the screen first, then lift.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.liftCover() }
        }
    }

    private func liftCover() {
        if ProcessInfo.processInfo.environment["FOLIO_TRACE"] != nil, !cover.isHidden { NSLog("folio: COVER lifted") }
        coverTimer?.invalidate()
        cover.isHidden = true
        cover.tiles = []
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onWindow?() }
    }
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHover?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        let p = convert(event.locationInWindow, from: nil)
        // ⌘-drag draws a margin note card.
        if event.modifierFlags.contains(.command), !event.modifierFlags.contains(.option),
           let page = page(for: p, nearest: true) {
            noteStart = (page, convert(p, to: page))
            noteMoved = false
            clearSelection()
            return
        }
        // ⌥-drag in a margin draws a brace spanning the lines you drag past.
        if event.modifierFlags.contains(.option), let page = page(for: p, nearest: true) {
            let pp = convert(p, to: page)
            braceStart = (page, pp.y, pp.x < page.bounds(for: .cropBox).midX)
            clearSelection()
            return
        }
        if event.clickCount == 1, let page = page(for: p, nearest: false) {
            let pp = convert(p, to: page)
            if let a = page.annotation(at: pp), let name = a.userName,
               name.hasPrefix(Self.annotationPrefix),
               let id = UUID(uuidString: String(name.dropFirst(Self.annotationPrefix.count))) {
                clearSelection()
                onHighlightClick?(id, convert(a.bounds, from: page))
                return
            }
        }
        // PDFView runs its own tracking loop for selection drags, so this returns after mouse-up.
        super.mouseDown(with: event)
        reportSelection()
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = noteStart {
            let q = convert(convert(event.locationInWindow, from: nil), to: start.page)
            if !noteMoved, hypot(q.x - start.point.x, q.y - start.point.y) > 4 { noteMoved = true }
            guard noteMoved else { return }
            if let d = noteDraft { start.page.removeAnnotation(d) }
            let d = MarginNoteAnnotation(box: Self.box(start.point, q, on: start.page), text: "", tint: .systemYellow, draft: true)
            start.page.addAnnotation(d)
            noteDraft = d
            needsDisplay = true
            return
        }
        guard let start = braceStart else { super.mouseDragged(with: event); return }
        let pp = convert(convert(event.locationInWindow, from: nil), to: start.page)
        if let d = braceDraft { start.page.removeAnnotation(d); braceDraft = nil }
        let found = start.page.lines(betweenY: start.y, and: pp.y)
        let rects = found.rects.isEmpty ? [fallbackRect(start, pp.y)] : found.rects
        let d = BraceAnnotation(rects: rects, onLeft: start.left)
        d.ink = NSColor(calibratedWhite: 0.12, alpha: 0.45)
        start.page.addAnnotation(d)
        braceDraft = d
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let start = noteStart {
            noteStart = nil
            if let d = noteDraft { start.page.removeAnnotation(d); noteDraft = nil; needsDisplay = true }
            guard noteMoved else { return }   // a plain ⌘-click does nothing
            var r = Self.box(start.point, convert(convert(event.locationInWindow, from: nil), to: start.page), on: start.page)
            if r.width < 40 { r.size.width = 110 }
            if r.height < 18 { r.size.height = 44; r.origin.y -= 44 - 18 }
            onMarginNote?(start.page, r)
            return
        }
        if let start = braceStart {
            braceStart = nil
            if let d = braceDraft { start.page.removeAnnotation(d); braceDraft = nil }
            let pp = convert(convert(event.locationInWindow, from: nil), to: start.page)
            let found = start.page.lines(betweenY: start.y, and: pp.y)
            if !found.rects.isEmpty, abs(pp.y - start.y) > 4 {
                onBrace?(start.page, found.rects, found.text, start.left)
            }
            needsDisplay = true
            return
        }
        super.mouseUp(with: event)
        reportSelection()
    }

    // MARK: ⌘-drag: draw a margin note card.

    private static func box(_ a: NSPoint, _ b: NSPoint, on page: PDFPage) -> CGRect {
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        return r.intersection(page.bounds(for: .cropBox))
    }

    /// When the drag spans no text (image, blank area), brace a strip beside the drag instead.
    private func fallbackRect(_ start: (page: PDFPage, y: CGFloat, left: Bool), _ y: CGFloat) -> CGRect {
        let pb = start.page.bounds(for: .cropBox)
        let x = start.left ? pb.minX + pb.width * 0.12 : pb.minX + pb.width * 0.12
        return CGRect(x: x, y: min(start.y, y), width: pb.width * 0.76, height: abs(start.y - y))
    }

    private func reportSelection() {
        if NSEvent.pressedMouseButtons != 0 { return }
        if let s = currentSelection, let t = s.string,
           !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onSelectionEnd?(s)
        }
    }

    /// Replace all Folio annotations in the document with the given highlights.
    static func sync(_ highlights: [Highlight], into doc: PDFDocument) {
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for a in page.annotations where a.userName?.hasPrefix(annotationPrefix) == true {
                page.removeAnnotation(a)
            }
        }
        for h in highlights {
            guard let page = doc.page(at: h.page), !h.rects.isEmpty else { continue }
            if h.kind == .marginNote {
                let a = MarginNoteAnnotation(box: h.box ?? h.bounds, text: h.note, tint: h.color.nsColor)
                a.userName = annotationPrefix + h.id.uuidString
                a.contents = h.note
                page.addAnnotation(a)
                continue
            }
            if h.kind == .brace {
                let a = BraceAnnotation(rects: h.rects, onLeft: h.braceOnLeft)
                a.userName = annotationPrefix + h.id.uuidString
                a.contents = h.note
                page.addAnnotation(a)
                continue
            }
            let b = h.bounds
            let type: PDFAnnotationSubtype = h.color == .underline ? .underline : .highlight
            let a = PDFAnnotation(bounds: b, forType: type, withProperties: nil)
            a.color = h.color.nsColor
            a.userName = annotationPrefix + h.id.uuidString
            a.contents = h.note
            // Quad points are relative to the annotation's bounds origin: UL, UR, LL, LR per line.
            a.quadrilateralPoints = h.rects.flatMap { r -> [NSValue] in
                [NSValue(point: NSPoint(x: r.minX - b.minX, y: r.maxY - b.minY)),
                 NSValue(point: NSPoint(x: r.maxX - b.minX, y: r.maxY - b.minY)),
                 NSValue(point: NSPoint(x: r.minX - b.minX, y: r.minY - b.minY)),
                 NSValue(point: NSPoint(x: r.maxX - b.minX, y: r.minY - b.minY))]
            }
            page.addAnnotation(a)
        }
    }
}

// MARK: - SwiftUI wrapper

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    let controller: ReaderController
    let bookID: UUID
    let theme: PageTheme
    let dark: Bool
    let startPage: Int
    let highlights: [Highlight]
    let onPageChange: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PDFView {
        let v = FolioPDFView()
        v.appearance = NSAppearance(named: .aqua)
        v.document = document
        v.displaysPageBreaks = true
        v.pageShadowsEnabled = true
        // Books-style: the page owns the canvas; only a sliver of surround.
        v.pageBreakMargins = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        v.wantsLayer = true
        v.layerUsesCoreImageFilters = true
        apply(to: v, force: true)
        Self.applyLayout(to: v, force: true)
        v.autoScales = true
        controller.pdfView = v
        controller.pageCount = document.pageCount
        context.coordinator.attach(v)
        context.coordinator.syncHighlights(highlights, force: true)
        context.coordinator.restore(to: startPage, attempt: 0)
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        context.coordinator.parent = self
        apply(to: v, force: false)
        context.coordinator.syncHighlights(highlights, force: false)
        if let h = controller.pendingHighlight {
            controller.pendingHighlight = nil
            DispatchQueue.main.async { controller.go(to: h) }
        }
    }

    static func dismantleNSView(_ v: PDFView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Books-style: a two-page spread when the window is wide enough, otherwise one page.
    static func applyLayout(to v: PDFView, force: Bool) {
        let b = v.bounds
        guard b.width > 0, b.height > 0 else { return }
        // A spread of two portrait pages needs roughly 1.3× the height in width to be legible.
        let wantsSpread = b.width >= b.height * 1.3
        let dm: PDFDisplayMode = wantsSpread ? .twoUp : .singlePage
        if force || v.displayMode != dm {
            let page = v.currentPage
            v.displayMode = dm
            v.displaysAsBook = wantsSpread
            v.displayDirection = .vertical
            v.autoScales = true
            if !force, let page { DispatchQueue.main.async { v.go(to: page) } }
        }
    }

    private func apply(to v: PDFView, force: Bool) {
        let surround = theme.surround(dark: dark)
        if force || v.backgroundColor != surround {
            v.backgroundColor = surround
            v.contentFilters = theme.filters
        }
        let night = theme == .night
        if NightRendering.enabled != night {
            NightRendering.enabled = night
            // Flip the display box and back: PDFView throws away its cached page renders.
            let box = v.displayBox
            v.displayBox = box == .cropBox ? .mediaBox : .cropBox
            v.displayBox = box
            v.layoutDocumentView()
            v.documentView?.needsDisplay = true
            if night, let doc = v.document, let p = v.currentPage {
                (v as? FolioPDFView)?.coverForNight()
                NightRendering.prefetch(doc, around: doc.index(for: p))
            }
        }
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject {
        var parent: PDFKitView
        weak var view: FolioPDFView?
        private var monitor: Any?
        private var restored = false
        private var highlightSig = 0
        private var lastZone: HoverZone = .none
        private var lastMenuAnchor = CGRect.null

        init(_ parent: PDFKitView) { self.parent = parent }

        func attach(_ v: FolioPDFView) {
            view = v
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)),
                                                   name: .PDFViewPageChanged, object: v)
            v.onHover = { [weak self] p in self?.hover(p) }
            NightRendering.onPageDrawn = { [weak v] page in v?.pageWasDrawn(page) }
            v.onMouseDown = { [weak self] in self?.parent.controller.menu = nil }
            v.onResize = { [weak self] in self?.viewResized() }
            v.onWindow = { [weak self] in self?.configureWindow() }
            moveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] e in
                MainActor.assumeIsolated { self?.mouseActivity(e) }
                return e
            }
            v.onSelectionEnd = { [weak self] s in self?.showMenu(for: s) }
            v.onBrace = { [weak self] page, rects, text, left in
                guard let self, let doc = self.view?.document else { return }
                let h = Highlight(id: UUID(), page: doc.index(for: page), rects: rects, color: .yellow,
                                  text: text, note: "", createdAt: Date(), kind: .brace, braceOnLeft: left)
                LibraryStore.shared.addHighlights(self.parent.bookID, [h])
            }
            v.onHighlightClick = { [weak self] id, r in self?.showMenu(forExisting: id, at: r) }
            v.onMarginNote = { [weak self] page, box in
                guard let self, let v = self.view, let doc = v.document else { return }
                let linked = page.linesBeside(box)
                let h = Highlight(id: UUID(), page: doc.index(for: page),
                                  rects: linked.rects.isEmpty ? [box] : linked.rects, color: .yellow,
                                  text: linked.text, note: "", createdAt: Date(), kind: .marginNote, box: box)
                LibraryStore.shared.addHighlights(self.parent.bookID, [h])
                self.parent.controller.pendingNewNote = h.id
                self.showMenu(forExisting: h.id, at: v.convert(box, from: page), edit: true)
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                MainActor.assumeIsolated { self?.handleKey(e) == true ? nil : e }
            }
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
            moveMonitor = nil
            chromeTimer?.invalidate()
            readingTimer?.invalidate()
        }

        // MARK: Auto-hiding toolbar (Books-style)

        private var moveMonitor: Any?
        private var chromeTimer: Timer?
        private var chromeHidden = false

        private var titlebar: NSView? {
            view?.window?.standardWindowButton(.closeButton)?.superview?.superview
        }

        private func configureWindow() {
            guard let w = view?.window else { return }
            // No native title bar or toolbar: the page owns the whole window, our bar floats over it.
            w.styleMask.insert(.fullSizeContentView)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.toolbar = nil
            w.acceptsMouseMovedEvents = true
            scheduleChromeHide()
            startReadingTimer()
        }

        private var lastActivity = Date()
        private var readingTimer: Timer?
        private let tick: Double = 10

        /// Every 10 s, credit reading time if the reader is frontmost and was touched in the last 2 min.
        private func startReadingTimer() {
            readingTimer?.invalidate()
            readingTimer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let w = self.view?.window, w.isKeyWindow, NSApp.isActive,
                          Date().timeIntervalSince(self.lastActivity) < 120 else { return }
                    LibraryStore.shared.addReadingTime(self.parent.bookID, seconds: self.tick)
                }
            }
        }

        private func mouseActivity(_ e: NSEvent) {
            guard let w = view?.window, e.window === w else { return }
            lastActivity = Date()
            setChrome(hidden: false)
            let overTitlebar = e.locationInWindow.y > (w.contentView?.bounds.height ?? 0) - 60
            if overTitlebar || parent.controller.menu != nil {
                chromeTimer?.invalidate()
            } else {
                scheduleChromeHide()
            }
        }

        private func scheduleChromeHide() {
            chromeTimer?.invalidate()
            chromeTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.setChrome(hidden: true) }
            }
        }

        private func setChrome(hidden: Bool) {
            guard chromeHidden != hidden else { return }
            chromeHidden = hidden
            parent.controller.chromeVisible = !hidden
            if let tb = titlebar {   // traffic lights (windowed mode)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = hidden ? 0.25 : 0.12
                    tb.animator().alphaValue = hidden ? 0 : 1
                }
            }
            if hidden {
                lastZone = .none
                parent.controller.hoverZone = .none
            }
        }

        private var restoreTarget = 0
        private var restoreAttempts = 0

        /// Jump to the saved page once PDFView has a real size; page changes are ignored until then
        /// so a layout pass can never overwrite the saved position. Retried on timer and on resize.
        func restore(to start: Int, attempt: Int) {
            restoreTarget = start
            restoreAttempts = attempt
            DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.05 : 0.15)) { [weak self] in
                self?.tryRestore(fromTimer: true)
            }
        }

        private func tryRestore(fromTimer: Bool) {
            guard !restored, let v = view, let doc = v.document else { return }
            let start = restoreTarget
            guard v.bounds.width > 50, v.bounds.height > 50, let p = doc.page(at: start) else {
                if fromTimer { scheduleRetry() }
                return
            }
            v.go(to: p)
            let now = v.currentPage.map { doc.index(for: $0) } ?? -1
            let ok = now == start || (v.displaysAsBook && abs(now - start) <= 1)
            if ok || restoreAttempts >= 60 {           // ~9 s before giving up
                restored = true
                parent.controller.currentPage = now >= 0 ? now : start
                v.window?.makeFirstResponder(v)
                NightRendering.prefetch(doc, around: max(0, now))
            } else if fromTimer {
                scheduleRetry()
            }
        }

        private func scheduleRetry() {
            restoreAttempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.tryRestore(fromTimer: true) }
        }

        func viewResized() {
            guard let v = view else { return }
            if restored {
                PDFKitView.applyLayout(to: v, force: false)
            } else {
                PDFKitView.applyLayout(to: v, force: true)   // no go(to:) here; restore does the jump
                tryRestore(fromTimer: false)
            }
        }

        @objc private func pageChanged(_ n: Notification) {
            guard restored, let v = view, let doc = v.document, let page = v.currentPage else { return }
            let idx = doc.index(for: page)
            parent.controller.currentPage = idx
            parent.controller.menu = nil
            lastActivity = Date()
            parent.onPageChange(idx)
            v.coverForNight()
            NightRendering.prefetch(doc, around: idx)
        }

        // MARK: Hover zones (edge arrows + bottom scrubber)

        private func hover(_ p: NSPoint?) {
            guard let v = view else { return }
            var zone: HoverZone = .none
            if let p, parent.controller.menu == nil {
                let w = v.bounds.width
                if p.y < 96 { zone = .bottom }               // PDFView is not flipped: y=0 is the bottom
                else if p.x < 110 { zone = .left }
                else if p.x > w - 110 { zone = .right }
            }
            if zone != lastZone {
                lastZone = zone
                parent.controller.hoverZone = zone
            }
        }

        // MARK: Highlights

        func syncHighlights(_ hs: [Highlight], force: Bool) {
            var hasher = Hasher()
            for h in hs { hasher.combine(h.id); hasher.combine(h.color); hasher.combine(h.note) }
            let sig = hasher.finalize()
            guard force || sig != highlightSig else { return }
            highlightSig = sig
            FolioPDFView.sync(hs, into: parent.document)
            view?.needsDisplay = true
        }

        /// Flip a PDFView (bottom-left origin) rect into SwiftUI's top-left origin space.
        private func flipped(_ r: NSRect) -> CGRect {
            guard let v = view else { return r }
            return CGRect(x: r.minX, y: v.bounds.height - r.maxY, width: r.width, height: r.height)
        }

        private func showMenu(for sel: PDFSelection) {
            guard let v = view, let page = sel.pages.last else { return }
            // Anchor on the last line so the bubble sits just under the end of the selection.
            let lineRect = sel.selectionsByLine().last.map { $0.bounds(for: page) } ?? sel.bounds(for: page)
            let anchor = flipped(v.convert(lineRect, from: page))
            if parent.controller.menu != nil, anchor == lastMenuAnchor { return }
            lastMenuAnchor = anchor
            parent.controller.menu = HighlightMenuState(anchor: anchor, selection: sel, existing: nil)
        }

        private func showMenu(forExisting id: UUID, at rect: NSRect, edit: Bool = false) {
            guard let h = LibraryStore.shared.book(parent.bookID)?.highlights.first(where: { $0.id == id }) else { return }
            let anchor = flipped(rect)
            lastMenuAnchor = anchor
            parent.controller.menu = HighlightMenuState(anchor: anchor, selection: nil, existing: h,
                                                        editNote: edit || h.kind == .marginNote)
        }

        // MARK: Keys

        /// Arrow keys / space turn pages like a book (unless the user is typing in a text field).
        private func handleKey(_ e: NSEvent) -> Bool {
            guard let v = view, let win = v.window, e.window === win else { return false }
            if win.firstResponder is NSText { return false }
            if e.keyCode == 53, parent.controller.menu != nil {                 // esc closes the bubble
                parent.controller.dismissMenu(); return true
            }
            let mods = e.modifierFlags.intersection([.command, .option, .control])
            if mods == .command, let ch = e.charactersIgnoringModifiers {
                switch ch {
                case "=", "+": parent.controller.zoomIn(); return true
                case "-", "_": parent.controller.zoomOut(); return true
                case "0": parent.controller.fit(); return true
                default: break
                }
            }
            if !mods.isEmpty { return false }
            switch e.keyCode {
            case 123: v.goToPreviousPage(nil); return true                 // ←
            case 124: v.goToNextPage(nil); return true                     // →
            case 49:                                                        // space
                e.modifierFlags.contains(.shift) ? v.goToPreviousPage(nil) : v.goToNextPage(nil)
                return true
            case 115: v.goToFirstPage(nil); return true                    // home
            case 119: v.goToLastPage(nil); return true                     // end
            default: return false
            }
        }
    }
}

// MARK: - Highlight popover content

struct HighlightMenuView: View {
    let current: HighlightColor?
    let initialNote: String
    let isExisting: Bool
    var isMarginNote = false
    var startEditing = false
    let onColor: (HighlightColor) -> Void
    let onSaveNote: (String) -> Void
    let onCopy: () -> Void
    let onDelete: (() -> Void)?

    @State private var showNote = false
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    private let swatches: [HighlightColor] = [.yellow, .green, .blue, .pink, .purple]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ForEach(swatches) { c in
                    Button { onColor(c) } label: {
                        Circle()
                            .fill(Color(nsColor: c.nsColor))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(.black.opacity(0.15)))
                            .overlay {
                                if current == c { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.black.opacity(0.7)) }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(c.label)
                }
                if !isMarginNote {
                    Button { onColor(.underline) } label: {
                        Image(systemName: "underline")
                            .font(.body.weight(.semibold))
                            .frame(width: 22, height: 22)
                            .foregroundStyle(current == .underline ? Color.red : .primary)
                    }
                    .buttonStyle(.plain).help("Underline")
                }
                Divider().frame(height: 18)
                iconButton("note.text", help: isExisting ? "Edit Note" : "Add Note") {
                    withAnimation(.easeOut(duration: 0.15)) { showNote.toggle() }
                    noteFocused = showNote
                }
                iconButton("doc.on.doc", help: "Copy", action: onCopy)
                if let onDelete {
                    iconButton("trash", help: isMarginNote ? "Remove Note" : "Remove Highlight", action: onDelete).foregroundStyle(.red)
                }
            }
            if showNote {
                VStack(alignment: .trailing, spacing: 6) {
                    TextEditor(text: $note)
                        .font(.body)
                        .frame(width: 280, height: 90)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                        .focused($noteFocused)
                    Button(isMarginNote ? "Done" : isExisting ? "Save Note" : "Highlight & Save Note") { onSaveNote(note) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear {
            note = initialNote
            if startEditing || (isExisting && !initialNote.isEmpty) { showNote = true }
            if startEditing { DispatchQueue.main.async { noteFocused = true } }
        }
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.body).frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
