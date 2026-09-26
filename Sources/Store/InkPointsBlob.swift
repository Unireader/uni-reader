import Foundation

/// 笔迹点集的二进制形态（schema v18，`BINARY-INK-PLAN.md §2`）：`note.points` / `board_item.points` 列。
///
/// 格式：`u8 版本 = 1` + n ×（`f32 x` `f32 y` `f32 z`），**小端**；n = (长度 − 1) / 12。
/// 坐标系与 payload 里的 JSON `points` 完全相同（页内归一化 / 画布坐标 / 分页画板的页内坐标），只换编码。
/// **两端契约**：安卓 `local/store/InkPointsBlob.kt` 同一份，跨端向量 `spike/ink-blob-vectors.txt`
/// （`spike/ink-blob-test.swift` 与安卓 `InkPointsBlobTest` 各读一遍，逐字节比）。
/// 点类型写 `SIMD3<Float>`（= App 层的 `InkPoint`）：存储层不依赖 App 层。
enum InkPointsBlob {
    static let version: UInt8 = 1

    static func encode(_ pts: [SIMD3<Float>]) -> Data {
        var out = [UInt8](repeating: 0, count: 1 + pts.count * 12)
        out[0] = version
        out.withUnsafeMutableBytes { raw in
            var o = 1
            for p in pts {
                raw.storeBytes(of: p.x.bitPattern.littleEndian, toByteOffset: o, as: UInt32.self)
                raw.storeBytes(of: p.y.bitPattern.littleEndian, toByteOffset: o + 4, as: UInt32.self)
                raw.storeBytes(of: p.z.bitPattern.littleEndian, toByteOffset: o + 8, as: UInt32.self)
                o += 12
            }
        }
        return Data(out)
    }

    /// 版本不认识 / 长度对不上 / 空 → nil（调用方按「没有二进制」处理，退回 JSON）。
    static func decode(_ d: Data) -> [SIMD3<Float>]? {
        guard d.count >= 1, (d.count - 1) % 12 == 0, d.first == version else { return nil }
        let n = (d.count - 1) / 12
        var pts = [SIMD3<Float>](repeating: .zero, count: n)
        d.withUnsafeBytes { raw in
            var o = 1
            for i in 0..<n {
                let x = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))
                let y = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o + 4, as: UInt32.self))
                let z = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o + 8, as: UInt32.self))
                pts[i] = SIMD3<Float>(Float(bitPattern: x), Float(bitPattern: y), Float(bitPattern: z))
                o += 12
            }
        }
        return pts
    }
}
