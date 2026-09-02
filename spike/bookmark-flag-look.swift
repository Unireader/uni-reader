// 书签旗标的**样张自查**（用户报「pdf 区域还是看不到东西」→ 先证明这枚东西到底渲不渲得出来，别猜）。运行：
//   cp spike/bookmark-flag-look.swift /tmp/main.swift && swiftc /tmp/main.swift -o /tmp/bflook && /tmp/bflook
// 产物：/tmp/bookmark-flag/*.png —— 直接看。
//
// 三张对照，只差「用什么控件」，位置/形制/尺寸完全一样：
//  A: Button   —— 草稿纸图钉的既有写法（已知能显示，当基准）
//  B: Menu + .menuStyle(.borderlessButton) + .menuIndicator(.hidden) + .fixedSize()  ← 现在的写法
//  C: Menu 不加 .fixedSize()
// 若 B 是空的而 A 有东西，就说明 `Menu` 在 `.position()` 的 ZStack 里画不出来，得换控件。
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

let marker = Color(red: 0.98, green: 0.72, blue: 0.55)

@MainActor @ViewBuilder
func label() -> some View {
    Image(systemName: "bookmark.fill")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.black.opacity(0.75))
        .padding(3)
        .background(marker, in: Circle())
        .overlay(Circle().stroke(.black.opacity(0.15), lineWidth: 0.5))
}

/// 页元胞的复刻：白纸 + 一枚标记贴右缘。
@MainActor @ViewBuilder
func page<M: View>(@ViewBuilder _ mark: () -> M) -> some View {
    ZStack(alignment: .topLeading) {
        Color.white
        Text("正文正文正文").font(.system(size: 13)).position(x: 100, y: 60)
        mark()
    }
    .frame(width: 260, height: 340)
    .border(.gray.opacity(0.4))
}

let size = CGSize(width: 260, height: 340)

MainActor.assumeIsolated {
    save("A-button", size) {
        page {
            Button {} label: { label() }
                .buttonStyle(.plain)
                .position(x: 260 - 12, y: 120)
        }
    }
    save("B-menu-fixedsize", size) {
        page {
            Menu {
                Button("Rename…") {}
                Button("Delete") {}
            } label: { label() }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .position(x: 260 - 12, y: 120)
        }
    }
    save("C-menu-nofixed", size) {
        page {
            Menu {
                Button("Rename…") {}
                Button("Delete") {}
            } label: { label() }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .position(x: 260 - 12, y: 120)
        }
    }
}
