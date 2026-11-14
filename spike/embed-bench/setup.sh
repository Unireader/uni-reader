#!/opt/homebrew/bin/bash
# 嵌入模型对比测试的准备（用户自己跑）：拉 SPM 依赖 + 从 hf-mirror.com 下三个模型。
# 模型放 build/dev/embed-bench/models/（build/ 已 gitignore），共约 1.8 GB：
#   qwen3-0.6b-bf16  Qwen/Qwen3-Embedding-0.6B（官方，bf16，1.19 GB）
#   qwen3-0.6b-4bit  mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ（0.34 GB）
#   bge-m3-fp16      mlx-community/bge-m3-mlx-fp16（官方仓库只有 pytorch_model.bin，MLX 读不了，用这份转好的；1.14 GB）
# 下载可续传；已下完的文件跳过。换源：HF_ENDPOINT=https://huggingface.co bash setup.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
models="$root/build/dev/embed-bench/models"
endpoint="${HF_ENDPOINT:-https://hf-mirror.com}"

echo "== 1/2 拉 SPM 依赖（mlx-swift-lm 3.32.3、swift-transformers 1.4.0 及其传递依赖）"
cd "$here"
xcodebuild -resolvePackageDependencies -scheme EmbedBench -derivedDataPath "$root/build/dev/embed-bench"

fetch() { # <本地目录名> <仓库> <文件...>
    local dir="$models/$1" repo="$2"; shift 2
    mkdir -p "$dir"
    for f in "$@"; do
        mkdir -p "$dir/$(dirname "$f")"
        echo "  $repo/$f"
        curl -fL --retry 3 -C - -o "$dir/$f" "$endpoint/$repo/resolve/main/$f"
    done
}

echo "== 2/2 下模型（$endpoint）"
fetch qwen3-0.6b-bf16 Qwen/Qwen3-Embedding-0.6B \
    config.json model.safetensors tokenizer.json tokenizer_config.json vocab.json merges.txt 1_Pooling/config.json
fetch qwen3-0.6b-4bit mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ \
    config.json model.safetensors model.safetensors.index.json tokenizer.json tokenizer_config.json \
    vocab.json merges.txt added_tokens.json special_tokens_map.json
fetch bge-m3-fp16 mlx-community/bge-m3-mlx-fp16 \
    config.json model.safetensors model.safetensors.index.json tokenizer.json tokenizer_config.json special_tokens_map.json

echo "== 完成"
du -sh "$models"/*
