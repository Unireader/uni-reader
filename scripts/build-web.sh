#!/bin/bash
# 采集页（web/，Svelte + Vite）构建并回写 macOS 资源：dist 单文件 → Sources/Resources/capture.html。
# 产物里 __WS_PORT__/__TOKEN__/__PENS__ 占位符原样保留，由 Mac 端 CapturePage.swift 运行时替换。
set -euo pipefail
cd "$(dirname "$0")/../web"

npm install
npm run build   # → dist/index.html（JS/CSS 全内联的单文件，wire.js 已打进 bundle）

# 契约自检：占位符必须在产物里原样存在，否则 Mac 端注入会静默失效 → 宁可失败也不覆盖资源
for ph in __WS_PORT__ __TOKEN__ __PENS__; do
  grep -q "$ph" dist/index.html || { echo "构建产物缺少占位符 $ph，拒绝覆盖 capture.html"; exit 1; }
done

cp dist/index.html ../Sources/Resources/capture.html
echo "OK: Sources/Resources/capture.html 已更新（单文件，wire.js 已内嵌）"
