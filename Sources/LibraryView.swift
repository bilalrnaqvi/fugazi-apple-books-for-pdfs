import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case all, reading, unread, finished
    case collection(UUID)
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent = "Recently Read"
    case added = "Date Added"
    case title = "Title"
    case author = "Author"
    var id: String { rawValue }
}

struct LibraryView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    @State private var selection: SidebarItem? = .all
    @State private var search = ""
    @AppStorage("librarySort") private var sort: LibrarySort = .recent
    @AppStorage("appAppearance") private var appearance: AppAppearance = .light
    @State private var dropTargeted = false

    // Rename / new-collection prompts
    @State private var namePrompt: NamePrompt?
    @State private var nameText = ""
    @State private var confirmRemove: Book?

    struct NamePrompt: Identifiable {
        enum Kind { case newCollection, renameCollection(UUID), renameBook(UUID) }
        let id = UUID()
        let kind: Kind
        let title: String
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } detail: {
            detail
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search library")
        .toolbar {
            ToolbarItem {
                Picker("Sort", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Sort books")
            }
            ToolbarItem {
                Menu {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Appearance", systemImage: "circle.lefthalf.filled")
                }
                .onChange(of: appearance) { _, _ in AppAppearance.apply() }
                .help("Light or dark appearance")
            }
            ToolbarItem {
                Button { store.presentImportPanel() } label: {
                    Label("Add PDFs", systemImage: "plus")
                }
                .help("Add PDFs to your library (⌘O)")
            }
        }
        .alert(namePrompt?.title ?? "", isPresented: Binding(
            get: { namePrompt != nil }, set: { if !$0 { namePrompt = nil } }
        )) {
            TextField("Name", text: $nameText)
            Button("Save") { commitName() }
            Button("Cancel", role: .cancel) { namePrompt = nil }
        }
        .confirmationDialog(
            "Remove “\(confirmRemove?.title ?? "")” from your library?",
            isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let b = confirmRemove { store.remove([b.id]) }
                confirmRemove = nil
            }
        } message: {
            Text("The library’s copy of this PDF will be deleted. Your original file is not affected.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .folioOpenBooks)) { note in
            for id in (note.object as? [UUID]) ?? [] { openWindow(id: "reader", value: id) }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Library") {
                row("All Books", "books.vertical", .all, count: store.books.count)
                row("Reading Now", "book", .reading, count: store.books.filter(\.isReading).count)
                row("Not Started", "sparkles", .unread, count: store.books.filter { !$0.isStarted }.count)
                row("Finished", "checkmark.circle", .finished, count: store.books.filter(\.finished).count)
            }
            Section("Collections") {
                ForEach(store.collections) { c in
                    row(c.name, "rectangle.stack", .collection(c.id),
                        count: store.books.filter { $0.collectionIDs.contains(c.id) }.count)
                        .dropDestination(for: String.self) { items, _ in
                            let ids = Set(items.compactMap(UUID.init(uuidString:)))
                            store.setCollection(ids, c.id, member: true)
                            return !ids.isEmpty
                        }
                        .contextMenu {
                            Button("Rename…") { prompt(.renameCollection(c.id), "Rename Collection", c.name) }
                            Button("Delete Collection", role: .destructive) {
                                if selection == .collection(c.id) { selection = .all }
                                store.deleteCollection(c.id)
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button { prompt(.newCollection, "New Collection", "") } label: {
                Label("New Collection", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
    }

    private func row(_ title: String, _ icon: String, _ tag: SidebarItem, count: Int) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if count > 0 { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
            }
        } icon: { Image(systemName: icon) }
        .tag(tag)
    }

    // MARK: Detail

    private var currentTitle: String {
        switch selection ?? .all {
        case .all: return "All Books"
        case .reading: return "Reading Now"
        case .unread: return "Not Started"
        case .finished: return "Finished"
        case .collection(let id): return store.collections.first { $0.id == id }?.name ?? "Collection"
        }
    }

    private var currentCollection: UUID? {
        if case .collection(let id) = selection { return id }
        return nil
    }

    private var filtered: [Book] {
        var list = store.books
        switch selection ?? .all {
        case .all: break
        case .reading: list = list.filter(\.isReading)
        case .unread: list = list.filter { !$0.isStarted }
        case .finished: list = list.filter(\.finished)
        case .collection(let id): list = list.filter { $0.collectionIDs.contains(id) }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.author.localizedCaseInsensitiveContains(q) }
        }
        switch sort {
        case .recent: list.sort { ($0.lastOpened ?? $0.addedAt) > ($1.lastOpened ?? $1.addedAt) }
        case .added: list.sort { $0.addedAt > $1.addedAt }
        case .title: list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author: list.sort { $0.author.localizedStandardCompare($1.author) == .orderedAscending }
        }
        return list
    }

    @ViewBuilder
    private var detail: some View {
        let books = filtered
        ZStack {
            Color(nsColor: .textBackgroundColor).ignoresSafeArea()
            if store.books.isEmpty {
                ContentUnavailableView {
                    Label("Your library is empty", systemImage: "books.vertical")
                } description: {
                    Text("Drag PDFs or folders here, or click Add PDFs.")
                } actions: {
                    Button("Add PDFs…") { store.presentImportPanel() }.buttonStyle(.borderedProminent)
                }
            } else if books.isEmpty {
                ContentUnavailableView(search.isEmpty ? "Nothing here yet" : "No matches",
                                       systemImage: search.isEmpty ? "tray" : "magnifyingglass",
                                       description: Text(search.isEmpty
                                            ? (currentCollection != nil ? "Drag books onto this collection in the sidebar." : "")
                                            : "No books match “\(search)”."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(currentTitle).font(.title2.bold())
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 26, alignment: .bottom)],
                                  alignment: .leading, spacing: 34) {
                            ForEach(books) { b in cell(b, coverHeight: 210) }
                        }
                    }
                    .padding(28)
                }
            }
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.06))
                    .overlay(Label("Drop PDFs to add them", systemImage: "arrow.down.doc").font(.title2))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let ids = store.importPDFs(urls, into: currentCollection)
            return !ids.isEmpty
        } isTargeted: { dropTargeted = $0 }
    }

    private func cell(_ book: Book, coverHeight: CGFloat) -> some View {
        BookCell(book: book, coverHeight: coverHeight)
            .onTapGesture { openWindow(id: "reader", value: book.id) }
            .draggable(book.id.uuidString) {
                Label(book.title, systemImage: "doc.richtext").padding(6)
            }
            .contextMenu { menu(for: book) }
    }

    @ViewBuilder
    private func menu(for book: Book) -> some View {
        Button("Open") { openWindow(id: "reader", value: book.id) }
        Divider()
        if !store.collections.isEmpty {
            Menu("Collections") {
                ForEach(store.collections) { c in
                    let inIt = book.collectionIDs.contains(c.id)
                    Button { store.setCollection([book.id], c.id, member: !inIt) } label: {
                        if inIt { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                    }
                }
            }
        }
        Button("New Collection with This Book…") {
            prompt(.newCollection, "New Collection", "", pending: book.id)
        }
        Divider()
        if book.finished {
            Button("Mark as Still Reading") { store.update(book.id) { $0.finished = false } }
        } else {
            Button("Mark as Finished") { store.update(book.id) { $0.finished = true; $0.lastOpened = $0.lastOpened ?? Date() } }
        }
        if book.isStarted {
            Button("Reset Progress") { store.update(book.id) { $0.lastPage = 0; $0.lastOpened = nil; $0.finished = false; $0.readingSeconds = 0; $0.pagesTurned = 0 } }
        }
        Button("Rename…") { prompt(.renameBook(book.id), "Rename Book", book.title) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL(for: book)]) }
        Divider()
        if let c = currentCollection {
            Button("Remove from This Collection") { store.setCollection([book.id], c, member: false) }
        }
        Button("Remove from Library…", role: .destructive) { confirmRemove = book }
    }

    // MARK: Name prompts

    @State private var pendingBookForNewCollection: UUID?

    private func prompt(_ kind: NamePrompt.Kind, _ title: String, _ initial: String, pending: UUID? = nil) {
        nameText = initial
        pendingBookForNewCollection = pending
        namePrompt = NamePrompt(kind: kind, title: title)
    }

    private func commitName() {
        guard let p = namePrompt else { return }
        let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch p.kind {
        case .newCollection:
            let id = store.addCollection(name)
            if let b = pendingBookForNewCollection { store.setCollection([b], id, member: true) }
            else { selection = .collection(id) }
        case .renameCollection(let id):
            store.renameCollection(id, to: name)
        case .renameBook(let id):
            if !name.isEmpty { store.update(id) { $0.title = name } }
        }
        namePrompt = nil
        pendingBookForNewCollection = nil
    }
}

// MARK: - Book cell

struct BookCell: View {
    @Environment(LibraryStore.self) private var store
    let book: Book
    let coverHeight: CGFloat
    @State private var cover: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottom) {
                Color.clear
                Group {
                    if let cover {
                        Image(nsImage: cover)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.15))
                            .aspectRatio(0.7, contentMode: .fit)
                            .overlay(ProgressView().controlSize(.small))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .shadow(color: .black.opacity(hovering ? 0.35 : 0.22), radius: hovering ? 10 : 5, y: hovering ? 6 : 3)
                .scaleEffect(hovering ? 1.03 : 1, anchor: .bottom)
            }
            .frame(height: coverHeight)

            Text(book.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            status
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: coverHeight * 0.72)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .task(id: book.id) { cover = await Covers.image(for: book, store: store) }
        .help(book.author.isEmpty ? book.title : "\(book.title) — \(book.author)")
    }

    @ViewBuilder
    private var status: some View {
        if book.finished {
            Label("Finished", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.secondary)
        } else if book.isReading {
            HStack(spacing: 6) {
                ProgressView(value: book.progress).progressViewStyle(.linear).frame(maxWidth: 70)
                Text("\(Int(book.progress * 100))%").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        } else {
            Text(book.author.isEmpty ? " " : book.author)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
