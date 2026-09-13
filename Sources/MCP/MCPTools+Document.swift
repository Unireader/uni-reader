import Foundation

/// 批 1：`list_documents` / `open_document` / `get_document` / `read_pages`（方案 §7.4 ~ §7.7）。
extension MCPTools {
    static func listDocuments() -> MCPTool {
        MCPTool(
            name: "list_documents",
            title: "List documents in a workspace",
            description: "Documents (PDFs) in a workspace library with their ids, page counts, reading position, group and file status. Defaults to the key window's workspace; the workspace must already be open.",
            inputSchema: MCPSchema.object([
                "workspace": MCPSchema.string("Workspace .unrd path. Omit for the key window's workspace."),
                "group": MCPSchema.string("Only documents in this group (exact name)."),
            ]),
            outputSchema: MCPSchema.object([
                "workspace": workspaceDTOSchema,
                "groups": MCPSchema.array(of: MCPSchema.string("group name")),
                "documents": MCPSchema.array(of: documentDTOSchema),
            ]),
            tier: .read
        ) { _, args in
            let wsPath = try args.string("workspace")
            let group = try args.string("group")
            let r = try await MainActor.run { try MCPFacade.shared.documents(workspacePath: wsPath, group: group) }
            let ws = (r["workspace"] as? MCPObject) ?? [:]
            let docs = (r["documents"] as? [MCPObject]) ?? []
            var lines = ["Workspace “\(ws["name"] ?? "")” · \(docs.count) documents"]
            lines += docs.map { describeDocument($0) }
            return MCPToolResult(text: lines.joined(separator: "\n"), structured: r)
        }
    }

    static func openDocument() -> MCPTool {
        MCPTool(
            name: "open_document",
            title: "Open a document",
            description: "Show a library document in a reader tab (activates the tab if it is already open, otherwise opens one in a window of its workspace). Optionally jump to a page. Pass `path` instead of `document_id` to import a PDF file into the workspace first (same as dragging it in; requires writes to be enabled).",
            inputSchema: MCPSchema.object([
                "document_id": MCPSchema.string("Library document id from list_documents."),
                "path": MCPSchema.string("Absolute path of a PDF to import into the workspace and open (write; needs writes enabled). Use either document_id or path."),
                "workspace": MCPSchema.string("Workspace .unrd path: target for import, or disambiguation for document_id."),
                "window_id": MCPSchema.string("Open in this window (from get_state). Default: the window already showing it, else the workspace's key window."),
                "page": MCPSchema.integer("Jump to this page after opening (1-based).", min: 1),
                "activate": MCPSchema.boolean("Bring UniReader and the window to front", default: true),
            ]),
            outputSchema: MCPSchema.object([
                "session_id": MCPSchema.string("tab / session id"), "window_id": MCPSchema.string("window id"),
                "document": documentDTOSchema, "page": MCPSchema.integer("current page, 1-based"),
                "imported": MCPSchema.boolean("a new library entry was created"),
            ]),
            tier: .navigate
        ) { ctx, args in
            var id = try args.string("document_id") ?? ""
            let path = try args.string("path") ?? ""
            let wsPath = try args.string("workspace")
            let windowId = try args.string("window_id")
            let page = try args.int("page")
            let activate = try args.bool("activate", default: true)
            var imported = false
            if !path.isEmpty {
                // 导入 = 写入（决策 D7）：这个工具本身是导航级，带 path 时按写入开关拦
                guard id.isEmpty else { throw MCPInvalidParams("pass either document_id or path, not both") }
                guard ctx.writesEnabled else {
                    throw MCPToolError("importing a PDF is a write; writes are disabled in UniReader › Settings › Agent (pass document_id for a document already in the library)")
                }
                let r = try await importPDF(path: path, workspacePath: wsPath, group: nil)
                id = (r["document"] as? MCPObject)?["id"] as? String ?? ""
                imported = (r["imported"] as? Bool) == true
            }
            guard !id.isEmpty else { throw MCPInvalidParams("argument 'document_id' (or 'path') is required") }
            var r = try await MainActor.run {
                try MCPFacade.shared.openDocument(documentId: id, workspacePath: wsPath, windowId: windowId, page: page, activate: activate)
            }
            r["imported"] = imported
            let doc = (r["document"] as? MCPObject) ?? [:]
            return MCPToolResult(text: "\(imported ? "Imported and opened" : "Opened") “\(doc["title"] ?? "")” at page \(r["page"] ?? 1) · session_id \(r["session_id"] ?? "") · window_id \(r["window_id"] ?? "")",
                                 structured: r)
        }
    }

    /// `import_pdf` 与 `open_document(path:)` 共用：校验 → 目标工作区 → `WorkspaceManager.importPDF`（后台算 hash）→ 分组。
    static func importPDF(path: String, workspacePath: String?, group: String?) async throws -> MCPObject {
        let abs = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: abs) else { throw MCPToolError("file not found: \(path)") }
        guard (abs as NSString).pathExtension.lowercased() == "pdf" else { throw MCPToolError("not a PDF file: \(path)") }
        let ws = try await MainActor.run { try MCPFacade.shared.importWorkspace(workspacePath: workspacePath) }
        guard let res = await ws.importPDF(at: URL(fileURLWithPath: abs)) else {
            throw MCPToolError("could not import \(path) (unreadable file?)")
        }
        let (dto, wsInfo) = await MainActor.run {
            (MCPFacade.shared.afterImport(ws, res.document, group: group),
             ["name": ws.name, "path": ws.folder?.path ?? ""] as MCPObject)
        }
        return ["document": dto, "imported": res.isNew, "workspace": wsInfo]
    }

    static func importPDFTool() -> MCPTool {
        MCPTool(
            name: "import_pdf",
            title: "Import a PDF into a workspace",
            description: "Add a PDF file to a workspace library (same as dragging it into UniReader). A file already in the library is recognized by content hash and not duplicated. Does not open it unless `open` is true.",
            inputSchema: MCPSchema.object([
                "path": MCPSchema.string("Absolute path of the PDF file"),
                "workspace": MCPSchema.string("Target workspace .unrd path (must be open). Default: the key window's workspace."),
                "group": MCPSchema.string("Put it in this group (created if new)."),
                "open": MCPSchema.boolean("Also open it in a tab", default: false),
            ], required: ["path"]),
            outputSchema: MCPSchema.object([
                "document": documentDTOSchema, "imported": MCPSchema.boolean("a new library entry was created (false = it was already there)"),
                "workspace": MCPSchema.object(["name": MCPSchema.string("name"), "path": MCPSchema.string(".unrd path")]),
                "session_id": MCPSchema.string("tab id when open = true"),
            ]),
            tier: .write
        ) { _, args in
            let path = try args.requiredString("path")
            let wsPath = try args.string("workspace")
            let group = try args.string("group")
            let open = try args.bool("open", default: false)
            var r = try await importPDF(path: path, workspacePath: wsPath, group: group)
            let doc = (r["document"] as? MCPObject) ?? [:]
            if open, let id = doc["id"] as? String {
                let o = try await MainActor.run {
                    try MCPFacade.shared.openDocument(documentId: id, workspacePath: wsPath, windowId: nil, page: nil, activate: true)
                }
                r["session_id"] = o["session_id"]
            }
            let isNew = (r["imported"] as? Bool) == true
            return MCPToolResult(text: "\(isNew ? "Imported" : "Already in the library:") “\(doc["title"] ?? "")” · document_id \(doc["id"] ?? "")\(open ? " · opened" : "")", structured: r)
        }
    }

    static func runOCR() -> MCPTool {
        MCPTool(
            name: "run_ocr",
            title: "Run OCR on pages",
            description: "Queue OCR for scanned pages of a document that is open in a tab (uses the OCR engine configured in UniReader; cached pages are reused). Returns immediately; call read_pages again later to get the text.",
            inputSchema: MCPSchema.object(writeTargetProperties.merging([
                "pages": ["anyOf": [["type": "integer"], ["type": "string"]], "description": "Pages to recognize, e.g. \"1-20\". Default: the whole document."],
            ]) { a, _ in a }),
            outputSchema: MCPSchema.object([
                "document_id": MCPSchema.string("document"), "requested": MCPSchema.integer("pages asked for"),
                "pending": MCPSchema.integer("pages still queued or running"), "done": MCPSchema.integer("pages with text now"),
                "total": MCPSchema.integer("pages in the document"),
            ]),
            tier: .write
        ) { _, args in
            let docId = try args.string("document_id"), wsPath = try args.string("workspace")
            var pages: [Int]? = nil
            if let spec = try args.pages("pages") {
                let count = try await MainActor.run { try MCPFacade.shared.writeTarget(documentId: docId, workspacePath: wsPath).pageCount }
                pages = try PageNo.parse(spec, pageCount: count, limit: Int.max)
            }
            let r = try await MainActor.run { try MCPFacade.shared.runOCR(documentId: docId, workspacePath: wsPath, pages: pages) }
            return MCPToolResult(text: "OCR queued: \(r["requested"] ?? 0) pages requested, \(r["pending"] ?? 0) pending, \(r["done"] ?? 0)/\(r["total"] ?? 0) have text. Call read_pages later.", structured: r)
        }
    }

    static func getDocument() -> MCPTool {
        MCPTool(
            name: "get_document",
            title: "Document overview",
            description: "Page count, table of contents (outline) and whether the PDF has its own text layer or cached OCR text. Works for library documents (document_id) and for any PDF file (path).",
            inputSchema: MCPSchema.object(targetProperties.merging([
                "include_toc": MCPSchema.boolean("Include the outline tree", default: true),
            ]) { a, _ in a }),
            outputSchema: MCPSchema.object([
                "document": documentDTOSchema,
                "title": MCPSchema.string("title or file name"), "path": MCPSchema.string("file path"),
                "page_count": MCPSchema.integer("pages"),
                "first_page_size_pt": MCPSchema.array(of: MCPSchema.number("points"), "[width, height] of page 1 in PDF points"),
                "text": MCPSchema.object(["native_sample_pages": MCPSchema.integer("pages sampled"), "native_pages": MCPSchema.integer("sampled pages that have their own text"),
                                          "ocr_cached_pages": MCPSchema.integer("pages with cached OCR text")]),
                "toc": MCPSchema.array(of: MCPSchema.object(["title": MCPSchema.string("entry"), "page": MCPSchema.integer("1-based, null if the entry has no page"),
                                                             "children": MCPSchema.array(of: ["type": "object"])])),
            ]),
            tier: .read
        ) { _, args in
            let target = try await MainActor.run {
                try MCPFacade.shared.resolveTarget(documentId: try args.string("document_id"), path: try args.string("path"),
                                                   workspacePath: try args.string("workspace"))
            }
            let includeTOC = try args.bool("include_toc", default: true)
            let reader = MCPDocReader.shared
            let summary = try await reader.summary(path: target.path, includeTOC: includeTOC)
            let sample = try await reader.nativeSample(path: target.path, count: 5)
            var ocrCached = 0
            if let store = target.store { ocrCached = await reader.ocrPageCount(store: store, contentHash: target.contentHash) }

            func tocDTO(_ e: TOCEntry) -> MCPObject {
                ["title": e.label, "page": e.pageIndex.map { PageNo.external($0) } ?? NSNull(), "children": e.children.map(tocDTO)]
            }
            let toc = summary.toc.map(tocDTO)
            var r: MCPObject = [
                "title": target.title, "path": target.path,
                "page_count": summary.pageCount,
                "first_page_size_pt": [Double(summary.firstPageSize.width), Double(summary.firstPageSize.height)],
                "text": ["native_sample_pages": sample.sampled, "native_pages": sample.withText, "ocr_cached_pages": ocrCached] as MCPObject,
                "toc": toc,
            ]
            if let id = target.documentId, let d = await MainActor.run(body: { MCPFacade.shared.documentDTO(documentId: id) }) {
                r["document"] = d
            }
            var lines = ["“\(target.title)” · \(summary.pageCount) pages"]
            if let id = target.documentId { lines.append("document_id \(id)") }
            let textKind: String
            if sample.withText == sample.sampled, sample.sampled > 0 { textKind = "has its own text layer (read_pages works directly)" }
            else if sample.withText == 0 { textKind = ocrCached > 0 ? "scanned; \(ocrCached) pages have cached OCR text" : "scanned; NO OCR text cached yet (ask the user to run OCR in UniReader)" }
            else { textKind = "mixed: \(sample.withText)/\(sample.sampled) sampled pages have text; \(ocrCached) OCR pages cached" }
            lines.append("Text: \(textKind)")
            if includeTOC {
                if toc.isEmpty { lines.append("Outline: none") }
                else { lines.append("Outline:"); describeTOC(toc, into: &lines) }
            }
            return MCPToolResult(text: lines.joined(separator: "\n"), structured: r)
        }
    }

    static func searchText() -> MCPTool {
        MCPTool(
            name: "search_text",
            title: "Search text in a document",
            description: "Find a phrase in a document (case-insensitive). Searches the PDF's own text like ⌘F, and cached OCR text on scanned pages. Returns page numbers, a snippet with context, and the highlight rectangles.",
            inputSchema: MCPSchema.object(targetProperties.merging([
                "query": MCPSchema.string("Text to find"),
                "pages": ["anyOf": [["type": "integer"], ["type": "string"]], "description": "Limit to these pages, e.g. \"1-50\". Default: whole document."],
                "max_hits": MCPSchema.integer("Stop after this many hits", min: 1, max: 500),
            ]) { a, _ in a }, required: ["query"]),
            outputSchema: MCPSchema.object([
                "document_id": MCPSchema.string("library document id, absent for a plain file"),
                "query": MCPSchema.string("the query"),
                "hits": MCPSchema.array(of: MCPSchema.object([
                    "page": MCPSchema.integer("1-based"), "snippet": MCPSchema.string("text around the hit"),
                    "source": MCPSchema.enumeration(["native", "ocr"], "text layer"),
                    "rects": MCPSchema.array(of: MCPSchema.array(of: MCPSchema.number("0…1")), "[x, y, w, h] normalized, top-left origin")])),
                "truncated": MCPSchema.boolean("more hits exist"),
            ]),
            tier: .read
        ) { _, args in
            let target = try await MainActor.run {
                try MCPFacade.shared.resolveTarget(documentId: try args.string("document_id"), path: try args.string("path"),
                                                   workspacePath: try args.string("workspace"))
            }
            let query = try args.requiredString("query")
            let maxHits = try args.int("max_hits") ?? 50
            let reader = MCPDocReader.shared
            let pageCount = try await reader.withDocument(path: target.path) { $0.pageCount }
            var pageSet: Set<Int>? = nil
            if let spec = try args.pages("pages") { pageSet = Set(try PageNo.parse(spec, pageCount: pageCount, limit: Int.max)) }

            var hits = try await reader.searchNative(path: target.path, query: query, pages: pageSet, context: 80, maxHits: maxHits + 1)
            if let store = target.store {
                let nativePages = Set(hits.map(\.index))
                let ocr = await reader.searchOCR(store: store, contentHash: target.contentHash, query: query, pages: pageSet, maxHits: maxHits + 1)
                    .filter { !nativePages.contains($0.index) }   // 同一页两层都有就只报原生的，别重复
                hits = (hits + ocr).sorted { a, b in
                    a.index != b.index ? a.index < b.index : (a.rects.first?.minY ?? 0) < (b.rects.first?.minY ?? 0)
                }
            }
            let truncated = hits.count > maxHits
            if truncated { hits = Array(hits.prefix(maxHits)) }
            let items: [MCPObject] = hits.map {
                ["page": PageNo.external($0.index), "snippet": $0.snippet, "source": $0.source,
                 "rects": $0.rects.map(MCPFacade.rectArray)]
            }
            var r: MCPObject = ["query": query, "hits": items, "truncated": truncated]
            if let id = target.documentId { r["document_id"] = id }
            var lines = ["\(hits.count)\(truncated ? "+" : "") hits for “\(query)” in “\(target.title)”"]
            lines += hits.map { "- p.\(PageNo.external($0.index)): …\($0.snippet)…" }
            return MCPToolResult(text: lines.joined(separator: "\n"), structured: r)
        }
    }

    static func renderPage() -> MCPTool {
        MCPTool(
            name: "render_page",
            title: "Render a page image",
            description: "Render one page as an image (JPEG by default) so a vision-capable model can look at figures, formulas or layout. Page content only, no ink or highlights.",
            inputSchema: MCPSchema.object(targetProperties.merging([
                "page": MCPSchema.integer("Page to render, 1-based", min: 1),
                "width": MCPSchema.integer("Pixel width; snapped to \(LANServer.pageWidthSteps.map(String.init).joined(separator: "/")), max 2160", min: 240, max: 2160),
                "format": MCPSchema.enumeration(["jpeg", "png"], "image format", default: "jpeg"),
            ]) { a, _ in a }, required: ["page"]),
            outputSchema: MCPSchema.object([
                "page": MCPSchema.integer("1-based"), "width": MCPSchema.integer("pixels"), "height": MCPSchema.integer("pixels"),
                "mime": MCPSchema.string("image/jpeg or image/png"), "bytes": MCPSchema.integer("encoded size"),
            ]),
            tier: .read
        ) { _, args in
            let target = try await MainActor.run {
                try MCPFacade.shared.resolveTarget(documentId: try args.string("document_id"), path: try args.string("path"),
                                                   workspacePath: try args.string("workspace"))
            }
            let page = try args.int("page") ?? 1
            let width = min(LANServer.snapPageWidth(try args.int("width") ?? 1080), 2160)
            let fmt = try args.string("format") ?? "jpeg"
            guard fmt == "jpeg" || fmt == "png" else { throw MCPInvalidParams("format must be jpeg or png") }
            let format: PageRenderer.Format = fmt == "png" ? .png : .jpeg(quality: PageRenderer.defaultJPEGQuality)
            let reader = MCPDocReader.shared
            let pageCount = try await reader.withDocument(path: target.path) { $0.pageCount }
            let idx = try PageNo.index(page, pageCount: pageCount)
            let img = try await reader.render(path: target.path, index: idx, pixelWidth: width, format: format)
            let r: MCPObject = ["page": page, "width": img.width, "height": img.height, "mime": img.mime, "bytes": img.data.count]
            return MCPToolResult(text: "Page \(page) of “\(target.title)” · \(img.width)×\(img.height) \(fmt)",
                                 structured: r, image: (img.data, img.mime))
        }
    }

    static func readPages() -> MCPTool {
        MCPTool(
            name: "read_pages",
            title: "Read page text",
            description: "Text of one or more pages. Uses the PDF's own text; for scanned pages falls back to OCR text cached by UniReader. Pages with neither come back empty with a hint. At most \(PageNo.maxPagesPerCall) pages per call.",
            inputSchema: MCPSchema.object(targetProperties.merging([
                "pages": MCPSchema.pageSpec,
                "prefer": MCPSchema.enumeration(["auto", "native", "ocr"], "auto = PDF text, OCR only where the page has none; native = PDF text only; ocr = cached OCR only", default: "auto"),
                "max_chars": MCPSchema.integer("Stop after this many characters in total (the last page is cut and truncated=true).", min: 1000, max: 2_000_000),
            ]) { a, _ in a }),
            outputSchema: MCPSchema.object([
                "document_id": MCPSchema.string("library document id, absent for a plain file"),
                "title": MCPSchema.string("title"), "page_count": MCPSchema.integer("pages in the document"),
                "pages": MCPSchema.array(of: MCPSchema.object([
                    "page": MCPSchema.integer("1-based"), "label": MCPSchema.string("printed page label when different"),
                    "source": MCPSchema.enumeration(["native", "ocr", "none"], "where the text came from"),
                    "provider": MCPSchema.string("OCR engine id when source = ocr"),
                    "chars": MCPSchema.integer("characters returned"), "text": MCPSchema.string("page text"),
                    "truncated": MCPSchema.boolean("cut by max_chars")])),
                "truncated": MCPSchema.boolean("output was cut by max_chars"),
                "hint": MCPSchema.string("what to do about pages without text, if any"),
            ]),
            tier: .read
        ) { _, args in
            let target = try await MainActor.run {
                try MCPFacade.shared.resolveTarget(documentId: try args.string("document_id"), path: try args.string("path"),
                                                   workspacePath: try args.string("workspace"))
            }
            let prefer = try args.string("prefer") ?? "auto"
            guard ["auto", "native", "ocr"].contains(prefer) else { throw MCPInvalidParams("prefer must be auto, native or ocr") }
            let maxChars = try args.int("max_chars") ?? 200_000
            let reader = MCPDocReader.shared
            let pageCount = try await reader.withDocument(path: target.path) { $0.pageCount }
            let pages: [Int]
            if let spec = try args.pages("pages") {
                pages = try PageNo.parse(spec, pageCount: pageCount)
            } else {
                pages = [min(max(0, target.currentPage ?? 0), max(0, pageCount - 1))]
            }

            let native = try await reader.nativeTexts(path: target.path, pages: pages)
            var wantOCR: [Int] = []
            switch prefer {
            case "ocr": wantOCR = pages
            case "native": wantOCR = []
            default: wantOCR = native.filter { $0.native.count < MCPDocReader.nativeMinChars }.map(\.index)
            }
            var ocr: [Int: String] = [:]
            if !wantOCR.isEmpty, let store = target.store {
                ocr = await reader.ocrTexts(store: store, contentHash: target.contentHash, pages: wantOCR)
            }

            var items: [MCPObject] = []
            var text: [String] = []
            var used = 0
            var truncated = false
            var missing: [Int] = []
            for p in native {
                var source = "none"
                var body = ""
                if prefer != "ocr", p.native.count >= MCPDocReader.nativeMinChars { source = "native"; body = p.native }
                else if let o = ocr[p.index] { source = "ocr"; body = o }
                else if prefer == "native", !p.native.isEmpty { source = "native"; body = p.native }
                let external = PageNo.external(p.index)
                var cut = false
                if used + body.count > maxChars {
                    body = String(body.prefix(max(0, maxChars - used)))
                    cut = true; truncated = true
                }
                used += body.count
                if source == "none" { missing.append(external) }
                var item: MCPObject = ["page": external, "source": source, "chars": body.count, "text": body]
                if let l = p.label { item["label"] = l }
                if source == "ocr" { item["provider"] = PaddleOCR.providerID }
                if cut { item["truncated"] = true }
                items.append(item)
                var header = "--- Page \(external)"
                if let l = p.label { header += " (label \(l))" }
                header += " · \(source) ---"
                text.append(header)
                text.append(body.isEmpty ? "(no text)" : body)
                if cut {
                    text.append("[truncated by max_chars; continue from page \(external) with a smaller range]")
                    break
                }
            }
            var hint: String? = nil
            if !missing.isEmpty {
                let list = missing.map(String.init).joined(separator: ", ")
                hint = target.store == nil
                    ? "pages \(list) have no text layer (scanned); this file is outside a workspace so no OCR cache is available"
                    : "pages \(list) are scanned and have no OCR text yet; ask the user to run OCR on them in UniReader"
                text.append("Hint: \(hint!)")
            }
            var r: MCPObject = ["title": target.title, "page_count": pageCount, "pages": items, "truncated": truncated]
            if let id = target.documentId { r["document_id"] = id }
            if let hint { r["hint"] = hint }
            return MCPToolResult(text: text.joined(separator: "\n"), structured: r)
        }
    }
}
