import Foundation

/// **阅读进度排查通道**（`[PROG]` 前缀，2026-09-21 加，起因：用户报「有时候阅读进度丢了，
/// 跑到不知道什么地方去」——这种偶发、事后才发现的问题没法靠复现调试，只能先把现场记下来）。
///
/// 开关口径同 `PadLog` / `ZoomProbe` / `wsLog`——**文件在不在就是开关**：
/// ```
/// touch ~/Library/Logs/UniReader-progress.log    # 开启
/// rm    ~/Library/Logs/UniReader-progress.log    # 关闭
/// ```
///
/// 记的是「谁在什么时候，把哪篇文档的进度写成了什么 / 读成了什么」，覆盖全部会改动
/// `document.read_page/read_frac/read_zoom/read_hfrac` 的路径：
/// - `存`   —— `DocTabModel.saveProgress`（翻页 / 滚动节流 / 缩放 / 切走 / 关闭 / 对齐切换 / 尾随补存），
///            带**这次用的锚点是哪来的**（origin + seq），以及「锚点比本次装载还旧」的告警；
/// - `跳过` —— 两条守卫（没有 documentId / 标签还没装载）拦下的保存，历史上的进度自毁就出在这里；
/// - `落库`/`读库` —— 真正打到 SQLite 的那一下（后台队列，可能与关窗竞争）；
/// - `恢复`/`切回` —— 开文档 / 切标签时摆出来的位置；
/// - `锚点` —— 所有非本机滚动的锚点（restore / pad / toc / search / link / mcp），
///            本机滚动只记**跳变**（一次跳过大半页以上，正常滚动不会这样）；
/// - `首帧`/`重排`/`换基准` —— 阅读区落位与宽度变化时的重定位（位置在这里算错就会"跑飞"）；
/// - `镜像` —— 离线镜像合并改写了哪几篇的进度（安卓那侧读到哪，合并回来就是哪）。
///
/// 关着时热路径上只剩一次「每秒最多一遍」的 `fileExists`；写盘甩到独立队列，不占主线程。
enum ProgressLog {
    static let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/UniReader-progress.log")

    private static let queue = DispatchQueue(label: "com.xvan.UniReader.progresslog", qos: .utility)
    private static var handle: FileHandle?      // 只在 queue 上碰
    private static var checkedAt: CFAbsoluteTime = 0
    private static var isOn = false
    private static let gate = NSLock()          // 调用方不止主线程（后台落库队列、镜像合并线程）

    /// 探盘节流到 1s 一次（开关是给人用的，秒级生效足够）。
    static var enabled: Bool {
        gate.lock(); defer { gate.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        if now - checkedAt > 1 {
            checkedAt = now
            let on = FileManager.default.fileExists(atPath: url.path)
            if on != isOn {
                isOn = on
                queue.async { handle = nil }   // 关掉/被 rm 过 → 下次写重新开句柄
            }
        }
        return isOn
    }

    static func log(_ msg: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "\(Date.now.formatted(date: .omitted, time: .standard)) [PROG] \(msg())\n"
        queue.async {
            if handle == nil {
                handle = try? FileHandle(forWritingTo: url)
                _ = try? handle?.seekToEnd()
            }
            guard let h = handle, let d = line.data(using: .utf8) else { return }
            try? h.write(contentsOf: d)
        }
    }

    // MARK: - 统一格式（日志靠肉眼扫，格式必须一眼对得上）

    /// 位置：`p12+0.34`（页码对人 1 起，与界面一致；内部 0 起的值传进来即可）。
    static func pos(_ page: Int, _ frac: Double) -> String {
        String(format: "p%d+%.3f", page + 1, frac)
    }

    /// 文档：`3f9a21c8「王道计组」`。id 取前 8 位够区分，全写占满一行。
    static func doc(_ id: String?, _ title: String) -> String {
        let short = id.map { String($0.prefix(8)) } ?? "无"
        return "\(short)「\(title)」"
    }
}
