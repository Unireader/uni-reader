// 运行：把本文件复制成 main.swift，与 Sources/App/MarkdownOutline.swift 一起 swiftc 编译执行
import Foundation
var fails = 0
func check(_ c: Bool, _ m: String) { if !c { fails += 1; print("FAIL", m) } }
let t = """
---
title: x
# not heading
---
# 一级 #
## 二级
#tag
```
# code
```
   ### 三级 ##
####### 七
~~~
## in tilde
~~~
## 末尾
"""
let h = MarkdownOutline.headings(in: t)
check(h.map(\.title) == ["一级", "二级", "三级", "末尾"], "titles \(h.map(\.title))")
check(h.map(\.level) == [1, 2, 3, 2], "levels")
let tree = MarkdownOutlineNode.tree(from: h)
check(tree.count == 1 && tree[0].children.count == 2 && tree[0].children[0].children.count == 1, "tree")
print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
