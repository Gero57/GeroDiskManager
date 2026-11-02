import SwiftUI
import AppKit

struct DiskRecord: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var volumeName: String
    var rootPath: String
    var volumeURL: URL
    var capacity: Int64
    var itemCount: Int
    var scannedAt: Date
    var isAvailable: Bool { FileManager.default.fileExists(atPath: rootPath) }
}

struct FileRecord: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var diskID: UUID
    var diskName: String
    var name: String
    var path: String
    var isDirectory: Bool
}

@MainActor
final class CatalogStore: ObservableObject {
    @Published var disks: [DiskRecord] = []
    @Published var files: [FileRecord] = []
    @Published var selectedDisk: UUID?
    @Published var searchText = ""
    @Published var scanning = false
    @Published var status = "Aggiungi un disco per iniziare"

    private var storageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GeroDiskManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("catalog.json")
    }

    init() { load() }

    var results: [FileRecord] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return files.filter {
            $0.name.localizedCaseInsensitiveContains(q) ||
            $0.path.localizedCaseInsensitiveContains(q)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var selectedDiskRecord: DiskRecord? {
        disks.first { $0.id == selectedDisk }
    }

    var selectedTree: [TreeEntry] {
        guard let disk = selectedDiskRecord else { return [] }
        let records = files.filter { $0.diskID == disk.id }
        func makeChildren(parentPath: String) -> [TreeEntry] {
            let direct = records.filter { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == parentPath }
            return direct.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }.map { record in
                TreeEntry(id: record.id.uuidString, name: record.name, path: record.path,
                          isDirectory: record.isDirectory,
                          descendants: record.isDirectory ? makeChildren(parentPath: record.path) : [])
            }
        }
        return makeChildren(parentPath: disk.rootPath)
    }

    func addDisk() {
        let panel = NSOpenPanel()
        panel.title = "Seleziona la radice del disco da catalogare"
        panel.message = "Scegli il volume o una cartella. I file originali non verranno modificati."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let root = url.standardizedFileURL
        if disks.contains(where: { $0.rootPath == root.path }) {
            status = "Questo disco è già presente nel catalogo"
            return
        }
        let values = try? root.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey])
        let disk = DiskRecord(name: values?.volumeName ?? root.lastPathComponent,
                              volumeName: values?.volumeName ?? root.lastPathComponent,
                              rootPath: root.path, volumeURL: root,
                              capacity: Int64(values?.volumeTotalCapacity ?? 0),
                              itemCount: 0, scannedAt: Date())
        disks.append(disk)
        selectedDisk = disk.id
        scan(disk)
    }

    func scan(_ disk: DiskRecord) {
        guard !scanning else { return }
        scanning = true
        status = "Catalogazione di \(disk.name)…"
        let root = URL(fileURLWithPath: disk.rootPath)
        let diskID = disk.id
        let diskName = disk.name
        Task.detached(priority: .userInitiated) {
            var found: [FileRecord] = []
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
            if let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                while let url = enumerator.nextObject() as? URL {
                    let v = try? url.resourceValues(forKeys: Set(keys))
                    if v?.isHidden == true { continue }
                    found.append(FileRecord(diskID: diskID, diskName: diskName,
                                            name: url.lastPathComponent,
                                            path: url.path,
                                            isDirectory: v?.isDirectory ?? false))
                }
            }
            await MainActor.run {
                self.files.removeAll { $0.diskID == diskID }
                self.files.append(contentsOf: found)
                if let i = self.disks.firstIndex(where: { $0.id == diskID }) {
                    self.disks[i].itemCount = found.count
                    self.disks[i].scannedAt = Date()
                }
                self.scanning = false
                self.status = "Catalogazione completata: \(found.count.formatted()) elementi"
                self.save()
            }
        }
    }

    func remove(_ disk: DiskRecord) {
        disks.removeAll { $0.id == disk.id }
        files.removeAll { $0.diskID == disk.id }
        if selectedDisk == disk.id { selectedDisk = nil }
        save()
    }

    func reveal(_ item: FileRecord) {
        guard FileManager.default.fileExists(atPath: item.path) else {
            status = "Disco non collegato: \(item.diskName)"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    func save() {
        let data = try? JSONEncoder().encode(Archive(disks: disks, files: files))
        try? data?.write(to: storageURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let archive = try? JSONDecoder().decode(Archive.self, from: data) else { return }
        disks = archive.disks
        files = archive.files
    }
}

struct Archive: Codable {
    var disks: [DiskRecord]
    var files: [FileRecord]
}

struct TreeEntry: Identifiable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    let descendants: [TreeEntry]
    var children: [TreeEntry]? { descendants.isEmpty ? nil : descendants }
}


@main
struct GeroDiskManagerApp: App {
    @StateObject private var store = CatalogStore()
    var body: some Scene {
        WindowGroup {
            MainView().environmentObject(store)
                .frame(minWidth: 900, minHeight: 600)
        }
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
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 12) {
                HStack {
                    Text("I TUOI DISCHI").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: store.addDisk) { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("Aggiungi disco")
                }.padding(.horizontal, 14).padding(.top, 16)
                List(selection: $store.selectedDisk) {
                    ForEach(store.disks) { disk in
                        HStack(spacing: 10) {
                            Image(systemName: disk.isAvailable ? "externaldrive.fill" : "externaldrive")
                                .foregroundStyle(disk.isAvailable ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(disk.name).lineLimit(1)
                                Text("\(disk.itemCount.formatted()) elementi · \(disk.isAvailable ? "Collegato" : "Offline")")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }.tag(disk.id as UUID?)
                    }
                }
                Button(action: store.addDisk) {
                    Label("Aggiungi disco", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).padding(12)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Gero Disk Manager").font(.largeTitle.bold())
                        Text("Cerca file in tutti i tuoi dischi, anche quando sono offline.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.scanning { ProgressView().controlSize(.small) }
                }.padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 20)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Cerca un file o una cartella…", text: $store.searchText)
                        .textFieldStyle(.plain).font(.title3)
                    if !store.searchText.isEmpty {
                        Button { store.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(14).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 28)
                HStack {
                    Text(store.searchText.isEmpty ? "CATALOGHI" : "\(store.results.count) RISULTATI")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if let id = store.selectedDisk, let disk = store.disks.first(where: { $0.id == id }) {
                        Button("Aggiorna catalogo") { store.scan(disk) }.disabled(store.scanning)
                    }
                }.padding(.horizontal, 30).padding(.top, 24).padding(.bottom, 8)
                if !store.searchText.isEmpty {
                    List(store.results) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                                .foregroundStyle(item.isDirectory ? .blue : .secondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name).font(.body.weight(.medium))
                                Text(item.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(item.diskName).font(.caption.weight(.semibold))
                                Text(FileManager.default.fileExists(atPath: item.path) ? "Collegato" : "Offline")
                                    .font(.caption2).foregroundStyle(FileManager.default.fileExists(atPath: item.path) ? .green : .secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { store.reveal(item) }
                        .contextMenu { Button("Mostra nel Finder") { store.reveal(item) } }
                    }
                    .listStyle(.inset)
                } else if let disk = store.selectedDiskRecord {
                    HStack {
                        Label(disk.name, systemImage: "externaldrive.fill").font(.headline)
                        Spacer()
                        Text("\(store.selectedTree.count) elementi al primo livello")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 28).padding(.top, 14)
                    if store.selectedTree.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "folder").font(.system(size: 34)).foregroundStyle(.secondary)
                            Text("Catalogo vuoto").font(.headline)
                            Text("Aggiorna il catalogo per leggere la struttura del disco.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            OutlineGroup(store.selectedTree, children: \.children) { node in
                                HStack(spacing: 8) {
                                    Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                                        .foregroundStyle(node.isDirectory ? .blue : .secondary)
                                    Text(node.name)
                                    Spacer()
                                    if !FileManager.default.fileExists(atPath: node.path) {
                                        Text("Offline").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    let record = FileRecord(diskID: disk.id, diskName: disk.name,
                                        name: node.name, path: node.path, isDirectory: node.isDirectory)
                                    store.reveal(record)
                                }
                                .contextMenu {
                                    Button("Mostra nel Finder") {
                                        let record = FileRecord(diskID: disk.id, diskName: disk.name,
                                            name: node.name, path: node.path, isDirectory: node.isDirectory)
                                        store.reveal(record)
                                    }
                                }
                            }
                        }
                        .listStyle(.inset)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                            ForEach(store.disks) { disk in DiskCard(disk: disk) }
                        }.padding(28)
                    }
                }
                HStack {
                    Text(store.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(store.disks.count) dischi").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
            }
        }
    }
}

struct DiskCard: View {
    @EnvironmentObject var store: CatalogStore
    let disk: DiskRecord
    var body: some View {
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
            HStack {
                Button("Apri catalogo") { store.selectedDisk = disk.id; store.searchText = "" }
                Spacer()
                Button { store.scan(disk) } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(!disk.isAvailable || store.scanning).help("Aggiorna")
            }
        }
        .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
        .contextMenu {
            Button("Rimuovi catalogo") { store.remove(disk) }
        }
    }
}
