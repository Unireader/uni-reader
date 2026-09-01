import Foundation

/// 「这个路径在不在那个卷上」。
///
/// 单拎出来是因为它**只要写错一点就会误伤**：卷要弹出时我们会把它上面开着的工作区当场撤离
/// （关连接、关窗口）。裸 `hasPrefix` 会让 `/Volumes/备份` 把 `/Volumes/备份2` 也算进去
/// —— 用户弹一块盘，另一块盘上的窗口莫名其妙被关掉，而且现场什么线索都没有。
///
/// 纯函数、零依赖，故可单测（`spike/volume-scope-test.swift`）。
enum VolumeScope {

    /// [path] 是否落在卷 [volume] 之内（含 path == volume 本身）。
    ///
    /// 判据是**按路径分量**比，不是按字符串前缀：只有整段目录名相等才算，
    /// 所以 `/Volumes/备份` 不会吃掉 `/Volumes/备份2`。
    static func contains(_ path: String, volume: String) -> Bool {
        let p = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let v = URL(fileURLWithPath: volume).standardizedFileURL.pathComponents
        guard !v.isEmpty, p.count >= v.count else { return false }
        return Array(p.prefix(v.count)) == v
    }
}
