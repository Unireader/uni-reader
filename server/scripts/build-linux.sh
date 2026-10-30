#!/bin/bash
# 在 Mac 上交叉编译 Linux 版服务器：musl 静态链接，单个文件、目标机什么都不用装（avahi-utils 只是局域网发现要）。
# 先跑一次 scripts/setup-linux-build.sh。
#
#   scripts/build-linux.sh [aarch64|x86_64]      默认 aarch64
#   scripts/build-linux.sh aarch64 --tests       连测试一起编（测试程序拷到 Linux 上跑，见 server/AGENTS.md）
#
# 最后一行打印产物路径（unireader-server，或 --tests 时的测试程序）：位置随 SwiftPM 版本变，别写死。
set -euo pipefail

VER=6.2.3                       # 与 setup-linux-build.sh 一致（为什么钉在这个版本见那边的注释）
ARCH=${1:-aarch64}
case "$ARCH" in aarch64|x86_64) ;; *) echo "架构只认 aarch64 / x86_64" >&2; exit 2 ;; esac
cd "$(dirname "$0")/.."

TC_DIR="$HOME/Library/Developer/Toolchains/swift-$VER-RELEASE.xctoolchain"
[ -d "$TC_DIR" ] || { echo "没有 Swift $VER 工具链：先跑 scripts/setup-linux-build.sh" >&2; exit 1; }
TOOLCHAINS=$(plutil -extract CFBundleIdentifier raw "$TC_DIR/Info.plist")
export TOOLCHAINS
SDK="$ARCH-swift-linux-musl"

# 各包的 Package.swift 是按 Mac 编的：Swift 6.2 读不了 Xcode 27 的 macOS SDK（unknown argument -target-arch-variant），
# 改用命令行工具（CommandLineTools）里的 macOS 26 SDK。只影响这一步，产物仍是 Linux 的。
if [ -z "${SDKROOT:-}" ]; then
    for s in /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk; do
        if [ -d "$s" ]; then SDKROOT=$s; fi
    done
    [ -n "${SDKROOT:-}" ] || { echo "没找到 macOS 26 SDK（/Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk）" >&2; exit 1; }
    export SDKROOT
fi

if [ "${2:-}" = "--tests" ]; then
    swift build --disable-automatic-resolution --swift-sdk "$SDK" --build-tests
    bin=$(swift build --disable-automatic-resolution --swift-sdk "$SDK" --show-bin-path)
    find "$bin" -maxdepth 1 -name '*PackageTests*' -type f -perm -u+x | head -1
else
    # 网页阅读器（web/）：装了依赖就先构建，产物由构建插件编进程序；没装就提醒一句，程序照样能编，只是不带网页
    if [ -d web/node_modules ]; then
        scripts/build-web.sh >&2
    elif [ ! -f web/dist/index.html ]; then
        echo "⚠️ web/dist 不存在，这次编出的程序不带网页（先 cd server/web && pnpm install，再重跑本脚本）" >&2
    fi
    # -s：去掉符号表，体积小很多
    swift build -c release --disable-automatic-resolution --swift-sdk "$SDK" --product unireader-server -Xlinker -s
    echo "$(swift build -c release --disable-automatic-resolution --swift-sdk "$SDK" --show-bin-path)/unireader-server"
fi
