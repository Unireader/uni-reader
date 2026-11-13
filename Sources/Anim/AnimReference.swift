import Foundation

// ```anim 块的写法全文（MCP `get_anim_reference` 原样给 Agent；`ANIM-BLOCK-PLAN.md §3` 以它为准）。
// 示例都要能无错运行：`spike/anim-test.swift` 逐个检查。

extension AnimText {
    static let examples: [String] = [
        """
        title Go-Back-N: window 4, frame 2 lost
        lanes Sender Receiver
        seq SW 0..7 window=4 at=Sender
        var expected = 0

        step Send frames 0-3 without waiting
          send Sender -> Receiver "0"
          send Sender -> Receiver "1"
          send Sender -> Receiver "2" lost
          timer Sender "T2" start
          send Sender -> Receiver "3"
        step Receiver accepts 0 and 1; 3 is out of order and discarded
          deliver Receiver "0"
          deliver Receiver "1"
          set expected = 2
          discard Receiver "3"
          send Receiver -> Sender "ACK 0"
          send Receiver -> Sender "ACK 1"
        step ACK 1 arrives: window slides to 2-5, send 4 and 5
          slide SW to=2
          send Sender -> Receiver "4"
          send Sender -> Receiver "5"
        step Timer for frame 2 expires: go back and resend 2-5
          timer Sender "T2" expire
          mark SW[2..5] active
          send Sender -> Receiver "2"
          send Sender -> Receiver "3"
          send Sender -> Receiver "4"
          send Sender -> Receiver "5"
        """,
        """
        title Bubble sort, first pass
        array A = [5, 1, 4, 2]
        var i = 0
        step Compare A[0] and A[1]: 5 > 1, swap
          mark A[0..1] active
          swap A[0] A[1]
        step Compare A[1] and A[2]: 5 > 4, swap
          unmark A[0]
          set i = 1
          swap A[1] A[2]
        step Compare A[2] and A[3]: 5 > 2, swap
          unmark A[1]
          set i = 2
          swap A[2] A[3]
        step 5 is in its final place
          unmark A[2]
          mark A[3] done
          say "After one pass the largest value has bubbled to the end."
        """,
        """
        title Stack vs queue
        stack S = []
        queue Q = []
        row S Q
        step Put in 1, 2, 3
          push S 1
          push S 2
          push S 3
          enqueue Q 1
          enqueue Q 2
          enqueue Q 3
        step Take one out: the stack gives 3 (last in), the queue gives 1 (first in)
          pop S
          dequeue Q
        """,
        """
        title Stop-and-wait vs selective repeat
        scene Stop-and-wait
          lanes A B
          step Send frame 0 and wait
            send A -> B "0" lost
            timer A "T0" start
          step Timeout: resend 0
            timer A "T0" expire
            send A -> B "0"
            deliver B "0"
        scene Selective repeat
          lanes A B
          seq W 0..5 window=3 at=A
          step Send 0, 1, 2
            send A -> B "0" lost
            send A -> B "1"
            send A -> B "2"
            timer A "T0" start
          step B buffers 1 and 2; only 0 is resent after its timer expires
            buffer B "1"
            buffer B "2"
            timer A "T0" expire
            send A -> B "0"
            deliver B "0 1 2"
            slide W to=3
        """,
    ]

    static let reference: String = """
    # UniReader ```anim blocks — step-by-step animations in Markdown notes

    A fenced code block whose language is `anim` is drawn as a step-by-step animation the reader can play, pause \
    and step through (prev / next / slider). You describe WHAT exists and WHAT HAPPENS in each step; layout, colors \
    and motion are automatic. Never give coordinates or colors.

    ## Shape of a block
    ```
    title <text>                 (optional, first line)
    <element declarations>       (what is on screen at step 0)
    step <caption>               (each step: one caption line, then its actions)
      <action>
      ...
    step <caption>
      ...
    ```
    One statement per line. `#` starts a comment (outside quotes). Indentation is for readability only. \
    Names: letters, digits, `_` or CJK; no spaces. Text with spaces goes in "double quotes". \
    Step 0 is the initial picture (no caption). Keep steps small: one idea per step, 3–12 steps in total.

    ## Elements (declare before the first `step`)
    | declaration | draws |
    |---|---|
    | `lanes A B [C …]` | time-sequence diagram: one vertical line per party, time flows down; messages are slanted arrows. One per scene. |
    | `seq NAME 0..7 window=4 [mod=8] [at=LANE]` | sequence-number strip with a window bracket; numbers outside the window are dimmed. `at=` puts it under a lane's name; `mod=` shows numbers modulo N. |
    | `array NAME = [3, 1, 4]` | a row of cells with indexes below |
    | `stack NAME = [a, b]` | vertical stack, last item on top |
    | `queue NAME = [a, b]` | horizontal queue, front on the left |
    | `var NAME = VALUE` | a small "name = value" box |
    | `text "…"` | a line of explanatory text |
    | `row X Y …` | put already declared elements side by side on one row |
    Elements are stacked top to bottom in declaration order.

    ## Actions (inside a step)
    Targets: `A` (whole element), `A[2]` (one cell), `A[1..3]` (a range), a var name, or a message's `as=` name. \
    For a `seq`, indexes are the sequence numbers themselves (`SW[2..5]`).
    | action | effect |
    |---|---|
    | `mark TARGET STATE` | color state, kept until changed: `normal`, `active` (blue, "looking at this"), `done` (green), `wrong` (red), `muted` (gray), `new` (orange) |
    | `unmark TARGET` | back to normal |
    | `set TARGET = VALUE` | change a var or array cell |
    | `swap A[i] A[j]` | exchange two cells (animated as the values trading places) |
    | `push S v` / `pop S` | stack |
    | `enqueue Q v` / `dequeue Q` | queue (new cells are orange for one step) |
    | `say "…"` | a highlighted remark shown only during this step |
    | `send A -> B "label" [as=NAME] [lost] [state=STATE] [arrive=next]` | a message from lane A to B. Several sends in one step leave one after another (pipelining). `lost` = crosses out half way. `arrive=next` = still in flight at the end of this step, arrives in the next. |
    | `slide SEQ to=N` / `slide SEQ by=N` | move the window |
    | `timer LANE "T0" start\\|stop\\|expire` | a timer bar beside the lane; `expire` draws a timeout |
    | `deliver LANE "label"` / `discard LANE "label"` / `buffer LANE "label"` | receiver-side event beside the lane (green ✓ / red ✕ / orange ▣) |
    | `note LANE "label" [state=STATE]` | any other remark beside a lane |
    Timing in a diagram: everything on one lane happens in order; an event on a lane in the same step as an incoming \
    message happens after that message arrives. So write events in the order they happen and the picture follows.

    ## Comparing: several scenes in one block
    ```
    title …
    scene <name>
      <elements>
      step …
    scene <name>
      …
    ```
    Scenes share one set of playback controls and advance together by step number; a scene with fewer steps stays on \
    its last step. Side by side when wide enough, otherwise stacked. Make step N of every scene describe the same moment.

    ## Checking
    Call render_anim with the text before writing it into a note: it lists errors by line and returns an image \
    (one step, or a contact sheet of all steps). Fix every error — a line with an error is skipped.

    ## Examples
    \(examples.map { "```anim\n\($0)\n```" }.joined(separator: "\n\n"))
    """
}
