// 草稿纸自绘图形的**样张自查**（交付前必跑；纪律：自绘图形不靠脑补，先出图看一眼）。运行：
//   cp spike/scratch-look.swift /tmp/main.swift && swiftc Sources/Views/ScratchCanvasLayers.swift Sources/Views/InkLayers.swift Sources/App/ScratchPadModel.swift Sources/App/InkModel.swift Sources/App/InkLayerModel.swift Sources/App/PenPreset.swift Sources/App/NoteTypeModel.swift Sources/Store/LibraryModels.swift Sources/Support/L.swift /tmp/main.swift -o /tmp/slook && /tmp/slook
// 产物：/tmp/scratch-look/*.png —— 直接看，别猜。
//
// 覆盖三个缩放档（0.35 / 1 / 3.2）× 白纸，验证两件肉眼可判的事：
//  ① 点阵在任何缩放下密度都落在舒适区（不糊成一片、也不稀到一屏几个点）；
//  ② 点阵淡到不抢戏，笔迹仍是画面主体；原点十字看得见但不刺眼。
// 另出一张 minimap 样张（骨架 + 视口框）。
import SwiftUI
import AppKit

let outDir = URL(fileURLWithPath: "/tmp/scratch-look")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

@MainActor
func save<V: View>(_ name: String, _ size: CGSize, @ViewBuilder _ view: () -> V) {
    let r = ImageRenderer(content: view().frame(width: size.width, height: size.height))
    r.scale = 2
    guard let img = r.nsImage, let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("✗ \(name) 渲染失败"); return
    }
    let url = outDir.appendingPathComponent(name + ".png")
    try? png.write(to: url)
    print("✓ \(url.path)")
}

/// 一坨看得出形状的示例笔迹（画布坐标，逻辑点）。
func sampleStrokes() -> [InkStroke] {
    let ink = InkColor(r: 24, g: 90, b: 210, a: 0.95)
    let dark = InkColor(r: 30, g: 30, b: 34, a: 0.95)
    func wave(_ x0: Double, _ y0: Double, _ len: Double, _ amp: Double, _ c: InkColor, _ w: Double,
              _ t: PenBrushType) -> InkStroke {
        InkStroke(page: 0, color: c, width: w, type: t,
                  points: stride(from: 0.0, through: len, by: 6).map {
                      SIMD3($0 + x0, y0 + sin($0 / 26) * amp, 0.45 + 0.4 * abs(sin($0 / 40)))
                  },
                  padId: UUID())
    }
    return [
        wave(-230, -70, 430, 26, dark, 5, .ballpoint),
        wave(-210, 30, 380, 16, ink, 7, .fountain),
        wave(-190, 118, 300, 10, InkColor(r: 250, g: 204, b: 40, a: 0.5), 22, .marker),
        wave(-200, 190, 340, 20, dark, 9, .pencil),
    ]
}

@MainActor
func run() {
    let size = CGSize(width: 720, height: 460)
    let strokes = sampleStrokes()
    let paper = Color.white
    let ink = Color.black   // gridInk：白纸配深墨

    for (label, zoom) in [("z035", 0.35), ("z100", 1.0), ("z320", 3.2)] as [(String, CGFloat)] {
        let vp = ScratchViewport(origin: CGPoint(x: -size.width / (2 * zoom), y: -size.height / (2 * zoom)),
                                 zoom: zoom)
        save("grid-\(label)", size) {
            ZStack {
                paper
                ScratchGridLayer(viewport: vp, ink: ink)
                ScratchInkLayer(strokes: strokes, viewport: vp)
            }
        }
        // 只有网格、没有笔迹：验「空白纸是不是淡到还算白底」
        save("gridonly-\(label)", size) {
            ZStack { paper; ScratchGridLayer(viewport: vp, ink: ink) }
        }
    }

    // minimap 样张：内容偏在一侧，视口框只框住一部分 → 看得出「我在哪」
    let vp = ScratchViewport(origin: CGPoint(x: -120, y: -60), zoom: 1)
    save("minimap", CGSize(width: 176, height: 124)) {
        ScratchMinimap(strokes: strokes, viewport: vp, viewSize: size, onJump: { _ in })
    }
    // 胶囊工具条的**对比度**样张（浅色/深色 × 白纸底）。加这一组是因为首版用了
    // `.buttonStyle(.borderless)`，它在 material 底上把图标画得极淡——用户当场报「非激活的按钮
    // 看不清」。对比度这种事看代码看不出来，只能出图。这里只复刻 toolbar 的修饰符组合。
    for (name, scheme) in [("cap-light", ColorScheme.light), ("cap-dark", .dark)] {
        save(name, CGSize(width: 460, height: 90)) {
            ZStack { Color.white; capsuleMock }.environment(\.colorScheme, scheme)
        }
    }
    print("—\n样张已出，逐张看过再交付。")
}

/// 与 `ScratchPadView.toolbar` 同一组修饰符的复刻（不引 AppModel/DocSession）。
/// 改了那边的按钮样式，**这里要跟着改**，否则样张就不再代表真实观感。
@MainActor
var capsuleMock: some View {
    func btn(_ icon: String, _ tint: Color = .primary, _ off: Bool = false) -> some View {
        Button {} label: {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(tint).disabled(off)
    }
    return HStack(spacing: 8) {
        Button {} label: { Label("Scratchpad 1", systemImage: "square.and.pencil").lineLimit(1) }
            .buttonStyle(.plain).foregroundStyle(.primary)
        Divider().frame(height: 14)
        btn("scope")
        btn("arrow.up.left.and.arrow.down.right", .primary, true)   // 空纸时禁用
        btn("map", .accentColor)
        // 缩放读数（只在非 100% 时出现）。**首版样张漏了它**，于是没看出 `.secondary` 在
        // material 上根本读不出来——复刻缺一件，样张就代表不了真实观感。
        Text("150%").font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.primary)
        Divider().frame(height: 14)
        btn("xmark")
    }
    .padding(.horizontal, 12).padding(.vertical, 7)
    .background(.regularMaterial, in: Capsule())
    .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
    .shadow(radius: 6, y: 2)
}

MainActor.assumeIsolated { run() }
