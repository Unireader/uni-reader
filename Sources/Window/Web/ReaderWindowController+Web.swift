import AppKit

/// 网页（`docs/WEB-DOC-PLAN.md`）在窗口这一层的入口：导入 / 重新导入一个课件文件夹。
extension ReaderWindowController {

    /// 选一个文件夹（或文件夹里的某个 html：它就是入口页）导入；`replacing` = 重新导入到已有的那份网页。
    func importWebFolder(replacing: String? = nil) {
        guard let win = window, win.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.html, .folder]
        panel.allowsMultipleSelection = false
        panel.prompt = L("Import")
        panel.message = replacing == nil
            ? L("Choose the folder of a web page (its HTML files, images, styles and scripts), or the HTML file to open first.")
            : L("Choose the new version of this web page’s folder. What the page has stored is kept.")
        panel.beginSheetModal(for: win) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            DispatchQueue.main.async { self?.runWebImport(url, replacing: replacing) }
        }
    }

    private func runWebImport(_ url: URL, replacing: String?) {
        guard let win = window else { return }
        let progress = WebImportProgressSheet()
        let sheet = NSWindow(contentViewController: progress)
        win.beginSheet(sheet)
        let ws = workspace
        Task { @MainActor [weak self] in
            do {
                let doc = try await ws.importWebFolder(url, replacing: replacing) { i, n in
                    DispatchQueue.main.async { progress.update(done: i, total: n) }
                }
                win.endSheet(sheet)
                self?.tabs.openWebDoc(doc.id)
            } catch {
                win.endSheet(sheet)
                self?.presentError(error.localizedDescription)
            }
        }
    }
}

/// 导入时的进度（复制课件里的文件，大的课件要几秒）。
final class WebImportProgressSheet: NSViewController {
    private let label = NSTextField(labelWithString: L("Copying the web page into the workspace…"))
    private let bar = NSProgressIndicator()

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 90))
        label.textColor = .labelColor
        bar.isIndeterminate = true
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.startAnimation(nil)
        for s in [label, bar] as [NSView] {
            s.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(s)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: v.topAnchor, constant: 20),
            bar.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            bar.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -20),
            bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
        ])
        view = v
    }

    func update(done: Int, total: Int) {
        guard total > 0 else { return }
        if bar.isIndeterminate {
            bar.stopAnimation(nil)
            bar.isIndeterminate = false
        }
        bar.doubleValue = Double(done) / Double(total)
        label.stringValue = String(format: L("Copying the web page into the workspace… %d / %d files"), done, total)
    }
}
