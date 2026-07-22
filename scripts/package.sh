#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# 打包 UniReader：xcodegen → archive → Developer ID 导出 → 公证 → staple → zip
#
# 用法：
#   ./scripts/package.sh                 # 用 project.yml 里当前的版本号打包
#   VERSION=0.2.0 ./scripts/package.sh   # 打包前把 MARKETING_VERSION 改成 0.2.0 再打包
#
# 前置条件（只需做一次）：
#   xcrun notarytool store-credentials "UniReader-Notary" \
#     --apple-id "<team T8F5T6HKG8 下有权限的 Apple ID>" \
#     --team-id "T8F5T6HKG8"
#   （执行后会安全地交互式提示输入 App 专用密码，去 appleid.apple.com 生成）

PROJECT_YML="project.yml"
SCHEME="UniReader"
NOTARY_PROFILE="${NOTARY_PROFILE:-UniReader-Notary}"
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/UniReader.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="scripts/exportOptions.plist"

if [[ -n "${VERSION:-}" ]]; then
  echo "-> 设置 MARKETING_VERSION = $VERSION"
  sed -i '' -E "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$VERSION\"/" "$PROJECT_YML"
fi

echo "-> xcodegen generate"
xcodegen generate

VERSION=$(grep -m1 'MARKETING_VERSION' "$PROJECT_YML" | sed -E 's/.*"([^"]*)".*/\1/')
echo "-> 打包版本: $VERSION"

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
