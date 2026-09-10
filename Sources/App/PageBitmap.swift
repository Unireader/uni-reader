import CoreGraphics
import CoreImage
import ImageIO
import PDFKit

/// PDF 页位图渲染原语（纯 CoreGraphics，不碰 AppKit → 任意线程可用）。
/// 旋转语义由 `spike/render-rotation-test.swift`（9/9）钉死：
/// `page.draw(with:to:)` 自带旋转；显示尺寸 = mediaBox 在 90/270° 时换边；子矩形贴片只需平移。
///
/// ⚠️ `page.draw(with:box,to:)` 内部**已经**把 box 的原点对齐到当前 CTM 原点——调用方不需要、也不能再手动
/// `translateBy(-b.minX,-b.minY)`。旧代码这么写过，因为绝大多数 PDF 的 MediaBox 原点是 (0,0)，这行平移
/// 恰好等于平移 0，从未暴露；真正 CropBox 原点非零（例如跨页扫描图靠 CropBox 切一半）时会叠加成双重平移，
/// 把整页内容顶到画布外（实测：CropBox.minX≈550 时输出纯白）。
///
/// ⚠️ 本原语线程安全，**但 `PDFPage`/`PDFDocument` 不是**：同一个 `PDFDocument` 实例只允许被
/// 一条队列渲染。现有三条管线各自持有独立文档实例或独占队列——Mac 阅读区走
/// `PageRenderEngine` 的串行队列（`session.pdf`）、平板页图走 `LANServer` 服务 queue
/// （`AppModel.padRenderPDF`，另开的实例，见 `setPadRender`）、OCR 走 `DocSession.ocrRenderQueue`。
/// 新增调用方前先确认它拿的是哪份文档实例，别再把 `session.pdf` 交给第四条队列。
enum PageBitmap {
    /// 该页实际显示用的 box：优先 CropBox，退化（未定义/零尺寸）时退回 MediaBox。
    /// 渲染、选区坐标归一化、TOC 跳转、平板页面宽高必须用同一个 box，否则互相错位。
    static func effectiveBox(_ page: PDFPage) -> PDFDisplayBox {
        let crop = page.bounds(for: .cropBox)
        return (crop.width > 0 && crop.height > 0) ? .cropBox : .mediaBox
    }

    /// 页的显示尺寸（pt，已含旋转换边）。
    static func displaySize(_ page: PDFPage) -> CGSize {
        let b = page.bounds(for: effectiveBox(page))
        let rot = ((page.rotation % 360) + 360) % 360
        return rot % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
    }

    /// 整页渲染（宽 pixelWidth 像素，白底）。
    static func render(page: PDFPage, pixelWidth: Int) -> CGImage? {
        let disp = displaySize(page)
        guard disp.width > 0, disp.height > 0, pixelWidth > 0 else { return nil }
        let scale = CGFloat(pixelWidth) / disp.width
        return draw(page: page,
                    pixelSize: CGSize(width: CGFloat(pixelWidth), height: (disp.height * scale).rounded()),
                    scale: scale,
                    subOrigin: .zero)
    }

    /// 子矩形贴片：`subRect` 为「页显示坐标、左上原点」的区域（pt）；`scale` = 像素/pt。
    static func renderTile(page: PDFPage, subRect: CGRect, scale: CGFloat) -> CGImage? {
        let disp = displaySize(page)
        guard subRect.width > 0, subRect.height > 0, scale > 0 else { return nil }
        return draw(page: page,
                    pixelSize: CGSize(width: (subRect.width * scale).rounded(),
                                      height: (subRect.height * scale).rounded()),
                    scale: scale,
                    subOrigin: CGPoint(x: subRect.minX, y: disp.height - subRect.maxY))  // 左上原点 → CG 底左原点
    }

    /// 整页/贴片的实际绘制（几何在调用方算好）。内存与像素格式的全部纪律在 `makeImage`。
    private static func draw(page: PDFPage, pixelSize: CGSize, scale: CGFloat, subOrigin: CGPoint) -> CGImage? {
        makeImage(pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height)) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: pixelSize))
            ctx.interpolationQuality = .high
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -subOrigin.x, y: -subOrigin.y)
            page.draw(with: effectiveBox(page), to: ctx)
        }
    }

    /// 把磁盘缓存里那张**已编码**的页图读回来。
    ///
    /// 🔴 **必须重绘进我们自己的 mmap 缓冲，不能直接把 ImageIO 给的 `CGImage` 塞进 LRU**：
    /// 那张图的像素归 CoreGraphics 管，释放不还给系统，正是下面那条红线说的病根；
    /// 而且它不进 `liveImages` 的账，「缓存淘汰了内存却不降」就又查不出来了。
    /// 重绘一次约 5~13ms（实测 1600~2400px），相比重渲 PDF 的 87~168ms 仍便宜一个数量级。
    ///
    /// 顺带说明为什么解码看着「几乎不要钱」：`CGImageSourceCreateImageAtIndex` 是惰性的，
    /// 真正的解码发生在 `ctx.draw` 那一下——这两步的账要合起来看。
    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0,
                                                        [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return makeImage(pixelWidth: img.width, pixelHeight: img.height) { ctx in
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
    }

    /// 🔴 **像素缓冲必须自己 `mmap` + 用 `CGDataProvider` 的释放回调 `munmap`**，别用
    /// `CGContext(data: nil…)` + `ctx.makeImage()`（2026-08-29 实测定位的内存主项）：
    /// 那条路里 `makeImage` 与 context 共享同一块 COW 缓冲，缓冲本身归 CoreGraphics 的
    /// `DefaultPurgeableMallocZone` 管——**CGImage 释放后它不跟着还**。实测（199MB 扫描 PDF、
    /// 滚 60 页）：`vmmap` 里 31 块 17,432,576 B 的 `MALLOC_LARGE`，而同期活着的 CGImage
    /// （`CG raster data` 块数）只有 11 张 → 20 块 ≈ 348MB 是没人认领的孤儿，且不随缓存上限变化
    /// （上限压到 128MB 照样涨到 555MB）、窗口改尺寸后仍冻在旧尺寸不释放。
    /// 🔴 而且**用 `mmap` 而不是 `malloc`**：改成自持缓冲后仍见「存活位图只有 113MB、
    /// `MALLOC_LARGE` 却是 435MB」——`free` 回调确实跑了（`liveImages` 是我们自己数的），是 macOS 的
    /// magazine malloc 把 free 掉的大块留在自己的 large cache 里等复用。`malloc_zone_pressure_relief`
    /// 能催回来一部分，但要限流、要尾随、活动一停就没人催，账始终对不齐。`mmap`/`munmap` 直接绕开
    /// 这层缓存：释放即还给内核，无条件、无延迟。页图动辄十几到几十 MB，malloc 本来也是走 mmap，
    /// 只是多垫了一层缓存——这里不需要那层。
    ///
    /// 自己持有后：一张图一块缓冲，`CGImage` 一死 `munmap` 立刻执行，`PageRenderEngine` 的 LRU
    /// 淘汰才真的等于还内存。
    ///
    /// 行宽显式对齐 64 字节（CG 快路径要求；原来传 `bytesPerRow: 0` 是让 CG 自己挑）。
    ///
    /// 自持缓冲的图像工厂：`mmap` 一块 BGRX 缓冲 → 交给 `paint` 画 → 包成 `CGImage`，
    /// 缓冲的所有权移交 `CGDataProvider`，最后一个引用消失时 `munmap`。
    /// 格式与内存策略的全部理由见上面那两条红线。
    private static func makeImage(pixelWidth pw: Int, pixelHeight ph: Int,
                                  _ paint: (CGContext) -> Void) -> CGImage? {
        makeImageRaw(pixelWidth: pw, pixelHeight: ph) { buf, bytesPerRow, space in
            guard let ctx = CGContext(data: buf, width: pw, height: ph, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: space, bitmapInfo: alphaInfo)
            else { return false }
            paint(ctx)
            return true
        }
    }

    /// 🔴 像素格式必须是 **BGRX（`noneSkipFirst` + 小端）**，别用 RGBA(`premultipliedLast`)：
    /// 后者不是 Apple Silicon 上 CoreAnimation 的原生格式，CG 每次合成都要转换，转换结果还被它
    /// 按固定条数缓存住——实测表现为 `MALLOC_LARGE` 一路涨到 **31 块就不涨了**（31×16.6MB≈515MB），
    /// 静置不降、Reclaimable=0，改缓存上限也没用，因为那是 CG 的副本不是我们的图。
    /// 页图是**不透明**的（整张填白后才画 PDF），所以连 alpha 通道都不需要，`noneSkipFirst`
    /// 比 `premultipliedFirst` 还省一步混合。
    private static let alphaInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    /// 裸缓冲版工厂：`fill` 直接拿到 `mmap` 出来的 BGRX 缓冲（行宽 64 字节对齐）自己填像素，
    /// 返回 false 表示没填成（缓冲当场 munmap，不出图）。`makeImage`（CGContext 画）与
    /// `invert`（Core Image 直接渲进缓冲）都走这里——**所有页位图只此一个出口**，
    /// `liveImages` 的账才数得全。
    private static func makeImageRaw(pixelWidth pw: Int, pixelHeight ph: Int,
                                     _ fill: (UnsafeMutableRawPointer, Int, CGColorSpace) -> Bool) -> CGImage? {
        guard pw > 0, ph > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bytesPerRow = (pw * 4 + 63) & ~63
        let byteCount = bytesPerRow * ph
        let mapped = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        guard let buf = mapped, buf != MAP_FAILED else { return nil }
        guard fill(buf, bytesPerRow, space) else { munmap(buf, byteCount); return nil }
        // 缓冲的所有权在这里移交给 provider：它是唯一的持有者，回调在最后一个引用消失时跑。
        guard let provider = CGDataProvider(dataInfo: nil, data: buf, size: byteCount,
                                            releaseData: { _, ptr, size in
                                                munmap(UnsafeMutableRawPointer(mutating: ptr), size)
                                                PageBitmap.noteFree(size)
                                            })
        else { munmap(buf, byteCount); return nil }
        noteAlloc(byteCount)
        return CGImage(width: pw, height: ph, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: alphaInfo), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: 存活页位图统计（诊断）

    /// 缓冲由 `draw` 自己 malloc、`CGDataProvider` 回调 free，所以这两个计数就是
    /// **「进程里还有多少张页图活着」的真值**。排查「缓存明明淘汰了、内存却不降」时先看它：
    /// 与 `PageRenderEngine.cacheUsageMB` 对不上，就说明缓存之外还有人在持有。
    private static let liveLock = NSLock()
    private static var liveCount = 0
    private static var liveBytes = 0

    static var liveImages: (count: Int, bytes: Int) {
        liveLock.lock(); defer { liveLock.unlock() }
        return (liveCount, liveBytes)
    }
    fileprivate static func noteAlloc(_ n: Int) {
        liveLock.lock(); liveCount += 1; liveBytes += n; liveLock.unlock()
    }
    fileprivate static func noteFree(_ n: Int) {
        liveLock.lock(); liveCount -= 1; liveBytes -= n; liveLock.unlock()
    }

    /// 夜间反色：CIColorInvert + CIHueAdjust(π)（色相复原：白底变黑，彩色不变怪）。
    ///
    /// 🔴 **结果必须渲进我们自己的 mmap 缓冲**（`ci.render(_:toBitmap:)`），别用
    /// `ci.createCGImage`：那条路出的图像素归 Core Image / CoreGraphics 管（落在
    /// `DefaultPurgeableMallocZone`，vmmap 里是 `MALLOC_LARGE`），既不进 `liveImages` 的账、
    /// 释放了分配器也不还——2026-09-10 三窗口实测 11 张 237MB 就是这批「账外」的夜间图，
    /// 设置页的诊断行对它一无所知。走 `makeImageRaw` 之后与亮色图同一套记账、同一套释放。
    /// 输出格式 `BGRA8` = 与我们 BGRX 缓冲同一字节序（B,G,R,X），alpha 位置写 255，`noneSkipFirst` 不读它。
    static func invert(_ image: CGImage, ci: CIContext) -> CGImage? {
        let src = CIImage(cgImage: image)
        guard let inv = CIFilter(name: "CIColorInvert") else { return nil }
        inv.setValue(src, forKey: kCIInputImageKey)
        guard let inverted = inv.outputImage else { return nil }
        guard let hue = CIFilter(name: "CIHueAdjust") else { return nil }
        hue.setValue(inverted, forKey: kCIInputImageKey)
        hue.setValue(Double.pi, forKey: kCIInputAngleKey)
        let out = hue.outputImage ?? inverted
        let w = image.width, h = image.height
        return makeImageRaw(pixelWidth: w, pixelHeight: h) { buf, bytesPerRow, space in
            ci.render(out, toBitmap: buf, rowBytes: bytesPerRow,
                      bounds: CGRect(x: 0, y: 0, width: w, height: h),
                      format: .BGRA8, colorSpace: space)
            return true
        }
    }
}
