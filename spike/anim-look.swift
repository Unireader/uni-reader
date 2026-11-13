// ```anim 出图目检：把写法说明里的示例画成 PNG（缩略图拼板 + 第 2 步补间中途一帧），深浅色各一张。运行：
//   mkdir -p build/spike/anim-look && cp spike/anim-look.swift build/spike/main.swift && swiftc Sources/Support/L.swift Sources/Anim/AnimText.swift Sources/Anim/AnimReference.swift Sources/Anim/AnimState.swift Sources/Anim/AnimStructures.swift Sources/Anim/AnimLayout.swift Sources/Anim/AnimLayout+Structures.swift Sources/Anim/AnimPainter.swift build/spike/main.swift -o build/spike/anim-look-bin && build/spike/anim-look-bin [额外的 .anim 文件…]
// 图在 build/spike/anim-look/。
import AppKit

func save(_ image: CGImage?, _ name: String) {
    guard let image else { print("❌ \(name) 没画出来"); return }
    let rep = NSBitmapImageRep(cgImage: image)
    let url = URL(fileURLWithPath: "build/spike/anim-look/\(name).png")
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    print("✅ \(url.path) \(image.width)×\(image.height)")
}

var sources = AnimText.examples
for path in CommandLine.arguments.dropFirst() {
    if let s = try? String(contentsOfFile: path, encoding: .utf8) { sources.append(s) }
}
for (i, text) in sources.enumerated() {
    let run = AnimEngine.run(text)
    if !run.errors.isEmpty { print("示例 \(i + 1) 错误：\(run.errors)") }
    for dark in [false, true] {
        save(AnimSnapshot.contactSheet(run: run, width: 640, dark: dark, scale: 1.5), "ex\(i + 1)-sheet-\(dark ? "dark" : "light")")
    }
    save(AnimSnapshot.image(run: run, width: 640, step: 0, dark: false, scale: 2, controls: true), "ex\(i + 1)-static")
    save(AnimSnapshot.image(run: run, width: 720, step: run.stepCount - 1, dark: false, scale: 1.5, controls: false), "ex\(i + 1)-last")
    // 补间中途：第 1 → 2 步，t = 0.5
    if run.stepCount > 2 {
        let metrics = AnimBlockMetrics(run: run, width: 640)
        let palette = AnimPalette(dark: false)
        let img = AnimSnapshot.render(size: CGSize(width: 640, height: metrics.canvasHeight), scale: 2, background: palette.color(.background)) {
            AnimPainter.draw(metrics.layout.frame(step: 1), metrics.layout.frame(step: 2), t: 0.5, palette: palette)
        }
        save(img, "ex\(i + 1)-mid")
    }
    // 最后一步的补间中途（旋转、改指向这类最后才发生的动作）
    if run.stepCount > 2 {
        let metrics = AnimBlockMetrics(run: run, width: 640)
        let palette = AnimPalette(dark: false)
        let k = run.stepCount - 1
        let img = AnimSnapshot.render(size: CGSize(width: 640, height: metrics.canvasHeight), scale: 2, background: palette.color(.background)) {
            AnimPainter.draw(metrics.layout.frame(step: k - 1), metrics.layout.frame(step: k), t: 0.5, palette: palette)
        }
        save(img, "ex\(i + 1)-midlast")
    }
}
