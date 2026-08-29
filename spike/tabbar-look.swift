// 标签栏的**样张自查**（交付前必跑；纪律：自绘 UI 不靠脑补，先出图看一眼）。运行：
//   cp spike/tabbar-look.swift /tmp/main.swift && swiftc Sources/Views/TabBarChrome.swift Sources/Support/L.swift /tmp/main.swift -o /tmp/tblook && /tmp/tblook
// 产物：/tmp/tabbar-look/*.png —— 直接看，别猜。
//
// 🔴 这里编的是**真实的 `TabStrip`**（`Sources/Views/TabBarChrome.swift`），不是 mock。
// 草稿纸那轮的教训：复刻一份就一定会漏——`spike/scratch-look.swift` 当时没复刻缩放读数，
// 于是「读数太浅」躲过了那一轮「逐张看过」。
//
// 覆盖：两种形态（浮动胶囊 / 贴底整条）× 浅深两套外观 × 三种标签数（2 / 5 / 9）。
// 要肉眼判的四件事：
//  ① 活动标签与非活动标签**分得开**（草稿纸那轮的坑就是 material 底上控件几乎看不见）；
//  ② 关闭按钮在**左**，且非活动标签上不显示（不抢戏）；
//  ③ 长标题截断得体、标签不会被挤成一条；
//  ④ 深色外观下描边/阴影不发白发糊。
import SwiftUI
import AppKit

let outDir = URL(fileURLWithPath: "/tmp/tabbar-look")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

@MainActor
func save<V: View>(_ name: String, _ size: CGSize, dark: Bool, @ViewBuilder _ view: () -> V) {
    let r = ImageRenderer(content:
        view()
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light)
    )
    r.scale = 2
    guard let img = r.nsImage, let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("✗ \(name) 渲染失败"); return
    }
    try? png.write(to: outDir.appendingPathComponent(name + ".png"))
    print("✓ \(outDir.appendingPathComponent(name + ".png").path)")
}

let titles = ["高等数学 第七版 上册", "线性代数", "概率论与数理统计", "Deep Learning", "考研英语真题",
              "数据结构与算法分析", "操作系统导论", "计算机网络 自顶向下", "编译原理 龙书"]

func items(_ n: Int, padAt: Int? = 1) -> [TabBarItem] {
    (0..<n).map { i in
        TabBarItem(id: UUID(), title: titles[i % titles.count],
                   padFollowing: i == padAt, hasDocument: true)
    }
}

/// 假的阅读区背景：标签栏是**盖在 PDF 上**的，纯色背景看不出遮挡与对比度。
struct FakeReader<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ c: () -> Content) { content = c() }
    var body: some View {
        ZStack(alignment: .bottom) {
            Color(nsColor: .underPageBackgroundColor)
            VStack(spacing: 10) {
                ForEach(0..<9, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: i % 3 == 2 ? 320 : 460, height: 9)
                }
            }
            .padding(.bottom, 26)
            .frame(maxHeight: .infinity, alignment: .center)
            content
        }
    }
}

@MainActor
func shot(_ name: String, style: TabBarStyle, count: Int, dark: Bool) {
    let its = items(count)
    save(name, CGSize(width: 900, height: 240), dark: dark) {
        FakeReader {
            TabStrip(items: its, activeID: its[0].id, style: style)
        }
    }
}

/// 特写：只画标签栏本身、放大 4 倍。对比度这种事看整屏样张看不出来，必须凑近看
/// （草稿纸那轮「胶囊里的非激活按钮几乎看不见」就是这么漏过去的）。
@MainActor
func closeup(_ name: String, style: TabBarStyle, dark: Bool) {
    // 活动标签**故意取中间那个**：取第一个的话，「浅的是活动的还是第一个」分不清
    // （2026-08-29 排查活动态对比度时就卡在这个歧义上）。
    let its = items(3, padAt: 2)
    let r = ImageRenderer(content:
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                TabStrip(items: its, activeID: its[1].id, style: style)
            }
        }
        .frame(width: 620, height: 60)
        .environment(\.colorScheme, dark ? .dark : .light)
    )
    r.scale = 4
    guard let img = r.nsImage, let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: outDir.appendingPathComponent(name + ".png"))
    print("✓ \(outDir.appendingPathComponent(name + ".png").path)")
}

@MainActor
func renderAll() {
    for dark in [false, true] {
        for style in [TabBarStyle.floating, .docked] {
            closeup("closeup-\(style.rawValue)-\(dark ? "dark" : "light")", style: style, dark: dark)
        }
    }
    for dark in [false, true] {
        let tag = dark ? "dark" : "light"
        for style in [TabBarStyle.floating, .docked] {
            for n in [2, 5, 9] {
                shot("\(style.rawValue)-\(n)tabs-\(tag)", style: style, count: n, dark: dark)
            }
        }
    }
    print("\n共 12 张，逐张目检：活动/非活动是否分得开、× 在左且非活动不显、长标题截断、深色下描边不发白。")
}
MainActor.assumeIsolated { renderAll() }
