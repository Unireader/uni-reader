// Real-ESRGAN（Core ML）样张：分块推理 → 拼回整页。2026-09-23 调研用，结论见 SCAN-ENHANCE-PLAN.md §3。
// 编译：swiftc -O spike/esrgan-look.swift -o /tmp/esrgan-look
// 用法：esrgan-look <模型.mlpackage> <模型倍数 2|4> <输入.png> <输出.png> [输出倍数，默认 2]
// 模型：hanxiao/real-esrgan-coreml 的 v1.0.0 release（RealESRGAN_<x2plus|general|anime_6B>_522_fp16.zip，解压即 .mlpackage）
// 分块：模型输入固定 522×522；每块四周多取 margin 像素的上下文（页外按边缘像素延伸），
// 只把中间那块写回——相邻块的重叠部分直接丢掉，不做融合，所以没有接缝。
import AppKit
import CoreImage
import CoreML

let a = CommandLine.arguments
guard a.count >= 5 else { print("用法见文件头"); exit(1) }
let modelURL = URL(fileURLWithPath: a[1])
let modelScale = Int(a[2])!
let outScale = a.count > 5 ? Int(a[5])! : 2
let tileSize = 522, margin = 24, core = tileSize - 2 * margin

// MARK: 读图 → 平面 RGB Float（0…1）
let src = NSImage(contentsOf: URL(fileURLWithPath: a[3]))!
    .cgImage(forProposedRect: nil, context: nil, hints: nil)!
let W = src.width, H = src.height
var rgba = [UInt8](repeating: 0, count: W * H * 4)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
CGContext(data: &rgba, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: space,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    .draw(src, in: CGRect(x: 0, y: 0, width: W, height: H))

// MARK: 模型
var t0 = Date()
let compiled = try! MLModel.compileModel(at: modelURL)
let cfg = MLModelConfiguration()
cfg.computeUnits = .all
let model = try! MLModel(contentsOf: compiled, configuration: cfg)
let inName = model.modelDescription.inputDescriptionsByName.keys.first!
let inType = model.modelDescription.inputDescriptionsByName[inName]!.multiArrayConstraint!.dataType
let outName = model.modelDescription.outputDescriptionsByName.keys.first!
print(String(format: "编译 + 加载 %.2fs  输入 %@(%@)  输出 %@", Date().timeIntervalSince(t0),
             inName, inType == .float16 ? "fp16" : "fp32", outName))

// MARK: 分块推理
let S = modelScale
let OW = W * S, OH = H * S
var out = [Float](repeating: 1, count: OW * OH * 3)   // 平面存放：c * OW*OH + y*OW + x
let input = try! MLMultiArray(shape: [1, 3, NSNumber(value: tileSize), NSNumber(value: tileSize)], dataType: inType)
let plane = tileSize * tileSize

t0 = Date()
var tiles = 0
var cy = 0
while cy < H {
    var cx = 0
    while cx < W {
        let x0 = cx - margin, y0 = cy - margin
        // 填输入（页外夹到边缘）
        for c in 0..<3 {
            for y in 0..<tileSize {
                let sy = min(max(y0 + y, 0), H - 1)
                for x in 0..<tileSize {
                    let sx = min(max(x0 + x, 0), W - 1)
                    let v = Float(rgba[(sy * W + sx) * 4 + c]) / 255
                    let i = c * plane + y * tileSize + x
                    if inType == .float16 {
                        input.dataPointer.assumingMemoryBound(to: Float16.self)[i] = Float16(v)
                    } else {
                        input.dataPointer.assumingMemoryBound(to: Float.self)[i] = v
                    }
                }
            }
        }
        let res = try! model.prediction(from: MLDictionaryFeatureProvider(dictionary: [inName: input]))
        let o = res.featureValue(for: outName)!.multiArrayValue!
        let ts = tileSize * S
        let st = o.strides.map { $0.intValue }   // [n, c, y, x]
        let isHalf = o.dataType == .float16
        // 只取中间那块写回
        let cw = min(core, W - cx), ch = min(core, H - cy)
        for c in 0..<3 {
            for y in 0..<(ch * S) {
                let ty = margin * S + y
                for x in 0..<(cw * S) {
                    let tx = margin * S + x
                    let j = c * st[1] + ty * st[2] + tx * st[3]
                    let v = isHalf ? Float(o.dataPointer.assumingMemoryBound(to: Float16.self)[j])
                                   : o.dataPointer.assumingMemoryBound(to: Float.self)[j]
                    out[c * OW * OH + (cy * S + y) * OW + (cx * S + x)] = min(max(v, 0), 1)
                }
            }
        }
        _ = ts
        tiles += 1
        cx += core
    }
    cy += core
}
print(String(format: "推理 %d 块 %.2fs  %dx%d → %dx%d", tiles, Date().timeIntervalSince(t0), W, H, OW, OH))

// MARK: 写出（模型倍数 ≠ 输出倍数时用 Lanczos 缩放）
var bytes = [UInt8](repeating: 255, count: OW * OH * 4)
for i in 0..<(OW * OH) {
    for c in 0..<3 { bytes[i * 4 + c] = UInt8((out[c * OW * OH + i] * 255).rounded()) }
}
let prov = CGDataProvider(data: Data(bytes) as CFData)!
var img = CGImage(width: OW, height: OH, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: OW * 4, space: space,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: prov,
                  decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
if outScale != S {
    let k = Double(outScale) / Double(S)
    let f = CIFilter(name: "CILanczosScaleTransform")!
    f.setValue(CIImage(cgImage: img), forKey: kCIInputImageKey)
    f.setValue(k, forKey: kCIInputScaleKey)
    f.setValue(1.0, forKey: kCIInputAspectRatioKey)
    let ci = f.outputImage!
    img = CIContext().createCGImage(ci, from: ci.extent.integral, format: .RGBA8, colorSpace: space)!
}
try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: a[4]))
print("写出 \(img.width)x\(img.height) → \(a[4])")
