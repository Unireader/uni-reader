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
            description: "Show a library document in a reader tab (activates the tab if it is already open, otherwise opens one in a window of its workspace). Optionally jump to a page. Only documents already in a workspace library: importing a new PDF is a separate (write) tool.",
            inputSchema: MCPSchema.object([
                "document_id": MCPSchema.string("Library document id from list_documents."),
                "workspace": MCPSchema.string("Workspace .unrd path, only when the id is ambiguous across open workspaces."),
                "window_id": MCPSchema.string("Open in this window (from get_state). Default: the window already showing it, else the workspace's key window."),
                "page": MCPSchema.integer("Jump to this page after opening (1-based).", min: 1),
                "activate": MCPSchema.boolean("Bring UniReader and the window to front", default: true),
            ], required: ["document_id"]),
            outputSchema: MCPSchema.object([
                "session_id": MCPSchema.string("tab / session id"), "window_id": MCPSchema.string("window id"),
                "document": documentDTOSchema, "page": MCPSchema.integer("current page, 1-based"),
            ]),
            tier: .navigate
        ) { _, args in
            let id = try args.requiredString("document_id")
            let wsPath = try args.string("workspace")
            let windowId = try args.string("window_id")
            let page = try args.int("page")
            let activate = try args.bool("activate", default: true)
            let r = try await MainActor.run {
                try MCPFacade.shared.openDocument(documentId: id, workspacePath: wsPath, windowId: windowId, page: page, activate: activate)
            }
            let doc = (r["document"] as? MCPObject) ?? [:]
            return MCPToolResult(text: "Opened “\(doc["title"] ?? "")” at page \(r["page"] ?? 1) · session_id \(r["session_id"] ?? "") · window_id \(r["window_id"] ?? "")",
                                 structured: r)
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
