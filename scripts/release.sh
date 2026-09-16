#!/usr/bin/env bash
# 发布到 GitHub：改版本号 → 重建采集页 → Debug 编译验证 → 提交 → archive → Developer ID 导出
# → 公证 + 装订 → zip + dmg（dmg 也公证装订）→ 打 tag → 推送 main 和 tag → gh release 上传 zip + dmg
#
# 由 agent-home/.claude/skills/release-macos-app 的 template-release-basic.sh（无 Sparkle）改写，差异：
#   - 版本号读写 project.yml 的 MARKETING_VERSION / CURRENT_PROJECT_VERSION（本项目不用 CFBundle* 键）
#   - 产物按 AGENTS.md「产物只许落在这两个地方」：build/UniReader-<版本>.zip / .dmg；中间产物沿用
#     package.sh 的 build/UniReader.xcarchive、build/export；编译一律 -derivedDataPath build/dev
#     + -disableAutomaticPackageResolution（SPM 包缓存就在那，发布时不联网拉包）
#   - 发布日志必须提前写好（--notes-file），不用 gh 自动生成；日志文件在仓库里时随版本号一起提交
#   - 采集页走 build-web.sh --no-install（不代装依赖）
#   - 公证全部通过之后才推送 main 和 tag：中途失败时远端什么都没变
#   - --dry-run 不提交：检查 + 改版本号 + Debug 编译，跑完把 project.yml 还原
#
# 用法：
#   ./scripts/release.sh <版本号> --notes-file <路径> [--prerelease <后缀>] [--dry-run]
#
# 例：
#   ./scripts/release.sh 0.1.38 --notes-file release-notes/v0.1.38.md --dry-run   # 先演练
#   ./scripts/release.sh 0.1.38 --notes-file release-notes/v0.1.38.md             # 正式发布（仓库是公开的）
#
# 前置条件（只需做一次）：
#   - 钥匙串里有 team T8F5T6HKG8 的 Developer ID Application 证书
#   - notarytool 钥匙串配置：xcrun notarytool store-credentials <配置名> --apple-id <id> --team-id T8F5T6HKG8
#     默认配置名 noticky-notary（与 package.sh 相同）；名字不同就 NOTARY_PROFILE=<配置名> ./scripts/release.sh ...
#   - gh 已登录（gh auth status）
#   - web/node_modules 已装（scripts/build-web.sh）、build/dev/SourcePackages 已解析（见 AGENTS.md）

set -euo pipefail

TEAM_ID="${TEAM_ID:-T8F5T6HKG8}"
NOTARY_PROFILE="${NOTARY_PROFILE:-noticky-notary}"
SCHEME="UniReader"
PROJECT="UniReader.xcodeproj"
PRODUCT="UniReader"
GH_REPO="Unireader/uni-reader"
PROJECT_YML="project.yml"
BUILD_DIR="build"
DERIVED_DATA="$BUILD_DIR/dev"
ARCHIVE="$BUILD_DIR/$PRODUCT.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="scripts/exportOptions.plist"

# ── 参数 ────────────────────────────────────────────────────────────
usage() {
  cat <<EOF >&2
用法: $(basename "$0") <版本号> --notes-file <路径> [--prerelease <后缀>] [--dry-run]

  <版本号>            MARKETING_VERSION，形如 0.1.38（构建号自动 +1）
  --notes-file 路径   提前写好的发布日志（Markdown），作为 GitHub release 正文；必填
  --prerelease 后缀   标记为预发布，tag 变成 v<版本号>-<后缀>
  --dry-run           只做检查 + 改版本号 + Debug 编译，然后还原 project.yml；
                      不提交、不公证、不推送、不发布
EOF
  exit 1
}

VERSION=""; PRERELEASE=""; NOTES_FILE=""; DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prerelease) PRERELEASE="${2:?--prerelease 需要一个后缀，如 beta}"; shift 2 ;;
    --notes-file) NOTES_FILE="${2:?--notes-file 需要一个路径}"; shift 2 ;;
    --dry-run)    DRY_RUN=true; shift ;;
    -h|--help)    usage ;;
    -*)           echo "未知选项: $1" >&2; usage ;;
    *) if [[ -z "$VERSION" ]]; then VERSION="$1"; shift
       else echo "多余的参数: $1" >&2; usage; fi ;;
  esac
done

[[ -n "$VERSION" ]] || usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "ERROR: 版本号应为 X.Y.Z（收到 '$VERSION'）" >&2; exit 1; }
[[ -n "$NOTES_FILE" ]] || { echo "ERROR: 必须用 --notes-file 指定提前写好的发布日志" >&2; usage; }
[[ -s "$NOTES_FILE" ]] || { echo "ERROR: 发布日志不存在或是空文件: $NOTES_FILE" >&2; exit 1; }

# 日志路径按调用时的目录解析，再切到仓库根目录
NOTES_FILE="$(cd "$(dirname "$NOTES_FILE")" && pwd)/$(basename "$NOTES_FILE")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 日志在仓库里且没被 .gitignore 忽略 → 检查工作区时放过它，并随版本号一起提交
NOTES_IN_REPO=""
case "$NOTES_FILE" in
  "$ROOT"/*)
    NOTES_IN_REPO="${NOTES_FILE#"$ROOT"/}"
    if git check-ignore -q "$NOTES_IN_REPO"; then NOTES_IN_REPO=""; fi
    ;;
esac

if [[ -n "$PRERELEASE" ]]; then
  TAG="v${VERSION}-${PRERELEASE}"; TITLE="$PRODUCT $VERSION $PRERELEASE"; ASSET_BASE="$PRODUCT-$VERSION-$PRERELEASE"
else
  TAG="v${VERSION}"; TITLE="$PRODUCT $VERSION"; ASSET_BASE="$PRODUCT-$VERSION"
fi
ZIP="$BUILD_DIR/$ASSET_BASE.zip"
DMG="$BUILD_DIR/$ASSET_BASE.dmg"
APP="$EXPORT_DIR/$PRODUCT.app"

# ── 中途退出时的收尾 ────────────────────────────────────────────────
# STAGE：bumped（改了 project.yml 未提交）→ committed → tagged → pushed → released
STAGE=""
on_exit() {
  local rc=$?
  case "$STAGE" in
    bumped)
      echo "==> 还原 project.yml 并重新生成工程"
      git checkout HEAD -- "$PROJECT_YML"
      xcodegen generate >/dev/null 2>&1 || true
      ;;
    committed|tagged)
      if [[ $rc -ne 0 ]]; then
        echo "" >&2
        echo "发布中断：版本号提交还在本地，没有推送，远端没有变化。重试前先撤销：" >&2
        if [[ "$STAGE" == "tagged" ]]; then echo "  git tag -d $TAG" >&2; fi
        echo "  git reset HEAD~1 && git checkout -- $PROJECT_YML && xcodegen generate" >&2
      fi
      ;;
    pushed)
      if [[ $rc -ne 0 ]]; then
        echo "" >&2
        echo "发布中断：main 和 $TAG 已推送，但 GitHub release 没建成。产物还在，可以手动补建：" >&2
        echo "  gh release create $TAG --repo $GH_REPO --verify-tag --title \"$TITLE\" --notes-file \"$NOTES_FILE\" $ZIP $DMG" >&2
      fi
      ;;
  esac
  exit "$rc"
}
trap on_exit EXIT

fail() { echo "ERROR: $*" >&2; exit 1; }

# 提交公证并等结果；只认输出里的 status: Accepted（不依赖 notarytool 的退出码）
notarize() {
  local file="$1" log="$2" id
  echo "==> 提交公证：$(basename "$file")（等待结果，通常几分钟）"
  xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$log" || true
  if ! grep -q "status: Accepted" "$log"; then
    id="$(grep -m1 -E '^id: ' "$log" | sed 's/^id: //' || true)"
    echo "ERROR: 公证没通过：${file}（完整输出 ${log}）" >&2
    echo "       查看原因: xcrun notarytool log ${id:-<submission-id>} --keychain-profile $NOTARY_PROFILE" >&2
    exit 1
  fi
}

echo "==> 版本 $VERSION  •  tag $TAG  •  产物 $ZIP + $DMG"
if [[ "$DRY_RUN" == true ]]; then echo "==> [dry-run] 演练模式"; fi

# ── 发布前检查 ──────────────────────────────────────────────────────
echo "==> 发布前检查"
[[ -f "$PROJECT_YML" ]] || fail "找不到 $PROJECT_YML"
for cmd in xcodegen xcodebuild gh npm hdiutil; do
  command -v "$cmd" >/dev/null || fail "找不到命令 $cmd"
done
gh auth status >/dev/null 2>&1 || fail "gh 没登录，先跑 gh auth login"
[[ -d web/node_modules ]] || fail "web/node_modules 不存在，先跑 scripts/build-web.sh 装依赖"
[[ -d "$DERIVED_DATA/SourcePackages/checkouts" ]] \
  || fail "SPM 包缓存不存在，先跑：xcodegen generate && xcodebuild -project $PROJECT -scheme $SCHEME -derivedDataPath $DERIVED_DATA -resolvePackageDependencies"

# 管道末尾别用 grep -q：pipefail 下前面的命令可能因 SIGPIPE 被判失败
security find-identity -v -p codesigning | grep "Developer ID Application.*$TEAM_ID" >/dev/null \
  || fail "钥匙串里没有 team $TEAM_ID 的 Developer ID Application 证书"

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  if [[ "$DRY_RUN" == true ]]; then
    echo "WARN: 读不到 notarytool 配置 '$NOTARY_PROFILE'（演练不公证，继续；正式发布会在这里停下）" >&2
  else
    fail "读不到 notarytool 配置 '$NOTARY_PROFILE'。新建：xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id ${TEAM_ID}；或 NOTARY_PROFILE=<配置名> $(basename "$0") ..."
  fi
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || fail "要在 main 分支上发布（当前是 ${BRANCH}）"

if [[ -n "$NOTES_IN_REPO" ]]; then
  DIRTY="$(git status --porcelain -- . ":(exclude)$NOTES_IN_REPO")"
else
  DIRTY="$(git status --porcelain)"
fi
[[ -z "$DIRTY" ]] || fail "工作区有未提交的改动（发布日志除外），先提交或 stash：
$DIRTY"

git fetch --quiet origin main
git merge-base --is-ancestor origin/main HEAD || fail "本地 main 落后于 origin/main，先 git pull"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then fail "本地已有 tag $TAG"; fi
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then fail "origin 上已有 tag $TAG"; fi
if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then fail "GitHub 上已有 release $TAG"; fi

# ── 改版本号 ────────────────────────────────────────────────────────
read_setting() { grep -m1 "$1:" "$PROJECT_YML" | sed -E 's/.*"([^"]*)".*/\1/'; }
CURRENT_VERSION="$(read_setting MARKETING_VERSION)"
CURRENT_BUILD="$(read_setting CURRENT_PROJECT_VERSION)"
[[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]] || fail "project.yml 里的 CURRENT_PROJECT_VERSION 格式不对: $CURRENT_BUILD"
NEXT_BUILD=$((CURRENT_BUILD + 1))
echo "==> 版本号 $CURRENT_VERSION (build $CURRENT_BUILD) → $VERSION (build $NEXT_BUILD)"

STAGE=bumped
sed -i '' -E "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$VERSION\"/" "$PROJECT_YML"
sed -i '' -E "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$NEXT_BUILD\"/" "$PROJECT_YML"

echo "==> 重建采集页（web/ → Sources/Resources/capture.html，不装依赖）"
bash scripts/build-web.sh --no-install

echo "==> xcodegen generate"
xcodegen generate >/dev/null

echo "==> Debug 编译验证（${DERIVED_DATA}）"
BUILD_LOG="$(mktemp -t unireader-release-debug)"
if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination 'platform=macOS' -configuration Debug \
      -derivedDataPath "$DERIVED_DATA" -disableAutomaticPackageResolution \
      build CODE_SIGNING_ALLOWED=NO >"$BUILD_LOG" 2>&1; then
  grep -E 'error:' "$BUILD_LOG" | head -20 >&2 || true
  fail "Debug 编译失败，完整日志: $BUILD_LOG"
fi
echo "    编译通过"

if [[ "$DRY_RUN" == true ]]; then
  echo "==> [dry-run] 检查和编译都通过，到此为止（不提交、不公证、不推送、不发布）"
  exit 0
fi

echo "==> 提交版本号"
git add "$PROJECT_YML"
if [[ -n "$NOTES_IN_REPO" ]]; then git add "$NOTES_IN_REPO"; fi
git commit -q -m "release: $TAG (build $NEXT_BUILD)"
STAGE=committed

# ── archive + Developer ID 导出 ─────────────────────────────────────
# 只清本脚本自己的中间产物和同版本产物；build/dev 不能删（见 AGENTS.md）
rm -rf "$ARCHIVE" "$EXPORT_DIR"
rm -f "$ZIP" "$DMG"
mkdir -p "$EXPORT_DIR"

echo "==> archive（Release）"
xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -destination "generic/platform=macOS" -archivePath "$ARCHIVE" \
  -derivedDataPath "$DERIVED_DATA" -disableAutomaticPackageResolution -quiet
[[ -d "$ARCHIVE" ]] || fail "没有生成 archive: $ARCHIVE"

echo "==> 导出（Developer ID 签名）"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" -quiet
[[ -d "$APP" ]] || fail "导出的 app 不存在: $APP"

echo "==> 校验签名"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "^(Authority|TeamIdentifier)=|flags=" || true
codesign -dv "$APP" 2>&1 | grep "TeamIdentifier=$TEAM_ID" >/dev/null || fail "签名的 TeamIdentifier 不是 $TEAM_ID"

# ── 公证 app → 装订 → 最终 zip ──────────────────────────────────────
NOTARIZE_ZIP="$EXPORT_DIR/$ASSET_BASE-notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARIZE_ZIP"
notarize "$NOTARIZE_ZIP" "$EXPORT_DIR/notary-app.log"
rm -f "$NOTARIZE_ZIP"

echo "==> 装订公证票据到 app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -t exec -vv "$APP" 2>&1 || true

echo "==> 打最终 zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# ── dmg（拖进 Applications 安装）→ 公证 → 装订 ──────────────────────
echo "==> 做 dmg"
DMG_STAGE="$EXPORT_DIR/dmg-stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
ditto "$APP" "$DMG_STAGE/$PRODUCT.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create -volname "$PRODUCT $VERSION" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$DMG_STAGE"

notarize "$DMG" "$EXPORT_DIR/notary-dmg.log"
echo "==> 装订公证票据到 dmg"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# ── tag → 推送 → GitHub release ─────────────────────────────────────
echo "==> 打 tag $TAG"
git tag -a "$TAG" -m "$TITLE"
STAGE=tagged

echo "==> 推送 main 和 $TAG"
git push --atomic origin main "refs/tags/$TAG"
STAGE=pushed

echo "==> 创建 GitHub release 并上传 zip + dmg"
if [[ -n "$PRERELEASE" ]]; then
  gh release create "$TAG" --repo "$GH_REPO" --verify-tag --prerelease \
    --title "$TITLE" --notes-file "$NOTES_FILE" "$ZIP" "$DMG"
else
  gh release create "$TAG" --repo "$GH_REPO" --verify-tag \
    --title "$TITLE" --notes-file "$NOTES_FILE" "$ZIP" "$DMG"
fi
STAGE=released

echo ""
echo "================================================================"
echo "已发布 $TAG"
echo "  zip : $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "  dmg : $DMG ($(du -h "$DMG" | cut -f1))"
echo "  页面: https://github.com/$GH_REPO/releases/tag/$TAG"
echo "================================================================"
