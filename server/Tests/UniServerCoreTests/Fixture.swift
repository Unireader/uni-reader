import Foundation
@testable import UniServerCore

/// 测试用的临时环境：一个服务器数据目录 + 若干「设备」（各自一个本地工作区 / 缓存）。
final class Fixture {
    let root: URL
    let paths: ServerPaths
    let host: WorkspaceHost

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("unireader-server-test-\(UUID().uuidString)", isDirectory: true)
        paths = ServerPaths(root: root.appendingPathComponent("data", isDirectory: true))
        host = try WorkspaceHost(paths: paths)
    }

    deinit {
        host.closeAll()
        try? FileManager.default.removeItem(at: root)
    }

    /// 一台设备：本地工作区文件夹 + 它的库。
    final class Device {
        let name: String
        let folder: URL
        let store: LibraryStore
        init(name: String, folder: URL, store: LibraryStore) { self.name = name; self.folder = folder; self.store = store }
        deinit { store.close() }

        func db<T>(_ body: (SQLiteDB) throws -> T) rethrows -> T { try store.withMirrorDB(body) }

        /// 一轮同步（拉取每页只取 [pageSize] 条，专门把分页的边界踩出来）。
        @discardableResult
        func sync(_ ws: HostedWorkspace, pageSize: Int = 3) throws -> SyncClient.RoundReport {
            try db { db in
                try SyncClient.round(db, folder: folder,
                                     push: { try ws.push($0, deviceName: self.name) },
                                     pull: { try ws.pullRows(since: $0, limit: pageSize) })
            }
        }

        func specState() throws -> [String: [String: String]] { try db { try SyncRows.specState($0) } }
    }

    /// 新建一个本地工作区。
    func makeDevice(_ name: String) throws -> Device {
        let folder = root.appendingPathComponent("\(name).unrd", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try LibraryStore(workspaceFolder: folder)
        try store.setWorkspaceName("测试工作区")
        try store.ensureWorkspaceId()
        return Device(name: name, folder: folder, store: store)
    }

    /// 把设备上的本地工作区上传到服务器（库快照 + `PDFs/` + `Images/`），之后这份本地工作区就是它的缓存。
    func upload(_ d: Device) throws -> HostedWorkspace {
        let up = try host.newUploadFolder()
        d.store.checkpointTruncate()
        try d.store.vacuumInto(up.appendingPathComponent("UniReader/library.sqlite").path)
        let fm = FileManager.default
        for sub in ["PDFs", "Images"] {
            let src = d.folder.appendingPathComponent(sub)
            if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: up.appendingPathComponent(sub)) }
        }
        let ws = try host.install(uploaded: up)
        try d.db { try SyncClient.resetBase($0, folder: d.folder, pulledRev: ws.head) }
        return ws
    }

    /// 另一台设备「从服务器打开」：下载快照建缓存。
    func cache(_ ws: HostedWorkspace, as name: String) throws -> Device {
        let folder = root.appendingPathComponent("\(name).unrd", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("UniReader"), withIntermediateDirectories: true)
        let head = try ws.exportSnapshot(to: folder.appendingPathComponent("UniReader/library.sqlite"))
        let store = try LibraryStore(workspaceFolder: folder)
        let d = Device(name: name, folder: folder, store: store)
        try d.db { try SyncClient.resetBase($0, folder: folder, pulledRev: head) }
        return d
    }

    func serverState(_ ws: HostedWorkspace) throws -> [String: [String: String]] {
        try ws.store.withMirrorDB { try SyncRows.specState($0) }
    }
}

// MARK: - 造数据

enum Seed {
    static func t(_ minute: Int) -> String { String(format: "2026-10-29T10:%02d:00.000Z", minute) }

    static func addDoc(_ d: Fixture.Device, _ id: String, title: String) throws {
        try d.db { try $0.run("INSERT INTO document(id,title,page_count,added_at,last_opened_at) VALUES(?,?,10,?,?)",
                              [.text(id), .text(title), .text(t(0)), .text(t(0))]) }
    }

    static func renameDoc(_ d: Fixture.Device, _ id: String, title: String) throws {
        try d.db { try $0.run("UPDATE document SET title=? WHERE id=?", [.text(title), .text(id)]) }
    }

    static func addNote(_ d: Fixture.Device, _ id: String, doc: String, text: String, at minute: Int) throws {
        try d.db { try $0.run("""
        INSERT INTO note(id,document_id,kind,page,anchor_x,anchor_y,anchor_w,anchor_h,payload,created_at,updated_at)
        VALUES(?,?,0,0,0.1,0.2,0,0,?,?,?)
        """, [.text(id), .text(doc), .blob(payload(text)), .text(t(minute)), .text(t(minute))]) }
    }

    static func editNote(_ d: Fixture.Device, _ id: String, text: String, at minute: Int) throws {
        try d.db { try $0.run("UPDATE note SET payload=?, updated_at=? WHERE id=?",
                              [.blob(payload(text)), .text(t(minute)), .text(id)]) }
    }

    static func deleteRow(_ d: Fixture.Device, _ table: String, _ id: String) throws {
        try d.db { try $0.run("DELETE FROM \(table) WHERE id=?", [.text(id)]) }
    }

    static func noteText(_ d: Fixture.Device, _ id: String) throws -> String? {
        try d.db { db in
            guard let p = try db.query("SELECT payload FROM note WHERE id=?", [.text(id)]).first?["payload"] as? Data
            else { return nil }
            return (try JSONSerialization.jsonObject(with: p) as? [String: String])?["text"]
        }
    }

    static func payload(_ text: String) -> Data { try! JSONSerialization.data(withJSONObject: ["text": text]) }

    /// 一份假 PDF（内容随意，服务器只认哈希）。返回内容哈希。
    @discardableResult
    static func addPDF(_ d: Fixture.Device, doc: String, bytes: String) throws -> String {
        let data = Data(bytes.utf8)
        let hash = ServerCrypto.sha256Hex(data)
        let rel = "PDFs/\(UUID().uuidString).pdf"
        let url = d.folder.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try d.db { db in
            let vid = UUID().uuidString
            try db.run("INSERT INTO variant(id,document_id,content_hash,page_count,added_at) VALUES(?,?,?,10,?)",
                       [.text(vid), .text(doc), .text(hash), .text(t(0))])
            try db.run("INSERT INTO location(id,variant_id,path,in_workspace) VALUES(?,?,?,1)",
                       [.text(UUID().uuidString), .text(vid), .text(rel)])
        }
        return hash
    }
}
