import SwiftUI
import PDFKit
import AppKit

struct ReaderView: View {
    let bookID: UUID
    @Environment(LibraryStore.self) private var store
    @State private var document: PDFDocument?
    @State private var failed = false
    @State private var controller = ReaderController()
    @State private var sidebarShown = false
    @State private var sidebarTab: SidebarTab = .pages
    @State private var showGoTo = false
    @State private var goToText = ""
    @AppStorage("readerTheme") private var lightTheme: PageTheme = .paper
    @AppStorage("readerThemeDark") private var darkTheme: PageTheme = .night
    @Environment(\.colorScheme) private var colorScheme
    /// The page look follows the app appearance; each appearance remembers its own choice.
    private var theme: Binding<PageTheme> {
        colorScheme == .dark ? $darkTheme : $lightTheme
    }

    var body: some View {
        Group {
            if let book = store.book(bookID), let doc = document {
                reader(book: book, doc: doc)
            } else if failed || store.book(bookID) == nil {
                ContentUnavailableView("Couldn’t open this PDF", systemImage: "exclamationmark.triangle",
                                       description: Text("The file may have been removed or is damaged."))
            } else {
                ProgressView("Opening…")
            }
        }
        .task(id: bookID) { load() }
        .onReceive(NotificationCenter.default.publisher(for: ReaderCommand.name)) { n in
            guard controller.pdfView?.window?.isKeyWindow == true,
                  let cmd = n.userInfo?["cmd"] as? ReaderCommand else { return }
            handle(cmd)
        }
        .alert("Go to Page", isPresented: $showGoTo) {
            TextField("Page number", text: $goToText)
            Button("Go") { goTo(goToText) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a page number from 1 to \(document?.pageCount ?? 0).")
        }
    }

    private func load() {
        guard let book = store.book(bookID) else { failed = true; return }
        if let doc = PDFDocument(url: store.fileURL(for: book)) {
            doc.delegate = NightPageDelegate.shared   // pages render themselves in Night mode
            document = doc
            store.update(bookID) { $0.lastOpened = Date(); $0.pageCount = doc.pageCount }
        } else {
            failed = true
        }
    }

    private func handle(_ cmd: ReaderCommand) {
        func open(_ t: SidebarTab) { sidebarTab = t; withAnimation { sidebarShown = true } }
        switch cmd {
        case .previousPage: controller.previous()
        case .nextPage: controller.next()
        case .goToPage: goToText = ""; showGoTo = true
        case .find: open(.search)
        case .contents: open(.contents)
        case .notes: open(.notes)
        case .bookmarks: open(.bookmarks)
        case .toggleSidebar: withAnimation { sidebarShown.toggle() }
        case .toggleBookmark: store.toggleBookmark(bookID, page: controller.currentPage)
        case .zoomIn: controller.zoomIn()
        case .zoomOut: controller.zoomOut()
        case .zoomFit: controller.fit()
        }
    }

    private func goTo(_ text: String) {
        guard let doc = document else { return }
        let t = text.trimmingCharacters(in: .whitespaces)
        // Prefer the printed page label (e.g. "xii" or "245"), then fall back to the physical index.
        for i in 0..<doc.pageCount where doc.page(at: i)?.label?.caseInsensitiveCompare(t) == .orderedSame {
            controller.go(to: i); return
        }
        if let n = Int(t) { controller.go(to: min(max(n - 1, 0), doc.pageCount - 1)) }
    }

    // MARK: Layout

    @ViewBuilder
    private func reader(book: Book, doc: PDFDocument) -> some View {
        // A plain side panel + full-bleed page. (NavigationSplitView forced the page below the
        // toolbar; here the page owns the whole window and the bar floats over it, like Books.)
        HStack(spacing: 0) {
            if sidebarShown {
                ReaderSidebar(document: doc, controller: controller, bookID: bookID, tab: $sidebarTab)
                    .frame(width: 270)
                    .background(.bar)
                    .safeAreaPadding(.top, 52)       // keep the tab strip clear of the floating toolbar
                    .transition(.move(edge: .leading))
                Divider()
            }
            ZStack {
                PDFKitView(document: doc, controller: controller, bookID: bookID, theme: theme.wrappedValue,
                           dark: colorScheme == .dark,
                           startPage: min(book.lastPage, max(0, doc.pageCount - 1)),
                           highlights: book.highlights) { page in
                    store.recordPage(bookID, page: page)
                }
                edgeArrows(doc: doc)
                highlightBubble(doc: doc)
                VStack(spacing: 0) {
                    topBar(book: book)
                        .opacity(controller.chromeVisible ? 1 : 0)
                        .offset(y: controller.chromeVisible ? 0 : -10)
                        .animation(.easeOut(duration: controller.chromeVisible ? 0.12 : 0.25), value: controller.chromeVisible)
                        .allowsHitTesting(controller.chromeVisible)
                    Spacer()
                }
                VStack {
                    Spacer()
                    scrubber(doc: doc)
                        .padding(.horizontal, 60)
                        .padding(.bottom, 14)
                        .opacity(controller.hoverZone == .bottom ? 1 : 0)
                        .offset(y: controller.hoverZone == .bottom ? 0 : 12)
                        .animation(.easeOut(duration: 0.18), value: controller.hoverZone == .bottom)
                        .allowsHitTesting(controller.hoverZone == .bottom)
                        .onHover { if $0 { controller.hoverZone = .bottom } }
                }
            }
            .animation(.easeOut(duration: 0.15), value: controller.menu?.id)
        }
        .ignoresSafeArea()
        .navigationTitle(book.title)
    }

    // MARK: Floating top bar (replaces the native toolbar so the page always owns the full window)

    private func topBar(book: Book) -> some View {
        let marked = book.bookmarks.contains(controller.currentPage)
        return HStack(spacing: 14) {
            barButton("sidebar.left", help: "Sidebar (⌃⌘S)") { handle(.toggleSidebar) }
                .padding(.leading, 70)   // clear of the traffic lights in windowed mode
            Spacer()
            VStack(spacing: 1) {
                Text(book.title).font(.callout.weight(.semibold)).lineLimit(1)
                if !book.author.isEmpty { Text(book.author).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(maxWidth: 520)
            Spacer()
            Menu {
                Picker("Page", selection: theme) {
                    Section("Light") { ForEach(PageTheme.lightStyles) { Text($0.label).tag($0) } }
                    Section("Dark") { ForEach(PageTheme.darkStyles) { Text($0.label).tag($0) } }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Zoom In") { controller.zoomIn() }
                Button("Zoom Out") { controller.zoomOut() }
                Button("Fit Page") { controller.fit() }.disabled(!controller.isZoomed)
            } label: {
                Image(systemName: "textformat.size").font(.body.weight(.medium))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(width: 28)
            .help("Page color and zoom")
            barButton("number", help: "Go to Page (⌥⌘G)") { handle(.goToPage) }
            barButton("magnifyingglass", help: "Search (⌘F)") { handle(.find) }
            barButton(marked ? "bookmark.fill" : "bookmark", help: marked ? "Remove Bookmark (⌘D)" : "Bookmark (⌘D)",
                      tint: marked ? .red : .primary) { store.toggleBookmark(bookID, page: controller.currentPage) }
                .padding(.trailing, 16)
        }
        .frame(height: 52)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private func barButton(_ icon: String, help: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.body.weight(.medium)).foregroundStyle(tint).frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    // MARK: Highlight bubble (appears under a text selection or on a tapped highlight)

    @ViewBuilder
    private func highlightBubble(doc: PDFDocument) -> some View {
        if let m = controller.menu {
            GeometryReader { geo in
                let width: CGFloat = 340
                let x = min(max(m.anchor.midX - width / 2, 8), max(8, geo.size.width - width - 8))
                let below = m.anchor.maxY + 10
                let y = below + 60 < geo.size.height ? below : max(8, m.anchor.minY - 66)
                HighlightMenuView(
                    current: m.existing?.color,
                    initialNote: m.existing?.note ?? "",
                    isExisting: m.existing != nil,
                    onColor: { c in
                        if let h = m.existing { store.updateHighlight(bookID, h.id) { $0.color = c } }
                        else if let sel = m.selection { store.addHighlights(bookID, Highlight.make(from: sel, in: doc, color: c, note: "")) }
                        controller.dismissMenu()
                    },
                    onSaveNote: { note in
                        if let h = m.existing { store.updateHighlight(bookID, h.id) { $0.note = note } }
                        else if let sel = m.selection { store.addHighlights(bookID, Highlight.make(from: sel, in: doc, color: .yellow, note: note)) }
                        controller.dismissMenu()
                    },
                    onCopy: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(m.existing?.text ?? m.selection?.string ?? "", forType: .string)
                        controller.dismissMenu()
                    },
                    onDelete: m.existing.map { h in { store.removeHighlight(bookID, h.id); controller.dismissMenu() } })
                .frame(width: width)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.black.opacity(0.1)))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                .offset(x: x, y: y)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
            .id(m.id)
        }
    }

    // MARK: Edge arrows (hover near either side, like Books)

    private func edgeArrows(doc: PDFDocument) -> some View {
        let count = doc.pageCount
        let atStart = controller.currentPage <= 0
        let atEnd = controller.currentPage >= count - 1
        return HStack {
            arrow("chevron.left", visible: controller.hoverZone == .left && !atStart, zone: .left) { controller.previous() }
            Spacer()
            arrow("chevron.right", visible: controller.hoverZone == .right && !atEnd, zone: .right) { controller.next() }
        }
        .padding(.horizontal, 22)
    }

    private func arrow(_ icon: String, visible: Bool, zone: HoverZone, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 46, height: 46)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.black.opacity(0.08)))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.85)
        .animation(.easeOut(duration: 0.15), value: visible)
        .allowsHitTesting(visible)
        .onHover { if $0 { controller.hoverZone = zone } }
    }

    // MARK: Bottom scrubber (hover-only)

    private func scrubber(doc: PDFDocument) -> some View {
        let count = max(1, doc.pageCount)
        let current = controller.currentPage
        let label = doc.page(at: current)?.label
        let left = count - current - 1
        return HStack(spacing: 14) {
            Slider(value: Binding(
                get: { Double(current) },
                set: { controller.go(to: Int($0.rounded())) }
            ), in: 0...Double(max(1, count - 1)))
            .controlSize(.small)
            VStack(alignment: .trailing, spacing: 0) {
                Text(label.map { $0 != "\(current + 1)" ? "Page \($0) · \(current + 1) of \(count)" : "Page \(current + 1) of \(count)" }
                     ?? "Page \(current + 1) of \(count)")
                    .font(.caption.monospacedDigit())
                Text(left == 0 ? "Last page" : "\(left) page\(left == 1 ? "" : "s") left")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(minWidth: 150, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .frame(maxWidth: 720)
    }

}

// MARK: - Sidebar

enum SidebarTab: String, CaseIterable, Identifiable {
    case pages, contents, bookmarks, notes, search
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .pages: "square.grid.2x2"
        case .contents: "list.bullet"
        case .bookmarks: "bookmark"
        case .notes: "highlighter"
        case .search: "magnifyingglass"
        }
    }
    var title: String {
        switch self {
        case .pages: "Pages"; case .contents: "Contents"; case .bookmarks: "Bookmarks"
        case .notes: "Notes & Highlights"; case .search: "Search"
        }
    }
}

struct ReaderSidebar: View {
    let document: PDFDocument
    let controller: ReaderController
    let bookID: UUID
    @Binding var tab: SidebarTab
    @Environment(LibraryStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(SidebarTab.allCases) { t in
                    Image(systemName: t.icon).help(t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            switch tab {
            case .pages: ThumbnailList(document: document, controller: controller)
            case .contents: OutlineList(document: document, controller: controller)
            case .bookmarks: BookmarkList(document: document, controller: controller, bookID: bookID)
            case .notes: NotesList(document: document, controller: controller, bookID: bookID)
            case .search: SearchPanel(document: document, controller: controller)
            }
        }
    }
}

private struct ThumbnailList: View {
    let document: PDFDocument
    let controller: ReaderController

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(0..<document.pageCount, id: \.self) { i in
                        ThumbnailCell(document: document, index: i, selected: i == controller.currentPage)
                            .id(i)
                            .onTapGesture { controller.go(to: i) }
                    }
                }
                .padding(14)
            }
            .onAppear { proxy.scrollTo(controller.currentPage, anchor: .center) }
            .onChange(of: controller.currentPage) { _, new in
                withAnimation { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }
}

private struct ThumbnailCell: View {
    let document: PDFDocument
    let index: Int
    let selected: Bool
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(Color.white).aspectRatio(0.72, contentMode: .fit)
                }
            }
            .frame(maxWidth: 140, maxHeight: 190)
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .overlay(RoundedRectangle(cornerRadius: 2)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3).padding(-4))
            Text(document.page(at: index)?.label ?? "\(index + 1)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(selected ? Color.accentColor : .secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .task(id: index) {
            image = document.page(at: index)?.thumbnail(of: NSSize(width: 280, height: 380), for: .cropBox)
        }
    }
}

private struct OutlineEntry: Identifiable {
    let id: Int
    let title: String
    let page: Int
    let depth: Int
}

private struct OutlineList: View {
    let document: PDFDocument
    let controller: ReaderController
    @State private var entries: [OutlineEntry] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded && entries.isEmpty {
                ContentUnavailableView("No table of contents", systemImage: "list.bullet",
                                       description: Text("This PDF doesn’t include chapter info. Use Pages or Search instead."))
            } else {
                let currentID = entries.last { $0.page >= 0 && $0.page <= controller.currentPage }?.id
                List(entries) { e in
                    Button { if e.page >= 0 { controller.go(to: e.page) } } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(e.title)
                                .font(e.depth == 0 ? .callout.weight(.semibold) : .callout)
                                .lineLimit(2)
                            Spacer(minLength: 6)
                            if e.page >= 0 {
                                Text(document.page(at: e.page)?.label ?? "\(e.page + 1)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.leading, CGFloat(e.depth) * 14)
                        .foregroundStyle(e.id == currentID ? Color.accentColor : .primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
        }
        .task {
            var out: [OutlineEntry] = []
            func walk(_ o: PDFOutline, depth: Int) {
                for i in 0..<o.numberOfChildren {
                    guard let c = o.child(at: i) else { continue }
                    let page = c.destination?.page ?? (c.action as? PDFActionGoTo)?.destination.page
                    let idx = page.map { document.index(for: $0) } ?? -1
                    out.append(OutlineEntry(id: out.count, title: c.label ?? "Untitled", page: idx, depth: depth))
                    if depth < 4 { walk(c, depth: depth + 1) }
                }
            }
            if let root = document.outlineRoot { walk(root, depth: 0) }
            entries = out
            loaded = true
        }
    }
}

private struct BookmarkList: View {
    let document: PDFDocument
    let controller: ReaderController
    let bookID: UUID
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let marks = store.book(bookID)?.bookmarks ?? []
        if marks.isEmpty {
            ContentUnavailableView("No bookmarks", systemImage: "bookmark",
                                   description: Text("Press ⌘D or the bookmark button to save your place on a page."))
        } else {
            List(marks, id: \.self) { p in
                Button { controller.go(to: p) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Page \(document.page(at: p)?.label ?? "\(p + 1)")").font(.callout.weight(.semibold))
                        Text(snippet(p)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Remove Bookmark", role: .destructive) { store.toggleBookmark(bookID, page: p) }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func snippet(_ p: Int) -> String {
        let s = document.page(at: p)?.string ?? ""
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.isEmpty ? "(no text on this page)" : String(flat.prefix(120))
    }
}

// MARK: Notes & Highlights

private struct NotesList: View {
    let document: PDFDocument
    let controller: ReaderController
    let bookID: UUID
    @Environment(LibraryStore.self) private var store
    @State private var editing: Highlight?
    @State private var noteText = ""

    var body: some View {
        let hs = (store.book(bookID)?.highlights ?? [])
            .sorted { $0.page != $1.page ? $0.page < $1.page : $0.bounds.maxY > $1.bounds.maxY }
        Group {
            if hs.isEmpty {
                ContentUnavailableView("No highlights yet", systemImage: "highlighter",
                                       description: Text("Select text and pick a color, or hold ⌥ Option and drag in a margin to draw a brace. They all show up here."))
            } else {
                List(hs) { h in
                    Button { controller.pendingHighlight = h; controller.go(to: h) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            if h.kind == .brace {
                                Text("{").font(.system(size: 26, weight: .light, design: .serif))
                                    .foregroundStyle(.primary).frame(width: 12)
                            } else {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color(nsColor: h.color.nsColor))
                                    .frame(width: 4)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(h.text.isEmpty ? "(image or empty selection)" : h.text)
                                    .font(.callout).lineLimit(4)
                                if !h.note.isEmpty {
                                    Label(h.note, systemImage: "note.text")
                                        .font(.callout.italic()).foregroundStyle(.secondary).lineLimit(3)
                                }
                                Text("Page \(document.page(at: h.page)?.label ?? "\(h.page + 1)") · \(h.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(h.note.isEmpty ? "Add Note…" : "Edit Note…") { noteText = h.note; editing = h }
                        Menu("Color") {
                            ForEach(HighlightColor.allCases) { c in
                                Button(c.label) { store.updateHighlight(bookID, h.id) { $0.color = c } }
                            }
                        }
                        Button("Copy Text") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(h.text, forType: .string)
                        }
                        Divider()
                        Button("Remove Highlight", role: .destructive) { store.removeHighlight(bookID, h.id) }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .alert("Note", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Your note", text: $noteText)
            Button("Save") {
                if let h = editing { store.updateHighlight(bookID, h.id) { $0.note = noteText } }
                editing = nil
            }
            Button("Cancel", role: .cancel) { editing = nil }
        }
    }
}

// MARK: Search

private struct SearchHit: Identifiable {
    let id: Int
    let selection: PDFSelection
    let page: Int
    let context: String
}

private struct SearchPanel: View {
    let document: PDFDocument
    let controller: ReaderController
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searched = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search this book", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(run)
                .padding(10)
            if searched {
                Text(hits.isEmpty ? "No results" : "\(hits.count)\(hits.count >= 500 ? "+" : "") results")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }
            List(hits) { h in
                Button { controller.go(to: h.selection) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Page \(document.page(at: h.page)?.label ?? "\(h.page + 1)")")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(h.context).font(.callout).lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
        }
        .onAppear { focused = true }
    }

    private func run() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { hits = []; searched = false; return }
        let results = document.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive])
        hits = results.prefix(500).enumerated().compactMap { i, sel in
            guard let page = sel.pages.first else { return nil }
            let ctx = sel.copy() as! PDFSelection
            ctx.extendForLineBoundaries()
            let text = (ctx.string ?? q).split(whereSeparator: \.isNewline).joined(separator: " ")
            return SearchHit(id: i, selection: sel, page: document.index(for: page), context: text)
        }
        searched = true
    }
}
