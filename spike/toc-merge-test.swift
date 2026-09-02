// TOCMerge 纯函数测试：书签按页号挂进一级目录组的落位规则（`REQUIREMENTS.md §1.9`）。运行：
//   cp spike/toc-merge-test.swift /tmp/main.swift && swiftc Sources/App/TOCMerge.swift /tmp/main.swift -o /tmp/tmt && /tmp/tmt
// （须命名为 main.swift：swiftc 多文件时顶层代码只允许在 main.swift）
// 覆盖：归组（区间左闭右开 / 组前平铺 / 无目录平铺 / 目录先序页号乱序）、
//       组内位置（插在第一个更大页号的直接子项之前 / 跳过坏书签子项 / 落到子树末尾 /
//       孙子项不参与比较）、同页多枚保序、边界（空输入 / 只有坏书签的目录）。
import Foundation

var pass = 0, fail = 0
func check(_ c: Bool, _ m: String) { if c { pass += 1; print("  ✅ \(m)") } else { fail += 1; print("  ❌ \(m)") } }

func row(_ d: Int, _ p: Int?) -> TOCMerge.Row { TOCMerge.Row(depth: d, page: p) }

/// 一棵典型目录：
///  0: 第一章 p0
///  1:   1.1  p2
///  2:   1.2  p8
///  3:     1.2.1 p9      ← 孙子项，不参与「直接子项」比较
///  4: 第二章 p20
///  5:   2.1  p22
let tree: [TOCMerge.Row] = [
    row(0, 0), row(1, 2), row(1, 8), row(2, 9), row(0, 20), row(1, 22),
]

print("归组（区间左闭右开）")
do {
    let s = TOCMerge.place(rows: tree, bookmarkPages: [0])
    check(s[0].owner == 0 && s[0].depth == 1, "书签 p0 → 挂第一章（边界左闭：等于组页号也算这一组）")
    let s2 = TOCMerge.place(rows: tree, bookmarkPages: [19])
    check(s2[0].owner == 0, "书签 p19 → 仍属第一章（右开：小于第二章 p20）")
    let s3 = TOCMerge.place(rows: tree, bookmarkPages: [20])
    check(s3[0].owner == 4 && s3[0].depth == 1, "书签 p20 → 挂第二章")
    let s4 = TOCMerge.place(rows: tree, bookmarkPages: [99])
    check(s4[0].owner == 4, "书签 p99（超出最后一组）→ 挂最后一个一级组")
}

print("没组可挂就平铺树顶")
do {
    // 第一章从 p5 起，书签在 p1
    let late: [TOCMerge.Row] = [row(0, 5), row(1, 6)]
    let s = TOCMerge.place(rows: late, bookmarkPages: [1])
    check(s[0].owner == nil && s[0].depth == 0 && s[0].insertBefore == 0,
          "书签页号早于第一个一级组 → 树顶第 0 行，depth=0")
    let none = TOCMerge.place(rows: [], bookmarkPages: [3])
    check(none[0].owner == nil && none[0].insertBefore == 0, "整本书没目录 → 树顶")
    // 目录里一个可用的一级组都没有（全是坏书签）
    let dead: [TOCMerge.Row] = [row(0, nil), row(1, 4)]
    let s2 = TOCMerge.place(rows: dead, bookmarkPages: [7])
    check(s2[0].owner == nil && s2[0].depth == 0, "一级组全是坏书签 → 树顶（不挂到没页号的组上）")
}

print("组内位置")
do {
    let s = TOCMerge.place(rows: tree, bookmarkPages: [5])
    check(s[0].insertBefore == 2, "书签 p5 → 插在 1.2(p8) 之前（第一个更大页号的直接子项）")
    let s2 = TOCMerge.place(rows: tree, bookmarkPages: [3])
    check(s2[0].insertBefore == 2, "书签 p3 → 同上（p2 不大于它，跳过）")
    let s3 = TOCMerge.place(rows: tree, bookmarkPages: [1])
    check(s3[0].insertBefore == 1, "书签 p1 → 插在 1.1(p2) 之前")
    let s4 = TOCMerge.place(rows: tree, bookmarkPages: [12])
    check(s4[0].insertBefore == 4, "书签 p12 → 该组无更大的直接子项 → 排在子树末尾（第二章之前）")
    let s5 = TOCMerge.place(rows: tree, bookmarkPages: [30])
    check(s5[0].insertBefore == tree.count, "书签 p30 → 最后一组的子树末尾 = 整表末尾")
}

print("孙子项不参与比较")
do {
    // 1.2.1 是 p9（depth=2）。书签 p8.5 → 只跟 depth==1 的比：1.1(p2)、1.2(p8) 都不大于它
    // → 落到子树末尾（即 1.2.1 之后），而**不是**插在 1.2.1 之前。
    let s = TOCMerge.place(rows: tree, bookmarkPages: [8])
    check(s[0].insertBefore == 4, "书签 p8 → 子树末尾（孙子项 p9 不参与比较）")
}

print("坏书签子项跳过顺延")
do {
    //  0: 第一章 p0 / 1: 1.1 坏 / 2: 1.2 p8
    let withDead: [TOCMerge.Row] = [row(0, 0), row(1, nil), row(1, 8)]
    let s = TOCMerge.place(rows: withDead, bookmarkPages: [5])
    check(s[0].insertBefore == 2, "书签 p5 → 跳过没页号的 1.1，插在 1.2(p8) 之前")
}

print("目录先序页号乱序时仍按页号取边界")
do {
    //  0: 附录 p90 / 1: 正文 p10（先序颠倒）
    let messy: [TOCMerge.Row] = [row(0, 90), row(0, 10)]
    let s = TOCMerge.place(rows: messy, bookmarkPages: [20])
    check(s[0].owner == 1, "书签 p20 → 挂「正文 p10」（按页号排边界，不按先序）")
    let s2 = TOCMerge.place(rows: messy, bookmarkPages: [95])
    check(s2[0].owner == 0, "书签 p95 → 挂「附录 p90」")
}

print("同页多枚保序 + 一一对应")
do {
    let s = TOCMerge.place(rows: tree, bookmarkPages: [5, 5, 5])
    check(s.count == 3, "落位表与输入等长")
    check(s.allSatisfy { $0.insertBefore == 2 && $0.owner == 0 }, "同页三枚落在同一处（调用方按序插入即保序）")
    let empty = TOCMerge.place(rows: tree, bookmarkPages: [])
    check(empty.isEmpty, "没有书签 → 空落位表")
}

print("\n通过 \(pass) / 失败 \(fail)")
if fail > 0 { exit(1) }
