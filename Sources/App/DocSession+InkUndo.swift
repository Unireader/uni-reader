import Foundation

/// `DocSession` 上的撤销记账与应用（栈本身在 `InkUndo.swift`，那边不认识会话、可被 spike 直接测）。

extension DocSession {

    /// 当前该由哪条栈接管撤销：草稿纸开着时归纸，否则归页内（⌘Z 跟着眼前那张画布走）。
    var activeUndo: InkUndoStack { openPadID != nil ? scratchUndo : inkUndo }

    /// 包住一段会改**页内笔迹 / 文字注解**的代码，把前后差异记进撤销栈。
    /// 落库与镜像照旧由既有的 `@Published` 订阅完成，这里只多记一笔账。
    @discardableResult
    func inkEdit<R>(_ label: String, kind: InkPatch.Kind, _ body: () -> R) -> R {
        let s0 = strokes, n0 = textNotes, i0 = imageNotes     // COW 快照，O(1)
        let r = body()
        inkUndo.record(label: label, kind: kind,
                       strokesBefore: s0, strokesAfter: strokes,
                       notesBefore: n0, notesAfter: textNotes,
                       imagesBefore: i0, imagesAfter: imageNotes)
        return r
    }

    /// 同上，草稿纸那张画布（笔迹；画板笔记还有图片）。
    @discardableResult
    func scratchEdit<R>(_ label: String, kind: InkPatch.Kind, _ body: () -> R) -> R {
        let s0 = scratchStrokes, b0 = boardImages
        let r = body()
        scratchUndo.record(label: label, kind: kind, strokesBefore: s0, strokesAfter: scratchStrokes,
                           boardImagesBefore: b0, boardImagesAfter: boardImages)
        return r
    }

    /// 撤销/重做一步**页内**编辑。返回是否真的动了数据（调用方据此决定要不要广播镜像）。
    func applyInkUndo(redo: Bool) -> Bool {
        guard let patch = inkUndo.pop(redo: redo) else { return false }
        inkUndo.whileApplying {
            if !patch.strokes.isEmpty {
                var arr = strokes
                InkDelta.apply(patch.strokes, to: &arr, undo: !redo)
                strokes = arr           // 一次性写回：中途每改一条都发一轮 @Published 就白重算整窗
            }
            if !patch.notes.isEmpty {
                var arr = textNotes
                InkDelta.apply(patch.notes, to: &arr, undo: !redo)
                textNotes = arr
            }
            if !patch.images.isEmpty {
                var arr = imageNotes
                InkDelta.apply(patch.images, to: &arr, undo: !redo)
                imageNotes = arr
            }
        }
        return true
    }

    /// 撤销/重做一步**草稿纸**编辑。
    func applyScratchUndo(redo: Bool) -> Bool {
        guard let patch = scratchUndo.pop(redo: redo) else { return false }
        scratchUndo.whileApplying {
            if !patch.strokes.isEmpty {
                var arr = scratchStrokes
                InkDelta.apply(patch.strokes, to: &arr, undo: !redo)
                scratchStrokes = arr
            }
            if !patch.boardImages.isEmpty {
                var arr = boardImages
                InkDelta.apply(patch.boardImages, to: &arr, undo: !redo)
                boardImages = arr
            }
        }
        return true
    }
}
