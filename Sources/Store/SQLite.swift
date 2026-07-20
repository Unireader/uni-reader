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
/// **非线程安全**：仅在持有者自己的串行队列/主线程上使用同一实例。
final class SQLiteDB {
    private var db: OpaquePointer?

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

    deinit { if let db { sqlite3_close_v2(db) } }

    /// 执行不带参数的语句（DDL / PRAGMA / 多条语句）。
    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError.exec(msg)
        }
    }

    /// 写语句（INSERT/UPDATE/DELETE）。
    func run(_ sql: String, _ params: [Value] = []) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError.step(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// 查询：每行返回 列名→值（String / Int64 / Double / Data / NSNull）。
    func query(_ sql: String, _ params: [Value] = []) throws -> [[String: Any]] {
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
