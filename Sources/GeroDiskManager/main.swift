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
    private let queue = DispatchQueue(label: "it.gero.diskmanager.database", qos: .userInitiated)

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GeroDiskManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("catalog.sqlite")
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY;", nil, nil, nil)
        sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS disks(
          id TEXT PRIMARY KEY, name TEXT NOT NULL, rootPath TEXT NOT NULL,
          capacity INTEGER NOT NULL DEFAULT 0, itemCount INTEGER NOT NULL DEFAULT 0,
          scannedAt REAL
        );
        CREATE TABLE IF NOT EXISTS files(
          id INTEGER PRIMARY KEY AUTOINCREMENT, diskID TEXT NOT NULL,
          diskName TEXT NOT NULL, name TEXT NOT NULL, path TEXT NOT NULL,
          parentPath TEXT NOT NULL, isDirectory INTEGER NOT NULL
        );
        """, nil, nil, nil)

        func hasColumn(_ name: String) -> Bool {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(disks)", -1, &statement, nil) == SQLITE_OK else { return false }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let raw = sqlite3_column_text(statement, 1),
                   String(cString: raw).caseInsensitiveCompare(name) == .orderedSame {
                    return true
                }
            }
            return false
        }

        if !hasColumn("mediaType") {
            sqlite3_exec(db, "ALTER TABLE disks ADD COLUMN mediaType TEXT NOT NULL DEFAULT 'Non specificato'", nil, nil, nil)
        }
        if !hasColumn("sortOrder") {
            sqlite3_exec(db, "ALTER TABLE disks ADD COLUMN sortOrder INTEGER NOT NULL DEFAULT 0", nil, nil, nil)
        }

        sqlite3_exec(db, """
        CREATE INDEX IF NOT EXISTS idx_files_disk_parent ON files(diskID,parentPath,isDirectory,name COLLATE NOCASE);
        CREATE INDEX IF NOT EXISTS idx_files_name ON files(name COLLATE NOCASE);
        CREATE INDEX IF NOT EXISTS idx_files_path ON files(path);
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
            for sql in ["DELETE FROM files WHERE diskID=?", "DELETE FROM disks WHERE id=?"] {
                var s: OpaquePointer?; sqlite3_prepare_v2(db, sql, -1, &s, nil)
                bind(id.uuidString, to: 1, in: s); sqlite3_step(s); sqlite3_finalize(s)
            }
        }
    }

    func replaceFiles(disk: DiskRecord, records: [FileRecordInput]) {
        run {
            sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
            var del: OpaquePointer?; sqlite3_prepare_v2(db, "DELETE FROM files WHERE diskID=?", -1, &del, nil)
            bind(disk.id.uuidString, to: 1, in: del); sqlite3_step(del); sqlite3_finalize(del)
            var ins: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO files(diskID,diskName,name,path,parentPath,isDirectory) VALUES(?,?,?,?,?,?)", -1, &ins, nil)
            for r in records {
                sqlite3_reset(ins); sqlite3_clear_bindings(ins)
                bind(disk.id.uuidString, to: 1, in: ins); bind(disk.name, to: 2, in: ins)
                bind(r.name, to: 3, in: ins); bind(r.path, to: 4, in: ins); bind(r.parent, to: 5, in: ins)
                sqlite3_bind_int(ins, 6, r.isDirectory ? 1 : 0)
                sqlite3_step(ins)
            }
            sqlite3_finalize(ins)
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }
    }

    func insertBatch(disk: DiskRecord, records: [FileRecordInput]) {
        run {
            sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO files(diskID,diskName,name,path,parentPath,isDirectory) VALUES(?,?,?,?,?,?)", -1, &s, nil)
            for r in records {
                sqlite3_reset(s); sqlite3_clear_bindings(s)
                bind(disk.id.uuidString, to: 1, in: s); bind(disk.name, to: 2, in: s)
                bind(r.name, to: 3, in: s); bind(r.path, to: 4, in: s); bind(r.parent, to: 5, in: s)
                sqlite3_bind_int(s, 6, r.isDirectory ? 1 : 0); sqlite3_step(s)
            }
            sqlite3_finalize(s); sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }
    }

    func children(diskID: UUID, parent: String) -> [FileRecord] {
        run {
            var out: [FileRecord] = []; var s: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT id,diskID,diskName,name,path,isDirectory FROM files WHERE diskID=? AND parentPath=? ORDER BY isDirectory DESC,name COLLATE NOCASE LIMIT 5000", -1, &s, nil)
            defer { sqlite3_finalize(s) }
            bind(diskID.uuidString, to: 1, in: s); bind(parent, to: 2, in: s)
            while sqlite3_step(s) == SQLITE_ROW { out.append(readRecord(s)) }
            return out
        }
    }

    func search(_ query: String, scope: String, mediaType: String, matchMode: String) -> [FileRecord] {
        run {
            var out: [FileRecord] = []; var s: OpaquePointer?
            let typeFilter: String
            switch scope {
            case "Cartelle": typeFilter = " AND isDirectory=1"
            case "File": typeFilter = " AND isDirectory=0"
            default: typeFilter = ""
            }
            let condition = matchMode == "Nome esatto" ? "files.name = ? COLLATE NOCASE" : "(files.name LIKE ? ESCAPE '\\' OR files.path LIKE ? ESCAPE '\\')"
            let sql = "SELECT files.id,files.diskID,files.diskName,files.name,files.path,files.isDirectory FROM files JOIN disks ON disks.id=files.diskID WHERE " + condition + typeFilter + " AND (?='Tutti' OR disks.mediaType=?) ORDER BY files.isDirectory DESC,files.name COLLATE NOCASE LIMIT 1000"
            sqlite3_prepare_v2(db, sql, -1, &s, nil)
            defer { sqlite3_finalize(s) }
            let escaped = query.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            let q = matchMode == "Nome esatto" ? query : "%" + escaped + "%"
            bind(q, to: 1, in: s)
            if matchMode != "Nome esatto" { bind(q, to: 2, in: s) }
            let mediaIndex: Int32 = matchMode == "Nome esatto" ? 2 : 3
            bind(mediaType, to: mediaIndex, in: s); bind(mediaType, to: mediaIndex + 1, in: s)
            while sqlite3_step(s) == SQLITE_ROW { out.append(readRecord(s)) }
            return out
        }
    }

    func removeDiskFilesOnly(_ id: UUID) {
        run {
            var s: OpaquePointer?
            sqlite3_prepare_v2(db, "DELETE FROM files WHERE diskID=?", -1, &s, nil)
            bind(id.uuidString, to: 1, in: s)
            sqlite3_step(s)
            sqlite3_finalize(s)
        }
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
    let name: String
    let path: String
    let parent: String
    let isDirectory: Bool
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
    @Published var visibleChildren: [FileRecord] = []
    @Published var currentFolder: String?
    @Published var scanning = false
    @Published var progress = 0
    @Published var status = "Aggiungi un disco per iniziare"
    private let database = CatalogDB()
    private var searchTask: Task<Void, Never>?

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
            var batch: [FileRecordInput] = []; var total = 0
            db.removeDiskFilesOnly(disk.id)
            while let url = enumerator.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isHidden == true { continue }
                batch.append(FileRecordInput(name: url.lastPathComponent, path: url.path,
                    parent: url.deletingLastPathComponent().path, isDirectory: values?.isDirectory ?? false))
                if batch.count >= 750 {
                    db.insertBatch(disk: disk, records: batch); total += batch.count; batch.removeAll(keepingCapacity: true)
                    let count = total
                    await MainActor.run { self.progress = count; self.status = "Catalogati \(count.formatted()) elementi…" }
                }
            }
            if !batch.isEmpty { db.insertBatch(disk: disk, records: batch); total += batch.count }
            await MainActor.run {
                if let i = self.disks.firstIndex(where: { $0.id == disk.id }) {
                    self.disks[i].itemCount = total; self.disks[i].scannedAt = Date()
                    db.upsert(self.disks[i])
                }
                self.scanning = false; self.status = "Catalogazione completata: \(total.formatted()) elementi"
                self.loadChildren(); self.scheduleSearch()
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
        searchTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = []; return }
        let db = database
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            let scope = searchScope
            let mediaType = searchMediaType
            let matchMode = searchMatchMode
            let rows = await Task.detached { db.search(q, scope: scope, mediaType: mediaType, matchMode: matchMode) }.value
            if !Task.isCancelled { results = rows }
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

struct MainView: View {
    @EnvironmentObject var store: CatalogStore
    @AppStorage("appearanceTheme") private var appearanceTheme = "Scuro"
    @AppStorage("backgroundTone") private var backgroundTone = "Blu"
    @AppStorage("textScale") private var textScale = 1.0
    @State private var showingSettings = false
    @State private var isReordering = false
    @State private var diskPendingDeletion: DiskRecord?
    private var colorScheme: ColorScheme? { appearanceTheme == "Chiaro" ? .light : .dark }
    private var dynamicType: DynamicTypeSize {
        // Una dimensione di base più leggibile in tutta l'interfaccia.
        // Il cursore nelle impostazioni continua a regolare la dimensione complessiva.
        switch textScale {
        case ..<0.85: return .medium
        case ..<1.0: return .large
        case ..<1.15: return .xLarge
        case ..<1.3: return .xxLarge
        default: return .xxxLarge
        }
    }
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
                    Text("CATALOGHI").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
                        Text("Gero Disk Manager").font(.largeTitle.bold())
                        Text("Un'unica ricerca in tutti i tuoi dischi, anche offline.").foregroundStyle(.secondary)
                    }
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape").font(.title2)
                    }.buttonStyle(.borderless).help("Impostazioni")
                    Spacer()
                    if store.scanning {
                        VStack(alignment: .trailing) {
                            ProgressView()
                            Text("\(store.progress.formatted()) voci").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }.padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 20)

                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Cerca un file o una cartella…", text: $store.searchText).textFieldStyle(.plain).font(.title3)
                    if !store.searchText.isEmpty {
                        Button { store.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                    }
                }
                .padding(14).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 28)

                if !store.searchText.isEmpty {
                    HStack(spacing: 12) {
                        Text("Mostra:").font(.caption).foregroundStyle(.secondary)
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
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if let disk = store.selectedDiskRecord, !store.showingHome {
                        Button("Aggiorna catalogo") { store.scan(disk) }.disabled(store.scanning || !disk.isAvailable)
                    }
                }.padding(.horizontal, 30).padding(.top, 24).padding(.bottom, 8)

                if !store.searchText.isEmpty {
                    List(store.results) { item in resultRow(item) }
                } else if store.showingHome || store.selectedDiskRecord == nil {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                            ForEach(store.disks) { disk in
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Image(systemName: disk.isAvailable ? "externaldrive.fill" : "externaldrive")
                                            .font(.title2).foregroundStyle(disk.isAvailable ? .green : .secondary)
                                        Spacer()
                                        Circle().fill(disk.isAvailable ? .green : .gray).frame(width: 8, height: 8)
                                    }
                                    Text(disk.name).font(.headline).lineLimit(1)
                                    Text("\(disk.itemCount.formatted()) elementi").font(.subheadline).foregroundStyle(.secondary)
                                    Text(disk.isAvailable ? "Collegato" : "Offline").font(.caption).foregroundStyle(.secondary)
                                    Picker("Supporto", selection: Binding(
                                        get: { store.disks.first(where: { $0.id == disk.id })?.mediaType ?? "Non specificato" },
                                        set: { store.setMediaType($0, for: disk) }
                                    )) {
                                        ForEach(["Non specificato", "HDD", "SSD", "USB", "Scheda SD", "Altro"], id: \.self) { Text($0).tag($0) }
                                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                                    HStack {
                                        Button("Apri catalogo") { store.select(disk) }
                                        Spacer()
                                        Button { store.scan(disk) } label: { Image(systemName: "arrow.clockwise") }
                                            .disabled(!disk.isAvailable || store.scanning)
                                    }
                                }
                                .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
                                .contextMenu { Button("Rimuovi catalogo") { store.remove(disk) } }
                            }
                        }.padding(28)
                    }
                } else if let disk = store.selectedDiskRecord {
                    HStack {
                        Button(action: store.goUp) { Image(systemName: "arrow.up") }
                            .disabled(store.currentFolder == disk.rootPath)
                        Text(store.currentFolder == disk.rootPath ? disk.name : URL(fileURLWithPath: store.currentFolder ?? disk.rootPath).lastPathComponent)
                            .font(.headline)
                        Spacer()
                        Text("\(disk.itemCount.formatted()) elementi indicizzati").font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 28).padding(.top, 12)

                    List(store.visibleChildren) { item in
                        HStack {
                            Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                                .foregroundStyle(item.isDirectory ? .blue : .secondary)
                            Text(item.name)
                            Spacer()
                            if !item.isDirectory {
                                Text(item.path.components(separatedBy: "/").dropLast().joined(separator: "/"))
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
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
                    Text(store.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(store.disks.count) dischi").font(.caption).foregroundStyle(.secondary)
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
        .environment(\.dynamicTypeSize, dynamicType)
        .background(canvas)
    }

    @ViewBuilder private func resultRow(_ item: FileRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(item.isDirectory ? .blue : .secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.body.weight(.medium))
                Text(item.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(item.diskName).font(.caption.weight(.semibold))
                Text(FileManager.default.fileExists(atPath: item.path) ? "Collegato" : "Offline")
                    .font(.caption2).foregroundStyle(.secondary)
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
                                .font(.caption2).foregroundStyle(.secondary)
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
                    .font(.caption2)
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
                Image(systemName: "gearshape.fill").font(.title2)
                Text("Impostazioni").font(.title2.bold())
                Spacer()
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Aspetto").font(.headline)
                Picker("Tema", selection: $theme) {
                    ForEach(themes, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented)
                if theme == "Scuro" {
                    Text("Colore di sfondo").font(.subheadline.weight(.medium))
                    Picker("Colore", selection: $tone) {
                        ForEach(tones, id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Dimensione del testo").font(.headline)
                    Spacer()
                    Text("\(Int(scale * 100))%").monospacedDigit().foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    Image(systemName: "textformat.size.smaller")
                    Slider(value: $scale, in: 0.8...1.6, step: 0.1)
                    Image(systemName: "textformat.size.larger")
                }
                Text("La modifica si applica all'intera applicazione.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Ripristina") { theme = "Scuro"; tone = "Blu"; scale = 1.0 }
                Button("Chiudi") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24)
    }
}
