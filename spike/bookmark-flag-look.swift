// 书签页面标记的**样张自查**（纪律：自绘图形不靠脑补，先出图看一眼）。运行：
//   cp spike/bookmark-flag-look.swift /tmp/main.swift && swiftc /tmp/main.swift -o /tmp/bflook && /tmp/bflook
// 产物：/tmp/bookmark-flag/*.png —— 直接看。
//
// 2026-09-02 第一轮验的是「控件选型」：同一个 `.position()` 场景里 Button 画得出来、
// `Menu` 只剩一个「不支持」的黄框（AppKit 托管控件，ImageRenderer 画不了）。留档见 A-control-*.png。
//
// 第二轮验的是「认不认得出」——用户实测：「在右边是吧，没注意到，而且颜色还是橘色的
// 说实话没有反应过来」。四版对照，全都保持扁平（无渐变/高光/投影，红线）：
//   V1 现状：暖橘圆底 + bookmark.fill，整枚在页内
//   V2 红缎带：贴右缘、**探出页外一截**（像真书里夹出来的那条），红色是书签的通用色
//   V3 红圆：只把 V1 换成红色并放大一号，形状不动
//   V4 缎带 + 页边细色条：缎带之外再给页面右缘一条极淡的竖色条，扫一眼就知道"这页标过"
import SwiftUI
import AppKit

let outDir = URL(fileURLWithPath: "/tmp/bookmark-flag")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

@MainActor
func save<V: View>(_ name: String, _ size: CGSize, @ViewBuilder _ view: () -> V) {
    let r = ImageRenderer(content: view().frame(width: size.width, height: size.height))
    r.scale = 2
    guard let img = r.nsImage, let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("❌ \(name) 渲染失败"); return
    }
    try? png.write(to: outDir.appendingPathComponent("\(name).png"))
    print("✅ \(name).png")
}

let orange = Color(red: 0.98, green: 0.72, blue: 0.55)
let ribbonRed = Color(red: 0.84, green: 0.23, blue: 0.24)

let pageW: CGFloat = 300, pageH: CGFloat = 380

/// 一页正文的复刻（灰条当文字，够判断"标记抢不抢戏、看不看得见"）。
@MainActor @ViewBuilder
func paper() -> some View {
    ZStack(alignment: .topLeading) {
        Color.white
        VStack(alignment: .leading, spacing: 9) {
            Text("第三章 语法制导翻译").font(.system(size: 13, weight: .semibold))
            ForEach(0..<14, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.black.opacity(0.16))
                    .frame(width: i % 4 == 3 ? 150 : 240, height: 6)
            }
        }
        .padding(.leading, 26).padding(.top, 34)
    }
}

// V1 现状：暖橘圆底，整枚在页内
@MainActor @ViewBuilder
func v1Mark() -> some View {
    Image(systemName: "bookmark.fill")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.black.opacity(0.75))
        .padding(3)
        .background(orange, in: Circle())
        .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 0.5))
}

// V3 红圆：形状不动，换色 + 放大一号
@MainActor @ViewBuilder
func v3Mark() -> some View {
    Image(systemName: "bookmark.fill")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .padding(4)
        .background(ribbonRed, in: Circle())
        .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 0.5))
}

/// V2/V4 的缎带：一块贴着页右缘的小旗，右端切一个 V 口（真书签的样子）。
/// ⚠️ 这是 `Sources/Views/PageCellView.swift` 里 `BookmarkRibbon` 的**复刻**（本文件要能单文件编译，
/// 引不进那边的类型）。**改一边必须同步另一边**，否则样张就不再是线上那个东西——
/// 草稿纸胶囊那次「样张里少复刻了一件，那件就成了下一个漏网的」是同一笔账。
struct RibbonShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let notch: CGFloat = 5
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - notch, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

@MainActor @ViewBuilder
func ribbon() -> some View {
    RibbonShape()
        .fill(ribbonRed)
        .frame(width: 26, height: 15)
        .overlay(RibbonShape().stroke(.black.opacity(0.18), lineWidth: 0.5))
}

let ys: [CGFloat] = [110, 210]   // 同页两枚，验会不会挤在一起

MainActor.assumeIsolated {
    save("V1-orange-circle", CGSize(width: pageW, height: pageH)) {
        ZStack(alignment: .topLeading) {
            paper()
            ForEach(ys, id: \.self) { y in v1Mark().position(x: pageW - 12, y: y) }
        }
        .border(.gray.opacity(0.35))
    }

    save("V2-red-ribbon", CGSize(width: pageW, height: pageH)) {
        ZStack(alignment: .topLeading) {
            paper()
            // 探出页外一截：中心放在页缘上，缎带一半在页内一半在页外
            ForEach(ys, id: \.self) { y in ribbon().position(x: pageW - 13, y: y) }
        }
        .border(.gray.opacity(0.35))
    }

    save("V3-red-circle", CGSize(width: pageW, height: pageH)) {
        ZStack(alignment: .topLeading) {
            paper()
            ForEach(ys, id: \.self) { y in v3Mark().position(x: pageW - 13, y: y) }
        }
        .border(.gray.opacity(0.35))
    }

    save("V4-ribbon-plus-edge", CGSize(width: pageW, height: pageH)) {
        ZStack(alignment: .topLeading) {
            paper()
            // 页面右缘一条极淡竖色条：整页扫一眼就知道"这页标过"
            Rectangle().fill(ribbonRed.opacity(0.18))
                .frame(width: 3, height: pageH)
                .position(x: pageW - 1.5, y: pageH / 2)
            ForEach(ys, id: \.self) { y in ribbon().position(x: pageW - 13, y: y) }
        }
        .border(.gray.opacity(0.35))
    }

    // 四版并排一张，方便一眼对比
    save("ALL", CGSize(width: pageW * 4 + 60, height: pageH + 30)) {
        HStack(spacing: 12) {
            ForEach(["V1 现状 橘圆", "V2 红缎带", "V3 红圆", "V4 缎带+页边条"], id: \.self) { name in
                VStack(spacing: 6) {
                    Text(name).font(.system(size: 12, weight: .medium))
                    ZStack(alignment: .topLeading) {
                        paper()
                        if name.hasPrefix("V1") {
                            ForEach(ys, id: \.self) { y in v1Mark().position(x: pageW - 12, y: y) }
                        } else if name.hasPrefix("V3") {
                            ForEach(ys, id: \.self) { y in v3Mark().position(x: pageW - 13, y: y) }
                        } else {
                            if name.hasPrefix("V4") {
                                Rectangle().fill(ribbonRed.opacity(0.18))
                                    .frame(width: 3, height: pageH)
                                    .position(x: pageW - 1.5, y: pageH / 2)
                            }
                            ForEach(ys, id: \.self) { y in ribbon().position(x: pageW - 13, y: y) }
                        }
                    }
                    .frame(width: pageW, height: pageH)
                    .border(.gray.opacity(0.35))
                }
            }
        }
        .padding(12)
        .background(Color(white: 0.93))
    }
}
