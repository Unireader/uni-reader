#!/bin/bash
# UniReader webview 内存实测。
#
#   ./ai-mem.sh mark          # ① 面板还没开的时候先打个基准（记下此刻已有的 WebContent 进程）
#   ./ai-mem.sh "开了浮窗"     # ② 之后每变一次形态跑一次，看新增了什么
#
# ⚠️ 两个坑，不绕开就会量错：
#  · WKWebView 的内容跑在**独立进程**（com.apple.WebKit.WebContent）里，
#    活动监视器里 UniReader 那一行**不含它**。
#  · `ps` 的 RSS 严重低估：UniReader 自己 RSS 82MB，footprint 1361MB
#    （CoreAnimation + CG raster 是阅读区的页图缓存）。**看 footprint，别看 RSS。**
#  · WebContent 的 ppid 是 1（launchd 起的），没法靠父子关系归属 → 所以用 mark 取增量。

MARK=/tmp/unireader-webcontent.mark

content_pids() { ps -Ao pid=,comm= | awk '/com\.apple\.WebKit\.WebContent/ {print $1}' | sort; }

# footprint 输出形如 "UniReader [37228]: 64-bit    Footprint: 1361 MB"，也可能是 GB
fp_mb() {
    # 行形如：UniReader [37228]: 64-bit    Footprint: 1361 MB (16384 bytes per page)
    # 数值和单位在 "Footprint:" 后面两格，**不是**行尾（行尾是 "page)"）。
    footprint -p "$1" 2>/dev/null | awk '
        /Footprint:/ { for (i=1; i<=NF; i++) if ($i == "Footprint:") { v=$(i+1); u=$(i+2); break }
                       if (u=="GB") v=v*1024; else if (u=="KB") v=v/1024;
                       printf "%.0f", v; exit }'
}

if [ "$1" = "mark" ]; then
    content_pids > "$MARK"
    echo "基准已记：此刻系统里有 $(wc -l < "$MARK" | tr -d ' ') 个 WebContent 进程（都不算 UniReader 的）"
    echo "现在去开 AI 面板，再跑：./ai-mem.sh \"开了浮窗\""
    exit 0
fi

app_pid=$(pgrep -x UniReader | head -1)
[ -z "$app_pid" ] && { echo "UniReader 没在跑"; exit 1; }
[ -f "$MARK" ] || { echo "还没打基准，先跑：./ai-mem.sh mark"; exit 1; }

printf '\n===== %s =====\n' "${1:-未命名}"
printf '  UniReader 本体(pid %s)     %6s MB   ← 含阅读区页图缓存，与 webview 无关\n' \
       "$app_pid" "$(fp_mb "$app_pid")"

new=$(comm -13 "$MARK" <(content_pids))
if [ -z "$new" ]; then
    printf '  WebContent               （没有新增进程 —— 复用了已有的，或面板还没加载）\n\n'
    exit 0
fi

total=0; n=0
for pid in $new; do
    mb=$(fp_mb "$pid"); [ -z "$mb" ] && mb=0
    n=$((n+1)); total=$((total+mb))
    printf '  WebContent #%d (pid %-6s)  %6s MB\n' "$n" "$pid" "$mb"
done
printf '  %-26s %6s MB   ← 这才是 AI 面板真正多吃的\n\n' "新增合计（$n 个进程）" "$total"
