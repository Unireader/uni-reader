#!/bin/bash
# 构建服务器自带的网页阅读器（web/，方案 docs/WEB-READER-PLAN.md）→ web/dist/。
# 之后 swift build / scripts/build-linux.sh 时，构建插件 EmbedWebAssets 自动把 web/dist 编进服务器程序。
#
#   scripts/build-web.sh            类型检查 + 测试（对 Mac 代码生成的跨端向量）+ 构建
#
# 依赖由用户安装（cd server/web && pnpm install，锁文件 pnpm-lock.yaml），本脚本不装。
# 下面用 npm run 跑 package.json 里的命令：只是执行，不装东西，pnpm 装的依赖照样能用。
set -euo pipefail
cd "$(dirname "$0")/../web"

if [ ! -d node_modules ]; then
    echo "网页的依赖还没装：请先执行  cd $(pwd) && pnpm install" >&2
    exit 1
fi
npm run check
npm test
npm run build
# 删掉之前编进程序的那份（各种构建方式各一份），下次 swift build 必定按新的 dist 重新生成（见构建插件 EmbedWebAssets 的注释）
find ../.build/plugins/outputs -path '*/UniServerHTTP/*/EmbedWebAssets/EmbeddedWeb.swift' -delete 2>/dev/null || true
echo "$(pwd)/dist"
