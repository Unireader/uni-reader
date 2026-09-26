import Foundation

/// 画板笔记的平板同步（`BOARD-NOTE-PLAN.md §4`）。笔迹那部分走草稿纸的 `scratchpads` / `scratchStrokes`
/// （画板会话里那张纸永远开着），这里只多两条下行（`boards` / `boardImages`）与两条上行（`boardOpen` / `boardAdd`）。
extension AppModel {

    /// 被跟随会话是什么（`boards.kind`）：0 = PDF（或空标签）、1 = Markdown 笔记、2 = 画板笔记。
    private func followKind(_ s: DocSession) -> Int {
        s.isBoard ? 2 : (s.showsMarkdown ? 1 : 0)
    }

    /// 画板列表 + 被跟随会话的类型。客户端接入、跟随的会话变化、画板增删改名时发。
    func broadcastBoards() {
        guard server.hasClients, let s = padSession else { return }
        let list: [[String: Any]] = s.workspaceBoards.map { ["id": $0.id.uuidString, "title": $0.displayName] }
        server.broadcast(["type": "boards", "kind": followKind(s),
                          "current": s.board?.id.uuidString ?? "", "list": list])
    }

    /// 当前画板上的图（不是画板会话时发空表）。图片本体客户端按 `GET /image?h=<sha>` 自取。
    func broadcastBoardImages() {
        guard server.hasClients, let s = padSession else { return }
        // 先把这几张图登记给 `/image`（只认登记过的 sha，不拿请求里的字符串拼路径）
        var files: [String: URL] = [:]
        if let folder = s.workspaceFolder {
            for im in s.boardImages where files[im.image] == nil {
                for ext in ImageAssets.passthroughExts.sorted() {
                    let u = ImageAssets.url(in: folder, sha256: im.image, ext: ext)
                    if FileManager.default.fileExists(atPath: u.path) { files[im.image] = u; break }
                }
            }
        }
        setBoardImageFiles(files)
        let list: [[String: Any]] = s.boardImages.map { im in
            ["id": im.id.uuidString, "sha": im.image,
             "x": Double(im.rect.minX), "y": Double(im.rect.minY),
             "w": Double(im.rect.width), "h": Double(im.rect.height)]
        }
        server.broadcast(["type": "boardImages", "list": list])
    }

    /// 平板 `boardOpen`：在它跟随的那扇窗口里打开这篇画板（已开着就切过去）。
    func applyBoardOpen(_ obj: [String: Any]) {
        guard let cur = padSession, let id = UUID(uuidString: obj["id"] as? String ?? "") else { return }
        padBoardRequest = PadBoardRequest(sessionID: cur.id, boardID: id)
    }

    /// 平板 `boardAdd`：新建一篇并打开。
    func applyBoardAdd() {
        guard let cur = padSession else { return }
        padBoardRequest = PadBoardRequest(sessionID: cur.id, boardID: nil)
    }

    /// 窗口替平板开好了画板标签之后调：平板若锁定在某个会话上（没在「跟随 Mac」），就把它锁到新标签。
    /// 跟随模式下新标签成为活动标签时 `setActive` 已经带过去了，不用管。
    func padFollowBoardTab(_ s: DocSession) {
        guard padSelectedSessionID != nil, padSelectedSessionID != s.id else { return }
        selectPadDoc(s.id.uuidString)
    }
}
