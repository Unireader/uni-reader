#!/opt/homebrew/bin/bash
# 编译并依次跑三个模型（先跑 setup.sh）。用法：bash run.sh [索引.sqlite] [额外参数，如 --show]
# 不给索引就取 ~/Library/Application Support/UniReader/SearchIndex/ 里最大的那个。
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="$root/build/dev/embed-bench"
models="$out/models"

index="${1:-}"
if [[ -z "$index" || "$index" == --* ]]; then
    # shellcheck disable=SC2012  # 文件名是 UUID，没有怪字符
    index="$(ls -S "$HOME/Library/Application Support/UniReader/SearchIndex/"*.sqlite | head -1)"
else
    shift
fi

cd "$here"
xcodebuild -scheme EmbedBench -destination 'platform=macOS' -configuration Release \
    -derivedDataPath "$out" build -quiet
bin="$out/Build/Products/Release/EmbedBench"

for m in qwen3-0.6b-4bit:qwen3 qwen3-0.6b-bf16:qwen3 bge-m3-fp16:bge; do
    echo
    echo "################ ${m%%:*}"
    "$bin" "$index" "$models/${m%%:*}" "${m##*:}" "$@" 2>&1 | tee "$out/result-${m%%:*}.txt"
done
