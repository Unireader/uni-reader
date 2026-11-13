import AppKit
import Foundation

/// ```anim 分步演示块的工具（`ANIM-BLOCK-PLAN.md §4.4`，2026-11-13）：写法说明 + 出图查错。只读，不碰工作区。
extension MCPTools {

    /// 写进 MCP 说明与 App 内 Agent 上下文的一句（同 `graphWriting`）。
    static let animWriting = "Step-by-step animations in Markdown notes (not in PDF text notes): a fenced block whose language is anim describes elements (time-sequence lanes, sequence-number windows, arrays, stacks, queues, variables) and numbered steps of actions; the reader plays it step by step. Use one when a process is easier to follow as it unfolds — protocols (stop-and-wait, sliding window, go-back-N, selective repeat), algorithm traces, data structure operations. Read get_anim_reference before writing one, check the text with render_anim (errors by line, and an image), then write it with edit_markdown like any other text."

    static func getAnimReference() -> MCPTool {
        MCPTool(
            name: "get_anim_reference",
            title: "anim block reference",
            description: "The full syntax of ```anim blocks (step-by-step animations in Markdown notes) with examples. Read it before writing or changing an anim block.",
            inputSchema: MCPSchema.object([:]),
            outputSchema: MCPSchema.object(["reference": MCPSchema.string("Markdown text")]),
            tier: .read
        ) { _, _ in
            MCPToolResult(text: AnimText.reference, structured: ["reference": AnimText.reference])
        }
    }

    static func renderAnim() -> MCPTool {
        MCPTool(
            name: "render_anim",
            title: "Render an anim block",
            description: "Check the text of an ```anim block (without the fence lines) and draw it: lists errors by line (a line with an error is skipped when shown) and returns an image — one step, or with no step given a contact sheet of every step so you can check the whole sequence at once. Does not touch any note.",
            inputSchema: MCPSchema.object([
                "text": MCPSchema.string("The block's text, without the ```anim and ``` lines."),
                "step": MCPSchema.integer("Draw only this step (0 = the initial picture). Omit for all steps.", min: 0),
                "width": MCPSchema.integer("Block width in points (default 640; the note shows it between 280 and 720)", min: 280, max: 720),
                "dark": MCPSchema.boolean("Dark appearance", default: false),
            ], required: ["text"]),
            outputSchema: MCPSchema.object([
                "steps": MCPSchema.integer("number of steps, not counting step 0"),
                "scenes": MCPSchema.integer("scenes"),
                "errors": MCPSchema.array(of: MCPSchema.object(["line": MCPSchema.integer("1-based line in the text"), "message": MCPSchema.string("what is wrong")])),
                "width": MCPSchema.integer("pixels"), "height": MCPSchema.integer("pixels"),
            ]),
            tier: .read
        ) { _, args in
            let text = try args.requiredString("text")
            guard text.utf8.count <= 60_000 else { throw MCPInvalidParams("text is too long") }
            let step = try args.int("step")
            let width = CGFloat(min(max(try args.int("width") ?? 640, 280), 720))
            let dark = try args.bool("dark", default: false)
            let run = AnimEngine.run(text)
            if let step, step >= run.stepCount { throw MCPInvalidParams("step \(step) does not exist (0…\(run.stepCount - 1))") }
            let image: CGImage? = await MainActor.run {
                if let step { return AnimSnapshot.image(run: run, width: width, step: step, dark: dark, scale: 2, controls: false) }
                return AnimSnapshot.contactSheet(run: run, width: width, dark: dark, scale: 1.5)
            }
            guard let image, let data = PageRenderer.encode(image, format: .png) else { throw MCPToolError("cannot render the block") }
            let errors: [MCPObject] = run.errors.map { ["line": $0.line, "message": $0.message] }
            var lines = ["\(run.stepCount - 1) step(s), \(run.script.scenes.count) scene(s), \(image.width)×\(image.height) png"]
            lines += run.errors.isEmpty ? ["No errors."] : run.errors.map { "Line \($0.line): \($0.message)" }
            let o: MCPObject = ["steps": run.stepCount - 1, "scenes": run.script.scenes.count, "errors": errors,
                                "width": image.width, "height": image.height]
            return MCPToolResult(text: lines.joined(separator: "\n"), structured: o, image: (data, "image/png"))
        }
    }
}
