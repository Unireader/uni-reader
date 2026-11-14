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
        """
        title Reverse a linked list
        list L = 1 -> 2 -> 3
        pointer prev
        pointer cur -> L[0]
        step 1 now points back to prev (null); move both pointers forward
          link L[0] -> null
          move prev -> L[0]
          move cur -> L[1]
        step 2 points back to 1
          link L[1] -> L[0]
          move prev -> L[1]
          move cur -> L[2]
        step 3 points back to 2; prev is the new head
          link L[2] -> L[1]
          move prev -> L[2]
          move cur -> null
          mark L[2] done
        """,
        """
        title BST: insert 5, then rotate right at 8
        tree T = (8 (3 1 6) (10 _ 14))
        pointer p -> T[8]
        step 5 < 8: go left
          mark T[8] active
          move p -> T[3]
        step 5 > 3: go right
          unmark T[8]
          mark T[3] active
          move p -> T[6]
        step 5 < 6: becomes the left child of 6
          unmark T[3]
          insert T 5 under 6 left
          move p -> null
        step Rotate right at 8: 3 becomes the root
          rotate T 8 right
        """,
        """
        title Breadth-first search from A
        graph G = A-B, A-C, B-D, C-D, D-E
        queue Q = [A]
        step Visit A, put its neighbors B and C in the queue
          dequeue Q
          mark G[A] done
          set G[A] = "d=0"
          mark G[A-B] active
          mark G[A-C] active
          enqueue Q B
          enqueue Q C
        step Visit B: D is new
          dequeue Q
          mark G[B] done
          set G[B] = "d=1"
          mark G[B-D] active
          enqueue Q D
        step Visit C: D is already queued
          dequeue Q
          mark G[C] done
          set G[C] = "d=1"
          mark G[C-D] muted
        """,
        """
        title Edit distance table: "ab" vs "ac"
        grid D rows=[-, a, b] cols=[-, a, c] = [[0, 1, 2], [1, , ], [2, , ]]
        pointer here -> D[1,1]
        step a = a: copy the diagonal
          mark D[0,0] active
          set D[1,1] = 0
        step a ≠ c: 1 + min of the three neighbors
          unmark D[0,0]
          mark D[0..1,1] active
          move here -> D[1,2]
          set D[1,2] = 1
        step Fill the last row the same way
          unmark D[0..1,1]
          move here -> D[2,2]
          set D[2,1] = 1
          set D[2,2] = 1
          mark D[2,2] done
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
    | `list NAME = a -> b -> c` | linked list; arrows follow each node's next (a null next shows ∅) |
    | `tree NAME = (8 (3 1 6) (10 _ 14))` | tree in bracket form: `(value child child …)`; `_` is an empty child, so `(10 _ 14)` has only a right child. Binary trees: first child = left, second = right. |
    | `graph NAME [layout=circle\\|layers] = A-B:4, B-C, A->C` | graph: `-` undirected, `->` directed, `:w` weight, a lone `D` adds a node. `layers` puts nodes in breadth-first columns from the first node. |
    | `grid NAME [rows=[…]] [cols=[…]] = 3x4` or `= [[1, 2], [3, 4]]` | 2-D table (DP tables), optional row / column headers; empty cells allowed (`[1, , 3]`) |
    | `sheet NAME` | a worksheet for hand calculations written row by row (long division, base conversion, binary arithmetic): one character per cell in aligned columns, plus rules, bring-down arrows and row notes (see the sheet actions). Lines `write` / `rule` / `arrow` / `label` / `mark` placed before the first `step` are the starting picture. |
    | `pointer NAME -> TARGET` / `pointer NAME` | a labeled arrow to an array index (may be one past the end), a list node, a tree node, a graph node or a grid cell |
    | `row X Y …` | put already declared elements side by side on one row |
    Elements are stacked top to bottom in declaration order.

    ## Actions (inside a step)
    Targets: `A` (whole element), `A[2]` (one cell), `A[1..3]` (a range), a var name, or a message's `as=` name. \
    For a `seq`, indexes are the sequence numbers themselves (`SW[2..5]`). Lists use positions (`L[0]`); trees use node \
    VALUES (`T[8]`, first match); graphs use node names and edges (`G[A]`, `G[A-B]`, `G[A->B]`); grids and sheets use \
    `D[row,col]` and ranges like `D[0..2,1]` (0-based).
    | action | effect |
    |---|---|
    | `mark TARGET STATE` | color state, kept until changed: `normal`, `active` (blue, "looking at this"), `done` (green), `wrong` (red), `muted` (gray), `new` (orange) |
    | `unmark TARGET` | back to normal |
    | `set TARGET = VALUE` | change a var or array cell |
    | `swap A[i] A[j]` | exchange two cells (animated as the values trading places) |
    | `push S v` / `pop S` | stack |
    | `enqueue Q v` / `dequeue Q` | queue (new cells are orange for one step) |
    | `say "…"` | a highlighted remark shown only during this step |
    | `insert L 2 x` / `remove L 2` | list: insert at / remove the node at position 2 (links are kept consistent) |
    | `link L[2] -> L[0]` / `link L[2] -> null` | list: change where a node's next points (reversal, cycles) |
    | `insert T 5 under 6 left\\|right` / `insert T 5` | tree: add a child (without a side: append as the last child; without `under`: the root of an empty tree) |
    | `remove T 14` | tree: remove that node and its subtree |
    | `rotate T 8 left\\|right` | binary tree rotation at node 8 (the animation shows nodes moving to their new places) |
    | `swap T[8] T[3]` | tree: exchange two node values (heaps) |
    | `set G[A] = "d=3"` / `set G[A-B] = 7` | graph: a small label under a node / an edge weight |
    | `set D[1,2] = 5` | grid cell (a range fills every cell in it) |
    | `write S[2,5] "1101"` | sheet: write characters from row 2, column 5 rightwards (0-based; a space leaves that cell alone) |
    | `rule S[2,5..8]` / `rule S[1,5..13] above` | sheet: a line under (or above) those columns of a row — the subtraction line, or the division bar |
    | `arrow S[1..3,9]` | sheet: a dashed arrow down column 9 from row 1 to row 3 (bringing a digit down) |
    | `label S[0] "← quotient"` | sheet: a note after the end of a row |
    | `move p -> A[3]` / `move p -> null` | move a pointer (it slides); `mark p wrong` recolors it |
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

    ## Kits: one line, steps worked out for you
    `kit NAME options…` expands into a whole scene (elements and every step) computed by the algorithm itself, so the \
    result is always correct. Prefer a kit whenever the user's question matches one; write steps by hand only for \
    things no kit covers. A kit gives the block a title if it has none; inside `scene` it fills that scene (compare \
    protocols by putting one kit in each scene). Captions follow the system language; add `lang=zh` or `lang=en` to choose.
    | kit | options | shows |
    |---|---|---|
    | `stopwait` / `gbn` / `sr` | `frames=6` `window=4` `lose=2,5` (first transmission of those frames is lost) `loseack=3` (first ACK for 3 is lost) `timeout=2` (rounds) `mod=8` | stop-and-wait, go-back-N, selective repeat on a time-sequence diagram with sender / receiver windows, timers, retransmissions |
    | `bubble` / `selection` / `insertion` / `quick` | `A=[5, 1, 4, 2]` (2–8 values; numbers compare as numbers) | every comparison and swap with pointers; quicksort uses the last element as pivot |
    | `crc` | `data=101001 gen=1101` | the textbook long division (a sheet): quotient on top, one XOR per step with its line, digits brought down, the remainder as FCS |
    | `preorder` / `inorder` / `postorder` / `levelorder` | `T=(8 (3 1 6) (10 _ 14))` (distinct values) | the visiting order on the tree and the output sequence |
    | `bfs` / `dfs` | `G="A-B, A-C, B-D"` `from=A` | queue / stack, discovered edges, visiting order (neighbors in the order the edges are written) |
    | `dijkstra` | `G="A-B:4, A-C:2, C-B:1"` `from=A` (weights ≥ 0) | distances under each node, relaxations, the shortest-path tree |
    | `page` | `alg=fifo\\|lru\\|opt\\|clock` `refs=7,0,1,2,0,3` (≤ 20) `frames=3` | OS page replacement: the textbook table (accesses × frames, faults marked √), why each page is evicted, the fault rate |
    | `disk` | `alg=fcfs\\|sstf\\|scan\\|cscan\\|look\\|clook` `start=100` `requests=55,58,39` `dir=up\\|down` `max=199` | OS disk scheduling: the head moving over the sorted tracks, total and average seek length (C-SCAN / C-LOOK count the return jump) |
    | `cache` | `map=direct\\|full\\|set` `lines=8` `ways=2` `blocks=0,4,8,0` `replace=lru\\|fifo` | cache mapping: line / set index (b mod …), tag, hit or miss, which block is replaced, the hit rate |
    | `base` | `n=156` `to=2` (2–16) | base conversion by repeated division (a sheet), remainders read bottom to top |
    | `kmp` | `P=ababaa` `nextval=yes\\|no` | KMP next / nextval arrays (1-based, as in most Chinese textbooks), every i / j move explained |
    | `hash` | `keys=19,14,23` `size=13` `p=13` `probe=linear\\|quadratic` | hash table with open addressing: collisions, probe counts, successful ASL |
    | `heap` | `A=[53, 17, 78, 9]` (distinct, ≤ 15) `type=max\\|min` `sort=no\\|yes` | building a heap by sifting down (tree and array together), optionally heap sort |
    | `bsearch` | `A=[7, 10, 13]` (sorted) `key=13` | binary search with low / high / mid pointers |
    | `tcp` | `ssthresh=16` `rounds=20` `timeout=12` `dup=17` | TCP congestion control: cwnd per round (slow start / congestion avoidance colors), timeout and 3-duplicate-ACK reactions |
    ```
    title Frame 2 lost: three protocols
    scene Stop-and-wait
      kit stopwait frames=3 lose=2
    scene Go-back-N
      kit gbn frames=6 window=3 lose=2
    scene Selective repeat
      kit sr frames=6 window=3 lose=2
    ```
    render_anim on a block with kits also returns the expanded text, which you can paste and edit if the user wants \
    something the kit does not do.

    ## Checking
    Call render_anim with the text before writing it into a note: it lists errors by line and returns an image \
    (one step, or a contact sheet of all steps). Fix every error — a line with an error is skipped.

    ## Examples
    \(examples.map { "```anim\n\($0)\n```" }.joined(separator: "\n\n"))
    """
}
