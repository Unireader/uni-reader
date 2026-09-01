import Foundation
import SQLite3

// SQLite 要求 bind text/blob 时若不自带析构，需用 TRANSIENT 让其立即拷贝缓冲。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteError: Error, CustomStringConvertible {
    case open(String), prepare(String), step(String), exec(String)
    var description: String {
        switch self {
        case .open(let m): return "SQLite open: \(m)"
        case .prepare(let m): return "SQLite prepare: \(m)"
        case .step(let m): return "SQLite step: \(m)"
        case .exec(let m): return "SQLite exec: \(m)"
        }
    }
}

/// 极简 SQLite 封装（系统 libsqlite3，无第三方依赖）。
///
/// 🔴 **每条语句在实例自己的锁里跑**（2026-09-01 加）。原先这里写着「非线程安全，只在主线程用」，
/// 而离线镜像功能从一开始就在后台线程上用主线程那条连接（建镜像、干跑、合并写入都是）。
/// 后果不是"偶尔读到旧数据"，是**连接自己的 lookaside 分配器被写坏**，然后在之后某一次
/// 毫不相干的 `prepare` 上崩掉——用户实测拿到的就是这个：主线程渲染侧栏右键菜单时
/// `EXC_BAD_ACCESS in sqlite3DbMallocRawNNTyped`，堆栈里连第二个碰 SQLite 的线程都没有
/// （因为写坏它的那次早就跑完了）。
///
/// 锁**按语句粒度**，不覆盖整个事务：覆盖事务的话，合并期间主线程一渲染就得等到 COMMIT，
/// 几秒的界面冻结换掉一个崩溃不划算。代价是别的线程能读到事务里未提交的中间态——
/// 这里的并发读者只有界面显示，认。
///
/// 这不是"可以随便跨线程用"的许可：想同时**写**同一个库仍然违反
/// `WorkspaceRegistry` 那条「同一路径同一实例」红线，锁只保证不炸，保证不了语义。
final class SQLiteDB {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    /// 绑定值类型。
    enum Value {
        case text(String), int(Int64), double(Double), blob(Data), null
    }

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteError.open(msg)
        }
        db = handle
        sqlite3_busy_timeout(db, 3000)
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
    }

    deinit { close() }

    /// **显式**关闭连接（幂等）。关闭后所有读写抛 `.exec("database is closed")`
    /// ——上层一律 `try?`，于是自动退化成 no-op。
    ///
    /// ⚠️ 光有 `deinit` 不够：这个连接的释放最终挂在 SwiftUI 的 `@State` 上，关窗后何时释放没有保证；
    /// 而只要 `library.sqlite` 的 fd 还开着，工作区所在的**可移动硬盘就弹不出去**（Finder 报
    /// 「磁盘正在使用中」），用户只能退出整个 app 才能弹。谁来调见 `WorkspaceRegistry.maybeTeardown`。
    func close() {
        lock.lock(); defer { lock.unlock() }   // 别在另一个线程正跑语句时把句柄拆了
        guard let handle = db else { return }
        db = nil
        sqlite3_close_v2(handle)   // _v2：即便还有未 finalize 的语句也会在其释放后自动收尾
    }

    /// 取仍可用的连接句柄；已关闭则抛错（调用方的 `try?` 会把它变成 no-op）。
    private func handle() throws -> OpaquePointer {
        guard let db else { throw SQLiteError.exec("database is closed") }
        return db
    }

    /// 执行不带参数的语句（DDL / PRAGMA / 多条语句）。
    func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        let db = try handle()
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError.exec(msg)
        }
    }

    /// 写语句（INSERT/UPDATE/DELETE）。
    func run(_ sql: String, _ params: [Value] = []) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError.step(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// 查询：每行返回 列名→值（String / Int64 / Double / Data / NSNull）。
    func query(_ sql: String, _ params: [Value] = []) throws -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [[String: Any]] = []
        let cols = sqlite3_column_count(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<cols {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT:   row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT:    row[name] = String(cString: sqlite3_column_text(stmt, i))
                case SQLITE_BLOB:
                    if let p = sqlite3_column_blob(stmt, i) {
                        row[name] = Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
                    } else { row[name] = Data() }
                default: row[name] = NSNull()
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// 事务包裹；body 抛错则回滚。
    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN;")
        do { try body(); try exec("COMMIT;") }
        catch { try? exec("ROLLBACK;"); throw error }
    }

    private func prepare(_ sql: String, _ params: [Value]) throws -> OpaquePointer? {
        let db = try handle()
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        for (i, v) in params.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .text(let s):   sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .int(let n):    sqlite3_bind_int64(stmt, idx, n)
            case .double(let d): sqlite3_bind_double(stmt, idx, d)
            case .blob(let data):
                if data.isEmpty { sqlite3_bind_zeroblob(stmt, idx, 0) }
                else { data.withUnsafeBytes { _ = sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(data.count), SQLITE_TRANSIENT) } }
            case .null:          sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }
}
