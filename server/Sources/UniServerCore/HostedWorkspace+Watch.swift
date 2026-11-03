import Foundation

/// 变更通知（长轮询，方案 `SERVER-MODE-PLAN.md §4.3` S4）：设备开着工作区时挂一个 `GET wait`，
/// 工作区里有任何改动（别的设备推送、网页写入、笔记文件、改名）服务器立刻回答，设备据此马上去拉。
///
/// 为什么不是方案原来写的 WebSocket `/events`：那要新增 `hummingbird-websocket` 依赖（得用户拉取），
/// 而长轮询就是普通 HTTP——过反向代理（Caddy）、安卓 OkHttp、网页 `fetch` 都零成本，延迟同样是即时的。
extension HostedWorkspace {

    /// 工作区现在的两个修订号：库里的行 / 笔记文件。
    public struct ChangeState: Equatable, Sendable {
        public var rows: UInt64
        public var notes: UInt64
        public init(rows: UInt64, notes: UInt64) { self.rows = rows; self.notes = notes }
    }

    /// 当前的修订号（不碰库、不等工作区的锁：改动时 `publishChange` 会更新这份缓存）。
    public var changeState: ChangeState { changeSignal.state }

    /// 等到修订号和 [rows] / [notes] 不一样（任何一个变了，包括变小：服务器数据被还原过）或超时，返回当时的修订号。
    /// 已经不一样就立刻返回。可取消（请求断了就不再等）。
    public func waitForChange(rows: UInt64, notes: UInt64, timeout: TimeInterval) async -> ChangeState {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            let gen = changeSignal.generation
            let s = changeSignal.state
            if s.rows != rows || s.notes != notes { return s }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 || Task.isCancelled { return s }
            await changeSignal.wait(after: gen, timeout: remaining)
        }
    }

    /// 记下新的修订号并叫醒所有在等的。🔴 在工作区的锁里、改完库之后调（`db` 就是正在用的那条连接）。
    func publishChange(_ db: SQLiteDB) {
        changeSignal.publish(ChangeState(rows: Self.head(db), notes: Self.noteHead(db)))
    }
}

final class ChangeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var _state: HostedWorkspace.ChangeState
    private var _generation: UInt64 = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(_ state: HostedWorkspace.ChangeState) { _state = state }

    var state: HostedWorkspace.ChangeState { lock.withLock { _state } }
    var generation: UInt64 { lock.withLock { _generation } }

    func publish(_ s: HostedWorkspace.ChangeState) {
        let toWake: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard s != _state else { return [] }
            _state = s
            _generation &+= 1
            let all = Array(waiters.values)
            waiters.removeAll()
            return all
        }
        for c in toWake { c.resume() }
    }

    /// 等到 `generation` 不再是 [gen]（有新的发布），或超时 / 被取消。登记之前就已经变了会立刻返回——不会丢通知。
    func wait(after gen: UInt64, timeout: TimeInterval) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let registered: Bool = lock.withLock {
                    if _generation != gen || Task.isCancelled { return false }
                    waiters[id] = c
                    return true
                }
                guard registered else { c.resume(); return }
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    self?.expire(id)
                }
            }
        } onCancel: { [weak self] in self?.expire(id) }
    }

    private func expire(_ id: UUID) {
        let c = lock.withLock { waiters.removeValue(forKey: id) }
        c?.resume()
    }
}
