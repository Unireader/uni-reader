import Foundation
import UniformTypeIdentifiers

/// ⌘V 到 Agent 输入框时剪贴板该怎么处理。只看剪贴板里的类型名，纯逻辑，spike `agent-usage-test.swift`。
enum AgentPaste: Equatable {
    /// 访达里复制的图片文件：按文件附上（同附件按钮）。
    case imageFiles
    /// 只有位图（截图 / 预览 / 浏览器「拷贝图像」）：取这种格式的数据附上。
    case bitmap(type: String)
    /// 照常粘文字（访达里复制的不是图片的文件 = 粘文件名）。
    case text

    /// - Parameters:
    ///   - types: 剪贴板上的类型（`NSPasteboard.types` 的 rawValue）。
    ///   - imageFileCount: 剪贴板上的文件里有几个是图片。
    static func classify(types: [String], imageFileCount: Int) -> AgentPaste {
        if imageFileCount > 0 { return .imageFiles }
        if types.contains(UTType.fileURL.identifier) { return .text }
        // 🔴 同时有文字和格式（RTF / HTML）的是**文档里复制的文字**：Pages / Word / Excel 复制文字时都会另附一张
        // 渲染好的图，这时要粘的是文字
        let rich = [UTType.rtf, .flatRTFD, .html].map(\.identifier)
        if types.contains(UTType.utf8PlainText.identifier), types.contains(where: rich.contains) { return .text }
        guard let t = bitmapType(in: types) else { return .text }
        return .bitmap(type: t)
    }

    /// 第一种位图格式（PNG / TIFF / JPEG / HEIC……）。PDF 不算：剪贴板里的 PDF 多半是矢量的文字排版。
    static func bitmapType(in types: [String]) -> String? {
        types.first { t in
            guard let u = UTType(t), u.conforms(to: .image) else { return false }
            return !u.conforms(to: .pdf)
        }
    }
}
