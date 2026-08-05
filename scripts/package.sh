#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# 打包 UniReader：xcodegen → archive → Developer ID 导出 → 公证 → staple → zip
#
# 用法：
#   ./scripts/package.sh                  # 自动递增：小版本号 +1，构建号 +1（如 0.1.11/1 → 0.1.12/2）
#   ./scripts/package.sh 0.2.0            # 打包前把 MARKETING_VERSION 改成 0.2.0（构建号仍自动 +1）
#   ./scripts/package.sh --version 0.2.0  # 同上
#   VERSION=0.2.0 ./scripts/package.sh    # 同上（环境变量方式）
#   ./scripts/package.sh 0.2.0 --build 3  # 同时把 CURRENT_PROJECT_VERSION 改成 3（不自动递增）
#   ./scripts/package.sh --no-bump        # 不改动版本号和构建号，用 project.yml 当前值打包
#
# 优先级：命令行参数 > VERSION/BUILD 环境变量 > 自动递增（--no-bump 时保持 project.yml 当前值）。
#
# 前置条件（只需做一次）：
#   xcrun notarytool store-credentials "UniReader-Notary" \
#     --apple-id "<team T8F5T6HKG8 下有权限的 Apple ID>" \
#     --team-id "T8F5T6HKG8"
#   （执行后会安全地交互式提示输入 App 专用密码，去 appleid.apple.com 生成）

PROJECT_YML="project.yml"
SCHEME="UniReader"
NOTARY_PROFILE="${NOTARY_PROFILE:-noticky-notary}"
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/UniReader.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="scripts/exportOptions.plist"

VERSION="${VERSION:-}"
BUILD="${BUILD:-}"
NO_BUMP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:?--version 需要一个版本号，如 0.2.0}"
      shift 2
      ;;
    --build)
      BUILD="${2:?--build 需要一个构建号，如 3}"
      shift 2
      ;;
    --no-bump)
      NO_BUMP=1
      shift
      ;;
    -*)
      echo "未知选项: $1" >&2
      exit 2
      ;;
    *)
      if [[ -n "$VERSION" ]]; then
        echo "多余的参数: $1（版本号已设为 $VERSION）" >&2
        exit 2
      fi
      VERSION="$1"
      shift
      ;;
  esac
done

CURRENT_VERSION=$(grep -m1 'MARKETING_VERSION' "$PROJECT_YML" | sed -E 's/.*"([^"]*)".*/\1/')
CURRENT_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION' "$PROJECT_YML" | sed -E 's/.*"([^"]*)".*/\1/')

# 未显式指定时自动递增：小版本号 +1、构建号 +1（--no-bump 关闭）
if [[ "$NO_BUMP" -eq 0 ]]; then
  if [[ -z "$VERSION" ]]; then
    if ! [[ "$CURRENT_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
      echo "project.yml 里的 MARKETING_VERSION 格式不对: $CURRENT_VERSION，无法自动递增" >&2
      exit 2
    fi
    LAST="${CURRENT_VERSION##*.}"
    VERSION="${CURRENT_VERSION%.*}.$((LAST + 1))"
  fi
  if [[ -z "$BUILD" ]]; then
    if ! [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
      echo "project.yml 里的 CURRENT_PROJECT_VERSION 格式不对: $CURRENT_BUILD，无法自动递增" >&2
      exit 2
    fi
    BUILD=$((CURRENT_BUILD + 1))
  fi
fi

if [[ -n "$VERSION" ]]; then
  if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "版本号格式不对: $VERSION（应为 x.y 或 x.y.z）" >&2
    exit 2
  fi
  echo "-> 设置 MARKETING_VERSION = $VERSION"
  sed -i '' -E "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$VERSION\"/" "$PROJECT_YML"
fi

if [[ -n "$BUILD" ]]; then
  if ! [[ "$BUILD" =~ ^[0-9]+$ ]]; then
    echo "构建号格式不对: $BUILD（应为整数）" >&2
    exit 2
  fi
  echo "-> 设置 CURRENT_PROJECT_VERSION = $BUILD"
  sed -i '' -E "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" "$PROJECT_YML"
fi

echo "-> 构建采集页前端（web/ → Sources/Resources/capture.html）"
bash scripts/build-web.sh

echo "-> xcodegen generate"
xcodegen generate

VERSION=$(grep -m1 'MARKETING_VERSION' "$PROJECT_YML" | sed -E 's/.*"([^"]*)".*/\1/')
BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION' "$PROJECT_YML" | sed -E 's/.*"([^"]*)".*/\1/')
echo "-> 打包版本: $VERSION (build $BUILD)"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "-> archive (Release)"
xcodebuild archive \
  -project UniReader.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS"

echo "-> export（Developer ID 签名）"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

APP_PATH="$EXPORT_DIR/$SCHEME.app"
NOTARIZE_ZIP="$BUILD_DIR/$SCHEME-$VERSION-notarize.zip"

echo "-> 打包用于提交公证的 zip"
ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

echo "-> 提交公证（可能需要几分钟，请耐心等待）"
xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "-> 装订公证票据到 .app"
xcrun stapler staple "$APP_PATH"

FINAL_ZIP="$BUILD_DIR/$SCHEME-$VERSION.zip"
echo "-> 打最终分发 zip"
ditto -c -k --keepParent "$APP_PATH" "$FINAL_ZIP"
rm -f "$NOTARIZE_ZIP"

echo ""
echo "完成: $FINAL_ZIP"
echo "拷贝到其他电脑后解压，把 $SCHEME.app 拖进 /Applications 即可（已公证+装订，无需右键打开）。"
