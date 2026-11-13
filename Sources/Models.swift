import Foundation
import AppKit
import PDFKit
import Observation

struct Book: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var author: String
    var fileName: String          // stored copy inside the library folder
    var originalName: String
    var fileSize: Int64
    var addedAt: Date
    var lastOpened: Date?
    var lastPage: Int             // 0-based
    var pageCount: Int
    var finished: Bool
    var collectionIDs: Set<UUID>
    var bookmarks: [Int]
    var highlights: [Highlight] = []
    var readingSeconds: Double = 0   // attentive time in the reader (window frontmost + recent activity)
    var pagesTurned: Int = 0         // sequential page turns (jumps via contents/search don't count)

    var progress: Double {
        guard pageCount > 1 else { return finished ? 1 : 0 }
        return min(1, Double(lastPage + 1) / Double(pageCount))
    }
    var isStarted: Bool { lastOpened != nil }
    /// "Actually reading" vs. just peeking: enough attentive time, or enough pages turned in sequence.
    var isReading: Bool { !finished && (readingSeconds >= 8 * 60 || pagesTurned >= 12) }

    init(id: UUID, title: String, author: String, fileName: String, originalName: String, fileSize: Int64,
         addedAt: Date, lastOpened: Date?, lastPage: Int, pageCount: Int, finished: Bool,
         collectionIDs: Set<UUID>, bookmarks: [Int], highlights: [Highlight] = []) {
        self.id = id; self.title = title; self.author = author; self.fileName = fileName
        self.originalName = originalName; self.fileSize = fileSize; self.addedAt = addedAt
        self.lastOpened = lastOpened; self.lastPage = lastPage; self.pageCount = pageCount
        self.finished = finished; self.collectionIDs = collectionIDs; self.bookmarks = bookmarks
        self.highlights = highlights
    }

    // Tolerant decoding so older library files (without newer keys) still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        fileName = try c.decode(String.self, forKey: .fileName)
        originalName = try c.decodeIfPresent(String.self, forKey: .originalName) ?? fileName
        fileSize = try c.decodeIfPresent(Int64.self, forKey: .fileSize) ?? 0
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        lastOpened = try c.decodeIfPresent(Date.self, forKey: .lastOpened)
        lastPage = try c.decodeIfPresent(Int.self, forKey: .lastPage) ?? 0
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        collectionIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .collectionIDs) ?? []
        bookmarks = try c.decodeIfPresent([Int].self, forKey: .bookmarks) ?? []
        highlights = try c.decodeIfPresent([Highlight].self, forKey: .highlights) ?? []
        readingSeconds = try c.decodeIfPresent(Double.self, forKey: .readingSeconds) ?? 0
        pagesTurned = try c.decodeIfPresent(Int.self, forKey: .pagesTurned) ?? 0
    }
}

enum HighlightColor: String, Codable, CaseIterable, Identifiable {
    case yellow, green, blue, pink, purple, underline
    var id: String { rawValue }
    var label: String {
        switch self {
        case .yellow: "Yellow"; case .green: "Green"; case .blue: "Blue"
        case .pink: "Pink"; case .purple: "Purple"; case .underline: "Underline"
        }
    }
    var nsColor: NSColor {
        switch self {
        case .yellow: NSColor(calibratedRed: 1.00, green: 0.86, blue: 0.20, alpha: 1)
        case .green: NSColor(calibratedRed: 0.55, green: 0.86, blue: 0.40, alpha: 1)
        case .blue: NSColor(calibratedRed: 0.45, green: 0.72, blue: 1.00, alpha: 1)
        case .pink: NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.70, alpha: 1)
        case .purple: NSColor(calibratedRed: 0.75, green: 0.60, blue: 1.00, alpha: 1)
        case .underline: NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.25, alpha: 1)
        }
    }
}

enum HighlightKind: String, Codable { case fill, brace, marginNote }

struct Highlight: Identifiable, Codable, Hashable {
    var id: UUID
    var page: Int                 // 0-based
    var rects: [CGRect]           // in PDF page space, one per text line
    var color: HighlightColor
    var text: String
    var note: String
    var createdAt: Date
    var kind: HighlightKind = .fill
    var braceOnLeft: Bool = true  // for .brace: which margin it is drawn in
    var box: CGRect? = nil        // for .marginNote: the note card, in PDF page space

    var bounds: CGRect { rects.reduce(CGRect.null) { $0.union($1) } }

    init(id: UUID, page: Int, rects: [CGRect], color: HighlightColor, text: String, note: String,
         createdAt: Date, kind: HighlightKind = .fill, braceOnLeft: Bool = true, box: CGRect? = nil) {
        self.id = id; self.page = page; self.rects = rects; self.color = color; self.text = text
        self.note = note; self.createdAt = createdAt; self.kind = kind; self.braceOnLeft = braceOnLeft
        self.box = box
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        page = try c.decode(Int.self, forKey: .page)
        rects = try c.decode([CGRect].self, forKey: .rects)
        color = try c.decodeIfPresent(HighlightColor.self, forKey: .color) ?? .yellow
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        kind = try c.decodeIfPresent(HighlightKind.self, forKey: .kind) ?? .fill
        braceOnLeft = try c.decodeIfPresent(Bool.self, forKey: .braceOnLeft) ?? true
        box = try c.decodeIfPresent(CGRect.self, forKey: .box)
    }
}

struct BookCollection: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
}

private struct LibraryFile: Codable {
    var books: [Book]
    var collections: [BookCollection]
}

extension Notification.Name {
    static let folioOpenBooks = Notification.Name("folioOpenBooks")
}

@Observable
@MainActor
final class LibraryStore {
    static let shared = LibraryStore()

    var books: [Book] = []
    var collections: [BookCollection] = []

    let rootURL: URL
    let booksURL: URL
    let coversURL: URL
    private var dbURL: URL { rootURL.appendingPathComponent("library.json") }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        rootURL = support.appendingPathComponent("Folio", isDirectory: true)
        booksURL = rootURL.appendingPathComponent("Books", isDirectory: true)
        coversURL = rootURL.appendingPathComponent("Covers", isDirectory: true)
        for dir in [rootURL, booksURL, coversURL] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        load()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: dbURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let file = try? decoder.decode(LibraryFile.self, from: data) {
            books = file.books
            collections = file.collections
        }
        // One-time: books with real progress from before attention tracking existed count as "reading".
        let key = "seededReadingStats"
        if !UserDefaults.standard.bool(forKey: key) {
            for i in books.indices where books[i].readingSeconds == 0 && books[i].pagesTurned == 0 && books[i].lastPage >= 15 {
                books[i].pagesTurned = 12
            }
            UserDefaults.standard.set(true, forKey: key)
            save()
        }
    }

    // MARK: Lookup

    func book(_ id: UUID) -> Book? { books.first { $0.id == id } }
    func fileURL(for book: Book) -> URL { booksURL.appendingPathComponent(book.fileName) }
    func coverURL(for book: Book) -> URL { coversURL.appendingPathComponent(book.id.uuidString + ".png") }

    func update(_ id: UUID, _ change: (inout Book) -> Void) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        change(&books[i])
        save()
    }

    // MARK: Import

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Add to Library"
        panel.message = "Choose PDFs (or folders of PDFs) to add to your library"
        if panel.runModal() == .OK {
            importPDFs(panel.urls)
        }
    }

    @discardableResult
    func importPDFs(_ urls: [URL], into collection: UUID? = nil) -> [UUID] {
        var ids: [UUID] = []
        for url in expand(urls) {
            if let id = importOne(url, into: collection) { ids.append(id) }
        }
        save()
        return ids
    }

    private func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let e = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for case let f as URL in e where f.pathExtension.lowercased() == "pdf" { out.append(f) }
                }
            } else if url.pathExtension.lowercased() == "pdf" {
                out.append(url)
            }
        }
        return out
    }

    private func importOne(_ url: URL, into collection: UUID?) -> UUID? {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let name = url.lastPathComponent
        if let existing = books.first(where: { $0.originalName == name && $0.fileSize == size }) {
            if let c = collection { update(existing.id) { $0.collectionIDs.insert(c) } }
            return existing.id
        }
        guard let doc = PDFDocument(url: url) else { return nil }
        let id = UUID()
        let stored = id.uuidString + ".pdf"
        do {
            try FileManager.default.copyItem(at: url, to: booksURL.appendingPathComponent(stored))
        } catch {
            return nil
        }
        let attrs = doc.documentAttributes ?? [:]
        let metaTitle = (attrs[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let metaAuthor = (attrs[PDFDocumentAttribute.authorAttribute] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fileTitle = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
        let title = Self.looksLikeRealTitle(metaTitle) ? metaTitle : fileTitle

        books.append(Book(
            id: id, title: title, author: metaAuthor, fileName: stored,
            originalName: name, fileSize: size, addedAt: Date(), lastOpened: nil,
            lastPage: 0, pageCount: doc.pageCount, finished: false,
            collectionIDs: collection.map { [$0] } ?? [], bookmarks: []))
        return id
    }

    /// PDF metadata titles are often junk like "Microsoft Word - doc1.docx" or "untitled".
    private static func looksLikeRealTitle(_ s: String) -> Bool {
        let l = s.lowercased()
        if s.count < 2 || s.count > 150 { return false }
        let junk = ["untitled", "microsoft word", ".doc", ".pdf", ".indd", ".qxd", "adobe", "layout 1", "unknown"]
        return !junk.contains { l.contains($0) }
    }

    // MARK: Book actions

    func remove(_ ids: Set<UUID>) {
        for b in books where ids.contains(b.id) {
            try? FileManager.default.removeItem(at: fileURL(for: b))
            try? FileManager.default.removeItem(at: coverURL(for: b))
            Covers.cache.removeObject(forKey: b.id.uuidString as NSString)
        }
        books.removeAll { ids.contains($0.id) }
        save()
    }

    func recordPage(_ id: UUID, page: Int) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        if books[i].lastPage == page, books[i].lastOpened != nil { return }
        let previous = books[i].lastPage
        books[i].lastPage = page
        books[i].lastOpened = Date()
        if page != previous, abs(page - previous) <= 2 { books[i].pagesTurned += 1 }
        // Only auto-finish when the reader actually paged onto the last page (not a stray jump).
        if page >= books[i].pageCount - 1, previous >= books[i].pageCount - 3 { books[i].finished = true }
        save()
    }

    private var unsavedReadingSeconds: Double = 0

    /// Reading time accrues in memory and hits disk about once a minute (and on quit).
    func addReadingTime(_ id: UUID, seconds: Double) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        books[i].readingSeconds += seconds
        unsavedReadingSeconds += seconds
        if unsavedReadingSeconds >= 60 { save() }
    }

    func save() {
        unsavedReadingSeconds = 0
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(LibraryFile(books: books, collections: collections)) {
            try? data.write(to: dbURL, options: .atomic)
        }
    }

    func toggleBookmark(_ id: UUID, page: Int) {
        update(id) { b in
            if let i = b.bookmarks.firstIndex(of: page) { b.bookmarks.remove(at: i) }
            else { b.bookmarks.append(page); b.bookmarks.sort() }
        }
    }

    // MARK: Highlights

    func addHighlights(_ id: UUID, _ hs: [Highlight]) {
        update(id) { $0.highlights.append(contentsOf: hs) }
    }
    func removeHighlight(_ id: UUID, _ hid: UUID) {
        update(id) { $0.highlights.removeAll { $0.id == hid } }
    }
    func updateHighlight(_ id: UUID, _ hid: UUID, _ change: (inout Highlight) -> Void) {
        update(id) { b in
            if let i = b.highlights.firstIndex(where: { $0.id == hid }) { change(&b.highlights[i]) }
        }
    }

    // MARK: Collections

    @discardableResult
    func addCollection(_ name: String) -> UUID {
        let c = BookCollection(id: UUID(), name: name.isEmpty ? "New Collection" : name)
        collections.append(c)
        save()
        return c.id
    }

    func renameCollection(_ id: UUID, to name: String) {
        guard let i = collections.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        collections[i].name = name
        save()
    }

    func deleteCollection(_ id: UUID) {
        collections.removeAll { $0.id == id }
        for i in books.indices { books[i].collectionIDs.remove(id) }
        save()
    }

    func setCollection(_ bookIDs: Set<UUID>, _ collection: UUID, member: Bool) {
        for i in books.indices where bookIDs.contains(books[i].id) {
            if member { books[i].collectionIDs.insert(collection) } else { books[i].collectionIDs.remove(collection) }
        }
        save()
    }
}

// MARK: - Cover thumbnails

enum Covers {
    static let cache = NSCache<NSString, NSImage>()

    @MainActor
    static func image(for book: Book, store: LibraryStore) async -> NSImage? {
        let key = book.id.uuidString as NSString
        if let img = cache.object(forKey: key) { return img }
        let coverURL = store.coverURL(for: book)
        let pdfURL = store.fileURL(for: book)
        let img = await Task.detached(priority: .utility) { () -> NSImage? in
            if let data = try? Data(contentsOf: coverURL), let i = NSImage(data: data) { return i }
            guard let doc = PDFDocument(url: pdfURL), let page = doc.page(at: 0) else { return nil }
            var b = page.bounds(for: .cropBox).size
            if page.rotation % 180 != 0 { b = NSSize(width: b.height, height: b.width) }
            let w: CGFloat = 420
            let h = b.width > 0 ? w * b.height / b.width : w * 1.5
            let thumb = page.thumbnail(of: NSSize(width: w, height: h), for: .cropBox)
            if let tiff = thumb.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: coverURL)
            }
            return thumb
        }.value
        if let img { cache.setObject(img, forKey: key) }
        return img
    }
}
