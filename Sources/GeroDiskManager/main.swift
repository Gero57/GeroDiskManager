import SwiftUI
import AppKit
import CSQLite

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct DiskRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var rootPath: String
    var capacity: Int64
    var itemCount: Int
    var scannedAt: Date?
    var mediaType: String = "Non specificato"
    var sortOrder: Int = 0
    var isAvailable: Bool { FileManager.default.fileExists(atPath: rootPath) }
}

struct FileRecord: Identifiable, Hashable {
    var id: Int64
    var diskID: UUID
    var diskName: String
    var name: String
    var path: String
    var isDirectory: Bool
}

struct CatalogDB {
    private var db: OpaquePointer?
    private let databasePath: String
    private let queue = DispatchQueue(label: "it.gero.diskmanager.database", qos: .userInitiated)

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GeroDiskManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Nuovo archivio normalizzato: il vecchio catalog.sqlite resta intatto come sicurezza.
        let url = base.appendingPathComponent("catalog-v2.sqlite")
        databasePath = url.path
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY; PRAGMA foreign_keys=ON;", nil, nil, nil)
        sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS disks(
          id TEXT PRIMARY KEY, name TEXT NOT NULL, rootPath TEXT NOT NULL,
          capacity INTEGER NOT NULL DEFAULT 0, itemCount INTEGER NOT NULL DEFAULT 0,
          scannedAt REAL, mediaType TEXT NOT NULL DEFAULT 'Non specificato',
          sortOrder INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS items(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          diskID TEXT NOT NULL,
          parentID INTEGER NOT NULL,
          name TEXT NOT NULL,
          path TEXT,
          isDirectory INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_items_parent
          ON items(diskID,parentID,isDirectory,name COLLATE NOCASE);
        CREATE INDEX IF NOT EXISTS idx_items_name ON items(name COLLATE NOCASE);
        CREATE INDEX IF NOT EXISTS idx_items_directory_path
          ON items(diskID,path) WHERE isDirectory=1;
        """, nil, nil, nil)
    }

    private func run<T>(_ work: () -> T) -> T { queue.sync(execute: work) }

    func disks() -> [DiskRecord] {
        run {
            var out: [DiskRecord] = []
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT id,name,rootPath,capacity,itemCount,scannedAt,mediaType,sortOrder FROM disks ORDER BY sortOrder,name COLLATE NOCASE", -1, &stmt, nil)
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                out.append(DiskRecord(id: UUID(uuidString: id) ?? UUID(),
                    name: String(cString: sqlite3_column_text(stmt, 1)),
                    rootPath: String(cString: sqlite3_column_text(stmt, 2)),
                    capacity: sqlite3_column_int64(stmt, 3),
                    itemCount: Int(sqlite3_column_int64(stmt, 4)),
                    scannedAt: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                    mediaType: String(cString: sqlite3_column_text(stmt, 6)),
                    sortOrder: Int(sqlite3_column_int(stmt, 7))))
            }
            return out
        }
    }

    func upsert(_ disk: DiskRecord) {
        run {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO disks(id,name,rootPath,capacity,itemCount,scannedAt,mediaType,sortOrder) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,rootPath=excluded.rootPath,capacity=excluded.capacity,itemCount=excluded.itemCount,scannedAt=excluded.scannedAt,mediaType=excluded.mediaType,sortOrder=excluded.sortOrder", -1, &s, nil)
            defer { sqlite3_finalize(s) }
            bind(disk.id.uuidString, to: 1, in: s); bind(disk.name, to: 2, in: s); bind(disk.rootPath, to: 3, in: s)
            sqlite3_bind_int64(s, 4, disk.capacity); sqlite3_bind_int64(s, 5, Int64(disk.itemCount))
            if let date = disk.scannedAt { sqlite3_bind_double(s, 6, date.timeIntervalSince1970) } else { sqlite3_bind_null(s, 6) }
            bind(disk.mediaType, to: 7, in: s); sqlite3_bind_int(s, 8, Int32(disk.sortOrder))
            sqlite3_step(s)
        }
    }

    func removeDisk(_ id: UUID) {
        run {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "DELETE FROM items WHERE diskID=?", -1, &s, nil)
            bind(id.uuidString, to: 1, in: s); sqlite3_step(s); sqlite3_finalize(s)
            var d: OpaquePointer?
            sqlite3_prepare_v2(db, "DELETE FROM disks WHERE id=?", -1, &d, nil)
            bind(id.uuidString, to: 1, in: d); sqlite3_step(d); sqlite3_finalize(d)

            // Reclaim on-disk space immediately after removing a catalog.
            sqlite3_busy_timeout(db, 10000)
            sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
            sqlite3_exec(db, "VACUUM", nil, nil, nil)
        }
    }

    func removeDiskFilesOnly(_ id: UUID) {
        run {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "DELETE FROM items WHERE diskID=?", -1, &s, nil)
            bind(id.uuidString, to: 1, in: s); sqlite3_step(s); sqlite3_finalize(s)
        }
    }

    // Le directory conservano il percorso una sola volta. I file memorizzano
    // soltanto l'ID della cartella madre e il proprio nome.
    func insertDirectory(disk: DiskRecord, parentID: Int64, name: String, path: String) -> Int64 {
        run {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO items(diskID,parentID,name,path,isDirectory) VALUES(?,?,?,?,1)", -1, &s, nil)
            defer { sqlite3_finalize(s) }
            bind(disk.id.uuidString, to: 1, in: s)
            sqlite3_bind_int64(s, 2, parentID)
            bind(name, to: 3, in: s)
            bind(path, to: 4, in: s)
            guard sqlite3_step(s) == SQLITE_DONE else { return 0 }
            return sqlite3_last_insert_rowid(db)
        }
    }

    func insertBatch(disk: DiskRecord, records: [FileRecordInput]) {
        guard !records.isEmpty else { return }
        run {
            sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO items(diskID,parentID,name,path,isDirectory) VALUES(?,?,?,NULL,0)", -1, &s, nil)
            for r in records {
                sqlite3_reset(s); sqlite3_clear_bindings(s)
                bind(disk.id.uuidString, to: 1, in: s)
                sqlite3_bind_int64(s, 2, r.parentID)
                bind(r.name, to: 3, in: s)
                sqlite3_step(s)
            }
            sqlite3_finalize(s)
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }
    }

    private func parentID(diskID: UUID, parentPath: String) -> Int64? {
        var root: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT rootPath FROM disks WHERE id=?", -1, &root, nil)
        bind(diskID.uuidString, to: 1, in: root)
        let isRoot = sqlite3_step(root) == SQLITE_ROW && String(cString: sqlite3_column_text(root, 0)) == parentPath
        sqlite3_finalize(root)
        if isRoot { return 0 }

        var s: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT id FROM items WHERE diskID=? AND path=? AND isDirectory=1 LIMIT 1", -1, &s, nil)
        defer { sqlite3_finalize(s) }
        bind(diskID.uuidString, to: 1, in: s); bind(parentPath, to: 2, in: s)
        return sqlite3_step(s) == SQLITE_ROW ? sqlite3_column_int64(s, 0) : nil
    }

    func children(diskID: UUID, parent: String) -> [FileRecord] {
        run {
            guard let parentID = parentID(diskID: diskID, parentPath: parent) else { return [] }
            let pathExpression = "CASE WHEN f.isDirectory=1 THEN f.path WHEN COALESCE(p.path,d.rootPath)='/' THEN '/'||f.name ELSE COALESCE(p.path,d.rootPath)||'/'||f.name END"
            let sql = "SELECT f.id,f.diskID,d.name,f.name,\(pathExpression),f.isDirectory FROM items f JOIN disks d ON d.id=f.diskID LEFT JOIN items p ON p.id=f.parentID WHERE f.diskID=? AND f.parentID=? ORDER BY f.isDirectory DESC,f.name COLLATE NOCASE LIMIT 5000"
            var out: [FileRecord] = []; var s: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &s, nil)
            defer { sqlite3_finalize(s) }
            bind(diskID.uuidString, to: 1, in: s); sqlite3_bind_int64(s, 2, parentID)
            while sqlite3_step(s) == SQLITE_ROW { out.append(readRecord(s)) }
            return out
        }
    }

    func search(_ query: String, scope: String, mediaType: String, matchMode: String) -> [FileRecord] {
        guard !Task.isCancelled else { return [] }
        var searchDB: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &searchDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let searchDB else {
            if let searchDB { sqlite3_close(searchDB) }
            return []
        }
        defer { sqlite3_close(searchDB) }
        sqlite3_busy_timeout(searchDB, 5000)

        var out: [FileRecord] = []
        var statement: OpaquePointer?
        let typeFilter: String
        switch scope {
        case "Cartelle": typeFilter = " AND f.isDirectory=1"
        case "File": typeFilter = " AND f.isDirectory=0"
        default: typeFilter = ""
        }
        let condition = matchMode == "Nome esatto"
            ? "f.name = ? COLLATE NOCASE"
            : "instr(lower(f.name), lower(?)) > 0"
        let pathExpression = "CASE WHEN f.isDirectory=1 THEN f.path WHEN COALESCE(p.path,d.rootPath)='/' THEN '/'||f.name ELSE COALESCE(p.path,d.rootPath)||'/'||f.name END"
        let sql = "SELECT f.id,f.diskID,d.name,f.name,\(pathExpression),f.isDirectory FROM items f JOIN disks d ON d.id=f.diskID LEFT JOIN items p ON p.id=f.parentID WHERE " + condition + typeFilter + " AND (?='Tutti' OR d.mediaType=?) ORDER BY f.isDirectory DESC,f.name COLLATE NOCASE LIMIT 1000"
        guard sqlite3_prepare_v2(searchDB, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        bind(query, to: 1, in: statement)
        bind(mediaType, to: 2, in: statement)
        bind(mediaType, to: 3, in: statement)

        while !Task.isCancelled {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW { out.append(readRecord(statement)) }
            else { break }
        }
        return Task.isCancelled ? [] : out
    }

    private func bind(_ value: String, to index: Int32, in stmt: OpaquePointer?) {
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func readRecord(_ s: OpaquePointer?) -> FileRecord {
        FileRecord(id: sqlite3_column_int64(s, 0),
            diskID: UUID(uuidString: String(cString: sqlite3_column_text(s, 1))) ?? UUID(),
            diskName: String(cString: sqlite3_column_text(s, 2)),
            name: String(cString: sqlite3_column_text(s, 3)),
            path: String(cString: sqlite3_column_text(s, 4)),
            isDirectory: sqlite3_column_int(s, 5) != 0)
    }
}

struct FileRecordInput {
    let parentID: Int64
    let name: String
}

@MainActor
final class CatalogStore: ObservableObject {
    @Published var disks: [DiskRecord] = []
    @Published var selectedDisk: UUID?
    @Published var showingHome = true
    @Published var searchText = "" { didSet { scheduleSearch() } }
    @Published var searchScope = "Cartelle" { didSet { scheduleSearch() } }
    @Published var searchMediaType = "Tutti" { didSet { scheduleSearch() } }
    @Published var searchMatchMode = "Nome esatto" { didSet { scheduleSearch() } }
    @Published var results: [FileRecord] = []
    @Published var searchDiagnostic = "Ricerca non avviata"
    @Published var visibleChildren: [FileRecord] = []
    @Published var currentFolder: String?
    @Published var scanning = false
    @Published var progress = 0
    @Published var status = "Aggiungi un disco per iniziare"
    private let database = CatalogDB()
    private var searchTask: Task<Void, Never>?
    private var searchWorker: Task<[FileRecord], Never>?

    init() {
        disks = database.disks()
        for index in disks.indices { disks[index].sortOrder = index; database.upsert(disks[index]) }
    }

    func moveDisk(_ disk: DiskRecord, by offset: Int) {
        guard let index = disks.firstIndex(where: { $0.id == disk.id }) else { return }
        let destination = index + offset
        guard disks.indices.contains(destination) else { return }
        disks.swapAt(index, destination)
        for index in disks.indices { disks[index].sortOrder = index; database.upsert(disks[index]) }
    }

    var selectedDiskRecord: DiskRecord? { disks.first { $0.id == selectedDisk } }

    func addDisk() {
        let panel = NSOpenPanel()
        panel.title = "Seleziona il disco da catalogare"
        panel.message = "Scegli il volume. I file originali non verranno modificati."
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = url.standardizedFileURL
        guard !disks.contains(where: { $0.rootPath == root.path }) else { status = "Disco già presente"; return }
        let values = try? root.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey])
        let disk = DiskRecord(id: UUID(), name: values?.volumeName ?? root.lastPathComponent,
            rootPath: root.path, capacity: Int64(values?.volumeTotalCapacity ?? 0), itemCount: 0, scannedAt: nil, sortOrder: disks.count)
        disks.append(disk); selectedDisk = disk.id; currentFolder = disk.rootPath
        database.upsert(disk); loadChildren()
        scan(disk)
    }

    func scan(_ disk: DiskRecord) {
        guard !scanning, disk.isAvailable else { status = "Collega il disco prima di aggiornarlo"; return }
        scanning = true; progress = 0; status = "Preparazione catalogazione…"
        let root = URL(fileURLWithPath: disk.rootPath)
        let db = database
        Task.detached(priority: .userInitiated) {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                await MainActor.run { self.scanning = false; self.status = "Impossibile leggere il disco" }
                return
            }
            var batch: [FileRecordInput] = []
            var directoryIDs: [String: Int64] = [disk.rootPath: 0]
            var total = 0
            db.removeDiskFilesOnly(disk.id)

            func flushFiles() {
                guard !batch.isEmpty else { return }
                db.insertBatch(disk: disk, records: batch)
                total += batch.count
                batch.removeAll(keepingCapacity: true)
            }

            while let url = enumerator.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isHidden == true { continue }
                let parentPath = url.deletingLastPathComponent().path
                guard let parentID = directoryIDs[parentPath] else { continue }
                let isDirectory = values?.isDirectory ?? false

                if isDirectory {
                    // Inseriamo subito le directory per conoscere l'ID da assegnare ai figli.
                    flushFiles()
                    let id = db.insertDirectory(disk: disk, parentID: parentID,
                                                name: url.lastPathComponent, path: url.path)
                    if id > 0 {
                        directoryIDs[url.path] = id
                        total += 1
                    }
                } else {
                    batch.append(FileRecordInput(parentID: parentID, name: url.lastPathComponent))
                    if batch.count >= 750 { flushFiles() }
                }

                if total > 0 && total % 3000 == 0 {
                    let count = total
                    await MainActor.run { self.progress = count; self.status = "Catalogati \(count.formatted()) elementi…" }
                }
            }
            flushFiles()
            let finalCount = total
            await MainActor.run {
                self.progress = finalCount
                self.status = "Catalogati \(finalCount.formatted()) elementi…"
            }
            await MainActor.run {
                if let i = self.disks.firstIndex(where: { $0.id == disk.id }) {
                    self.disks[i].itemCount = total
                    self.disks[i].scannedAt = Date()
                    db.upsert(self.disks[i])
                }
                self.scanning = false
                self.status = "Catalogazione completata: \(total.formatted()) elementi"
                self.loadChildren()
                self.scheduleSearch()
            }
        }
    }

    func showHome() {
        showingHome = true
        selectedDisk = nil
        currentFolder = nil
        searchText = ""
        visibleChildren = []
    }

    func select(_ disk: DiskRecord) {
        showingHome = false
        selectedDisk = disk.id; currentFolder = disk.rootPath; searchText = ""; loadChildren()
    }

    func selectFolder(_ disk: DiskRecord, path: String) {
        showingHome = false
        selectedDisk = disk.id
        currentFolder = path
        searchText = ""
        loadChildren()
    }

    func fetchSidebarChildren(diskID: UUID, parent: String, completion: @escaping ([FileRecord]) -> Void) {
        let db = database
        Task.detached {
            let rows = db.children(diskID: diskID, parent: parent)
            await MainActor.run { completion(rows) }
        }
    }

    func loadChildren() {
        guard let disk = selectedDiskRecord, let folder = currentFolder else { visibleChildren = []; return }
        let db = database
        Task.detached { let rows = db.children(diskID: disk.id, parent: folder); await MainActor.run { self.visibleChildren = rows } }
    }

    func enter(_ item: FileRecord) {
        guard item.isDirectory else { reveal(item); return }
        currentFolder = item.path; loadChildren()
    }

    func goUp() {
        guard let disk = selectedDiskRecord, let folder = currentFolder, folder != disk.rootPath else { return }
        currentFolder = URL(fileURLWithPath: folder).deletingLastPathComponent().path; loadChildren()
    }

    private func scheduleSearch() {
        // Annulla sia l'attesa sia l'eventuale query precedente.
        // Il worker controlla la cancellazione quando entra nella coda SQLite.
        searchTask?.cancel()
        searchWorker?.cancel()
        searchWorker = nil

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = []; searchDiagnostic = "Inserisci un termine di ricerca"; return }
        searchDiagnostic = "In attesa della ricerca…"
        let db = database
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }

            let scope = searchScope
            let mediaType = searchMediaType
            let matchMode = searchMatchMode
            let worker = Task.detached(priority: .userInitiated) {
                db.search(q, scope: scope, mediaType: mediaType, matchMode: matchMode)
            }
            searchWorker = worker
            let rows = await worker.value
            guard !Task.isCancelled else { return }
            searchWorker = nil
            results = rows
            searchDiagnostic = "\(matchMode) • \"\(q)\" • \(rows.count) risultati"
        }
    }

    func setMediaType(_ type: String, for disk: DiskRecord) {
        guard let index = disks.firstIndex(where: { $0.id == disk.id }) else { return }
        disks[index].mediaType = type
        database.upsert(disks[index])
        scheduleSearch()
    }

    func remove(_ disk: DiskRecord) {
        database.removeDisk(disk.id); disks.removeAll { $0.id == disk.id }
        if selectedDisk == disk.id { selectedDisk = nil; currentFolder = nil; visibleChildren = [] }
        for index in disks.indices { disks[index].sortOrder = index; database.upsert(disks[index]) }
        status = "Catalogo rimosso"
    }

    func reveal(_ item: FileRecord) {
        guard FileManager.default.fileExists(atPath: item.path) else { status = "Collega il disco: \(item.diskName)"; return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }
}

@main struct GeroDiskManagerApp: App {
    @StateObject private var store = CatalogStore()
    var body: some Scene {
        WindowGroup { MainView().environmentObject(store).frame(minWidth: 900, minHeight: 620) }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .textEditing) {
                Button("Cerca nei cataloghi") { NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSearchField.selectText(_:)), with: nil) }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}


private struct AppTextScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.35
}

private extension EnvironmentValues {
    var appTextScale: Double {
        get { self[AppTextScaleKey.self] }
        set { self[AppTextScaleKey.self] = newValue }
    }
}

private struct AppScaledFont: ViewModifier {
    @Environment(\.appTextScale) private var scale
    let style: Font.TextStyle
    var weight: Font.Weight = .regular

    private var baseSize: CGFloat {
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline: return 17
        case .subheadline: return 16
        case .body: return 16
        case .callout: return 16
        case .footnote: return 14
        case .caption: return 14
        case .caption2: return 13
        @unknown default: return 16
        }
    }

    func body(content: Content) -> some View {
        content.font(.system(size: baseSize * scale, weight: weight))
    }
}

private extension View {
    func appFont(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> some View {
        modifier(AppScaledFont(style: style, weight: weight))
    }
}

struct MainView: View {
    @EnvironmentObject var store: CatalogStore
    @AppStorage("appearanceTheme") private var appearanceTheme = "Scuro"
    @AppStorage("backgroundTone") private var backgroundTone = "Blu"
    @AppStorage("textScaleV2") private var textScale = 1.35
    @State private var showingSettings = false
    @State private var isReordering = false
    @State private var diskPendingDeletion: DiskRecord?
    private var colorScheme: ColorScheme? { appearanceTheme == "Chiaro" ? .light : .dark }
    private var accent: Color { appearanceTheme == "Classico" ? Color(red: 0.66, green: 0.46, blue: 0.22) : Color.accentColor }
    private var canvas: Color {
        if appearanceTheme == "Classico" { return Color(red: 0.20, green: 0.17, blue: 0.13) }
        if appearanceTheme == "Chiaro" { return Color(nsColor: .windowBackgroundColor) }
        switch backgroundTone {
        case "Viola": return Color(red: 0.12, green: 0.09, blue: 0.20)
        case "Verde": return Color(red: 0.07, green: 0.16, blue: 0.15)
        case "Grafite": return Color(red: 0.10, green: 0.11, blue: 0.13)
        case "Ardesia": return Color(red: 0.12, green: 0.15, blue: 0.20)
        default: return Color(red: 0.06, green: 0.11, blue: 0.19)
        }
    }
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 8) {
                HStack {
                    Text("CATALOGHI").appFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                    Spacer()
                    Button { isReordering.toggle() } label: { Image(systemName: isReordering ? "checkmark" : "arrow.up.arrow.down") }.buttonStyle(.borderless).help(isReordering ? "Fine riordino" : "Riordina cataloghi")
                    Button(action: store.addDisk) { Image(systemName: "plus") }.buttonStyle(.borderless).help("Aggiungi disco")
                }.padding(.horizontal, 14).padding(.top, 16)

                List {
                    Button(action: store.showHome) {
                        Label("Home", systemImage: "square.grid.2x2")
                            .fontWeight(store.showingHome ? .semibold : .regular)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(store.showingHome ? Color.accentColor.opacity(0.12) : Color.clear)

                    ForEach(Array(store.disks.enumerated()), id: \.element.id) { index, disk in
                        DiskSidebarSection(
                            disk: disk,
                            selected: store.selectedDisk == disk.id && !store.showingHome,
                            isReordering: isReordering,
                            canMoveUp: index > 0,
                            canMoveDown: index < store.disks.count - 1,
                            onMoveUp: { store.moveDisk(disk, by: -1) },
                            onMoveDown: { store.moveDisk(disk, by: 1) },
                            onSelect: { store.select(disk) },
                            onDelete: { diskPendingDeletion = disk }
                        )
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.sidebar)

                Button(action: store.addDisk) {
                    Label("Aggiungi disco", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).padding(12)
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Gero Disk Manager").appFont(.largeTitle, weight: .bold)
                        Text("Un'unica ricerca in tutti i tuoi dischi, anche offline.").foregroundStyle(.secondary)
                    }
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape").appFont(.title2)
                    }.buttonStyle(.borderless).help("Impostazioni")
                    Spacer()
                    if store.scanning {
                        VStack(alignment: .trailing) {
                            ProgressView()
                            Text("\(store.progress.formatted()) voci").appFont(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }.padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 20)

                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Cerca un file o una cartella…", text: $store.searchText).textFieldStyle(.plain).appFont(.title3)
                    if !store.searchText.isEmpty {
                        Button { store.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                    }
                }
                .padding(14).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 28)

                if !store.searchText.isEmpty {
                    HStack(spacing: 12) {
                        Text("Mostra:").appFont(.caption).foregroundStyle(.secondary)
                        Picker("Tipo di risultato", selection: $store.searchScope) {
                            Text("Cartelle").tag("Cartelle")
                            Text("File").tag("File")
                            Text("Tutto").tag("Tutto")
                        }.pickerStyle(.segmented).frame(maxWidth: 300)
                        Picker("Supporto", selection: $store.searchMediaType) {
                            Text("Tutti i supporti").tag("Tutti")
                            ForEach(["HDD", "SSD", "USB", "Scheda SD", "Altro", "Non specificato"], id: \.self) { Text($0).tag($0) }
                        }.frame(width: 170)
                        Picker("", selection: $store.searchMatchMode) {
                            Text("Nome esatto").tag("Nome esatto")
                            Text("Contiene").tag("Contiene")
                        }.pickerStyle(.segmented).frame(width: 190)
                        Spacer()
                    }.padding(.horizontal, 30).padding(.top, 10)
                }

                HStack {
                    Text(store.searchText.isEmpty ? (store.showingHome ? "I TUOI DISCHI" : "CONTENUTO DEL DISCO") : "RISULTATI (MASSIMO 1.000)")
                        .appFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                    Spacer()
                    if let disk = store.selectedDiskRecord, !store.showingHome {
                        Button("Aggiorna catalogo") { store.scan(disk) }.disabled(store.scanning || !disk.isAvailable)
                    }
                }.padding(.horizontal, 30).padding(.top, 24).padding(.bottom, 8)

                if !store.searchText.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.searchDiagnostic).appFont(.caption).foregroundStyle(.secondary)
                        List(store.results) { item in resultRow(item) }
                    }
                } else if store.showingHome || store.selectedDiskRecord == nil {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            diskSection("SSD", disks: store.disks.filter { $0.mediaType == "SSD" })
                            diskSection("HDD", disks: store.disks.filter { $0.mediaType == "HDD" })
                            diskSection("ALTRI SUPPORTI", disks: store.disks.filter { !["SSD", "HDD"].contains($0.mediaType) })
                        }
                        .padding(28)
                    }
                } else if let disk = store.selectedDiskRecord {
                    HStack {
                        Button(action: store.goUp) { Image(systemName: "arrow.up") }
                            .disabled(store.currentFolder == disk.rootPath)
                        Text(store.currentFolder == disk.rootPath ? disk.name : URL(fileURLWithPath: store.currentFolder ?? disk.rootPath).lastPathComponent)
                            .appFont(.headline)
                        Spacer()
                        Text("\(disk.itemCount.formatted()) elementi indicizzati").appFont(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 28).padding(.top, 12)

                    List(store.visibleChildren) { item in
                        HStack {
                            Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                                .foregroundStyle(item.isDirectory ? .blue : .secondary)
                            Text(item.name)
                            Spacer()
                            if !item.isDirectory {
                                Text(item.path.components(separatedBy: "/").dropLast().joined(separator: "/"))
                                    .appFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { store.enter(item) }
                        .contextMenu {
                            Button("Apri / mostra nel Finder") { store.reveal(item) }
                            if item.isDirectory { Button("Apri cartella") { store.enter(item) } }
                        }
                    }.listStyle(.inset)
                }

                HStack {
                    Text(store.status).appFont(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(store.disks.count) dischi").appFont(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
            }
        }
        .confirmationDialog("Eliminare questo catalogo?", isPresented: Binding(
            get: { diskPendingDeletion != nil },
            set: { if !$0 { diskPendingDeletion = nil } }
        ), titleVisibility: .visible) {
            Button("Elimina catalogo", role: .destructive) {
                if let disk = diskPendingDeletion { store.remove(disk) }
                diskPendingDeletion = nil
            }
            Button("Annulla", role: .cancel) { diskPendingDeletion = nil }
        } message: {
            Text("Verranno eliminati solo i dati indicizzati da Gero Disk Manager. I file originali sul disco non verranno toccati.")
        }
        .sheet(isPresented: $showingSettings) {
            AppearanceSettings(theme: $appearanceTheme, tone: $backgroundTone, scale: $textScale)
                .frame(width: 470, height: 430)
        }
        .preferredColorScheme(colorScheme)
        .tint(accent)
        .environment(\.appTextScale, textScale)
        .background(canvas)
    }

    @ViewBuilder
    private func diskSection(_ title: String, disks: [DiskRecord]) -> some View {
        if !disks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).appFont(.headline, weight: .semibold).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                    ForEach(disks) { disk in diskCard(disk) }
                }
            }
        }
    }

    private func diskCard(_ disk: DiskRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: disk.isAvailable ? "externaldrive.fill" : "externaldrive")
                    .appFont(.title2).foregroundStyle(disk.isAvailable ? .green : .secondary)
                Spacer()
                Circle().fill(disk.isAvailable ? .green : .gray).frame(width: 8, height: 8)
            }
            Text(disk.name).appFont(.headline).lineLimit(1)
            Text("\(disk.itemCount.formatted()) elementi").appFont(.subheadline).foregroundStyle(.secondary)
            Text(disk.isAvailable ? "Collegato" : "Offline").appFont(.caption).foregroundStyle(.secondary)
            Picker("Supporto", selection: Binding(
                get: { store.disks.first(where: { $0.id == disk.id })?.mediaType ?? "Non specificato" },
                set: { store.setMediaType($0, for: disk) }
            )) {
                ForEach(["Non specificato", "HDD", "SSD", "USB", "Scheda SD", "Altro"], id: \.self) { Text($0).tag($0) }
            }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("Apri catalogo") { store.select(disk) }
                Spacer()
                Button { diskPendingDeletion = disk } label: {
                    Image(systemName: "trash")
                }.buttonStyle(.borderless).help("Elimina questo catalogo")
                Button { store.scan(disk) } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(!disk.isAvailable || store.scanning)
            }
        }
        .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
        .contextMenu { Button("Rimuovi catalogo", role: .destructive) { diskPendingDeletion = disk } }
    }

    @ViewBuilder private func resultRow(_ item: FileRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(item.isDirectory ? .blue : .secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).appFont(.body, weight: .medium)
                Text(item.path).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(item.diskName).appFont(.caption, weight: .semibold)
                Text(FileManager.default.fileExists(atPath: item.path) ? "Collegato" : "Offline")
                    .appFont(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle()).onTapGesture(count: 2) { store.reveal(item) }
        .contextMenu { Button("Mostra nel Finder") { store.reveal(item) } }
    }
}

struct DiskSidebarSection: View {
    @EnvironmentObject var store: CatalogStore
    let disk: DiskRecord
    let selected: Bool
    let isReordering: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var expanded = false
    @State private var children: [FileRecord] = []

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(children) { item in
                if item.isDirectory {
                    AnyView(SidebarFolderRow(disk: disk, item: item, depth: 1))
                } else {
                    AnyView(Button {
                        store.reveal(item)
                    } label: {
                        Label(item.name, systemImage: "doc").lineLimit(1)
                    }.buttonStyle(.plain).padding(.leading, 18))
                }
            }
        } label: {
            HStack(spacing: 5) {
                Button(action: onSelect) {
                    HStack(spacing: 8) {
                        Image(systemName: disk.isAvailable ? "externaldrive.fill" : "externaldrive")
                            .foregroundStyle(disk.isAvailable ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(disk.name).lineLimit(1)
                            Text("\(disk.itemCount.formatted()) elementi · \(disk.isAvailable ? "Collegato" : "Offline")")
                                .appFont(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .background(selected ? Color.accentColor.opacity(0.12) : Color.clear)
                }.buttonStyle(.plain)
                if isReordering {
                    VStack(spacing: 1) {
                        Button(action: onMoveUp) { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(!canMoveUp).help("Sposta in alto")
                        Button(action: onMoveDown) { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).disabled(!canMoveDown).help("Sposta in basso")
                    }
                    .appFont(.caption2)
                }
            }
        }
        .contextMenu { Button("Elimina catalogo", role: .destructive, action: onDelete) }
        .onChange(of: expanded) { value in
            if value {
                store.fetchSidebarChildren(diskID: disk.id, parent: disk.rootPath) { children = $0 }
            }
        }
    }
}

struct SidebarFolderRow: View {
    @EnvironmentObject var store: CatalogStore
    let disk: DiskRecord
    let item: FileRecord
    let depth: CGFloat
    @State private var expanded = false
    @State private var children: [FileRecord] = []

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(children) { child in
                if child.isDirectory {
                    AnyView(SidebarFolderRow(disk: disk, item: child, depth: depth + 1))
                } else {
                    AnyView(Button {
                        store.reveal(child)
                    } label: {
                        Label(child.name, systemImage: "doc").lineLimit(1)
                    }.buttonStyle(.plain).padding(.leading, 18))
                }
            }
        } label: {
            Button {
                store.selectFolder(disk, path: item.path)
            } label: {
                Label(item.name, systemImage: "folder.fill")
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
        }
        .onChange(of: expanded) { value in
            if value {
                store.fetchSidebarChildren(diskID: disk.id, parent: item.path) { children = $0 }
            }
        }
    }
}

struct AppearanceSettings: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var theme: String
    @Binding var tone: String
    @Binding var scale: Double
    private let themes = ["Scuro", "Chiaro", "Classico"]
    private let tones = ["Blu", "Viola", "Verde", "Grafite", "Ardesia"]
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Image(systemName: "gearshape.fill").appFont(.title2)
                Text("Impostazioni").appFont(.title2, weight: .bold)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Aspetto").appFont(.headline)
                Picker("Tema", selection: $theme) {
                    ForEach(themes, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented)
                if theme == "Scuro" {
                    Text("Colore di sfondo").appFont(.subheadline, weight: .medium)
                    Picker("Colore", selection: $tone) {
                        ForEach(tones, id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Dimensione del testo").appFont(.headline)
                    Spacer()
                    Text("\(Int(scale * 100))%").monospacedDigit().foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    Image(systemName: "textformat.size.smaller")
                    Slider(value: $scale, in: 1.0...1.8, step: 0.1)
                    Image(systemName: "textformat.size.larger")
                }
                Text("La modifica si applica all'intera applicazione.").appFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Ripristina") { theme = "Scuro"; tone = "Blu"; scale = 1.35 }
                Button("Chiudi") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24)
    }
}
