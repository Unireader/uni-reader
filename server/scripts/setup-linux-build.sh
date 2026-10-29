#!/bin/bash
# 一次性准备「在 Mac 上编 Linux 版服务器」（用户自己跑，项目规矩：不代用户安装）。
#   1. swift.org 的 Swift 工具链（装到 ~/Library/Developer/Toolchains，只给交叉编译用；
#      不改默认的 swift：平时的 swift / xcodebuild 仍是 Xcode 自带那套）
#   2. Static Linux SDK（musl 静态编译：出来的二进制不依赖目标机的 glibc / Swift 运行库）
#   3. 拉取服务器的 Linux 依赖（swift-toolchain-sqlite）
# 工具链版本必须与 SDK 版本完全一致；升级时两处一起改（build-linux.sh 里的 VER 也改）。
# 🔴 钉在 6.2.3（SDK 0.0.1）：6.2.4 起的静态 SDK（0.1.0）把 musl 的内存分配换成了 mimalloc，
#    它用了 ARMv8.1 的原子指令，在 ARMv8.0 的板子上（如 RK3399 / 树莓派 4）一启动就 Illegal instruction。
#    升级前先确认新 SDK 的 aarch64 libc.a 里没有 mimalloc.o 了（server/AGENTS.md 有检查命令）。
set -euo pipefail

VER=6.2.3
SDK_VER=0.0.1
SDK_SUM=f30ec724d824ef43b5546e02ca06a8682dafab4b26a99fbb0e858c347e507a2c
BASE="https://download.swift.org/swift-$VER-release"
TC_DIR="$HOME/Library/Developer/Toolchains/swift-$VER-RELEASE.xctoolchain"

if [ ! -d "$TC_DIR" ]; then
    tmp=$(mktemp -d)
    echo "下载 Swift $VER 工具链（约 1.7GB）…"
    curl -fL -o "$tmp/swift.pkg" "$BASE/xcode/swift-$VER-RELEASE/swift-$VER-RELEASE-osx.pkg"
    installer -pkg "$tmp/swift.pkg" -target CurrentUserHomeDirectory
    rm -rf "$tmp"
fi
TOOLCHAINS=$(plutil -extract CFBundleIdentifier raw "$TC_DIR/Info.plist")
export TOOLCHAINS

if swift sdk list 2>/dev/null | grep -q "swift-$VER-RELEASE_static-linux"; then
    echo "Static Linux SDK 已装"
else
    echo "下载 Static Linux SDK（约 300MB）…"
    swift sdk install "$BASE/static-sdk/swift-$VER-RELEASE/swift-$VER-RELEASE_static-linux-$SDK_VER.artifactbundle.tar.gz" \
        --checksum "$SDK_SUM"
fi

cd "$(dirname "$0")/.."
unset TOOLCHAINS
swift package resolve
echo "好了：scripts/build-linux.sh 出 Linux 版"
