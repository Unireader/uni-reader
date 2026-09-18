#!/usr/bin/env bash
# 发布到 GitHub：改版本号 → 重建采集页 → Debug 编译验证 → 提交 → archive → Developer ID 导出
# → 公证 + 装订 → zip + dmg（dmg 也公证装订）→ Sparkle 签名 zip + 更新 appcast.xml
# → 打 tag → 推送 main 和 tag → gh release 上传 zip + dmg → 推送 appcast.xml
#
# 由 agent-home/.claude/skills/release-macos-app 的 template-release-basic.sh 改写，2026-09-18 按
# template-release-sparkle.sh 补上 Sparkle 自动更新（Swift 侧集成见 Sources/App/UpdaterService.swift）。
# 与两份模板的差异：
#   - 版本号读写 project.yml 的 MARKETING_VERSION / CURRENT_PROJECT_VERSION（本项目不用 CFBundle* 键）
#   - 产物按 AGENTS.md「产物只许落在这两个地方」：build/UniReader-<版本>.zip / .dmg；中间产物沿用
#     package.sh 的 build/UniReader.xcarchive、build/export；编译一律 -derivedDataPath build/dev
#     + -disableAutomaticPackageResolution（SPM 包缓存就在那，发布时不联网拉包，Sparkle 的 sign_update/
#     generate_keys 工具也从这份缓存里找，不会现场再解析一次）
#   - 发布日志必须提前写好（--notes-file），不用 gh 自动生成；日志文件在仓库里时随版本号一起提交
#   - 采集页走 build-web.sh --no-install（不代装依赖）
#   - 公证全部通过之后才推送 main 和 tag：中途失败时远端什么都没变
#   - --dry-run 不提交：检查 + 改版本号 + Debug 编译，跑完把 project.yml 还原
#   - **`--prerelease` 版本不进 Sparkle 更新通道**：appcast.xml 只收录正式版。本项目暂不做 Perch 那种
#     「beta channel」偏好开关（2026-09-18 与用户确认过，以后要加再补），所以最简单也最安全的做法就是
#     预发布版压根不写进 appcast——不然普通用户会被 Sparkle 自动推到未测试的构建。
#
# 前置条件（只需做一次）：
#   - 钥匙串里有 team T8F5T6HKG8 的 Developer ID Application 证书
#   - notarytool 钥匙串配置：xcrun notarytool store-credentials <配置名> --apple-id <id> --team-id T8F5T6HKG8
#     默认配置名 noticky-notary（与 package.sh 相同）；名字不同就 NOTARY_PROFILE=<配置名> ./scripts/release.sh ...
#   - gh 已登录（gh auth status）
#   - web/node_modules 已装（scripts/build-web.sh）、build/dev/SourcePackages 已解析（见 AGENTS.md）
#   - 正式版发布还需要：Sparkle 的 EdDSA 密钥已生成过一次（`Sources/Info.plist` 的 SUPublicEDKey 非空、
#     登录钥匙串里有对应私钥）——第一次发布前跑：
#       xcodegen generate
#       xcodebuild -project UniReader.xcodeproj -scheme UniReader -derivedDataPath build/dev -resolvePackageDependencies
#       build/dev/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
#     把打印的公钥粘进 Sources/Info.plist 的 SUPublicEDKey，再 xcodegen generate 一次。
#     ⚠️ 公钥一旦随首次发布公开，严禁更换——否则所有已装版本都会拒绝以后的更新。
#
# 用法：
#   ./scripts/release.sh <版本号> --notes-file <路径> [--prerelease <后缀>] [--dry-run]
#
# 例：
#   ./scripts/release.sh 0.1.38 --notes-file release-notes/v0.1.38.md --dry-run   # 先演练
#   ./scripts/release.sh 0.1.38 --notes-file release-notes/v0.1.38.md             # 正式发布（仓库是公开的）

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
# Sparkle 自动更新（正式版才用，见文件头「--prerelease 版本不进 Sparkle 更新通道」）
APPCAST="appcast.xml"
APPCAST_MARKER="<!-- BEGIN-ITEMS (release.sh inserts new entries here, newest first) -->"
INFO_PLIST_SRC="Sources/Info.plist"
SPARKLE_BIN_DIR="$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin"

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
        # $APPCAST 可能在 Sparkle 签名那一步被本地改过（还没提交），一并还原。
        echo "  git reset HEAD~1 && git checkout -- $PROJECT_YML $APPCAST && xcodegen generate" >&2
      fi
      ;;
    pushed)
      if [[ $rc -ne 0 ]]; then
        echo "" >&2
        echo "发布中断：main 和 $TAG 已推送，但 GitHub release 没建成。产物还在，可以手动补建：" >&2
        echo "  gh release create $TAG --repo $GH_REPO --verify-tag --title \"$TITLE\" --notes-file \"$NOTES_FILE\" $ZIP $DMG" >&2
      fi
      ;;
    released)
      if [[ $rc -ne 0 ]]; then
        echo "" >&2
        echo "发布中断：GitHub release $TAG 已建好（zip/dmg 可下载），但 $APPCAST 的提交/推送失败。" >&2
        echo "老用户暂时收不到这次更新提醒，手动补：" >&2
        echo "  git add $APPCAST && git commit -m \"appcast: $TAG\" && git push origin main" >&2
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

# Sparkle 相关检查只在正式版才做——预发布版不进 appcast（见文件头说明），不需要这些前置条件。
# 密钥/工具没配好时 --dry-run 只 WARN 放行（同下面 notarytool 配置那条的口径：dry-run 只验证
# 版本号/编译这条主链路，Sparkle 的一次性密钥设置留到真要发布时再拦）；正式发布严格 fail。
sparkle_precheck_fail() {
  if [[ "$DRY_RUN" == true ]]; then
    echo "WARN: $* （演练继续；正式发布会在这里停下）" >&2
  else
    fail "$*"
  fi
}

if [[ -z "$PRERELEASE" ]]; then
  [[ -f "$APPCAST" ]] || fail "找不到 $APPCAST"
  grep -qF "$APPCAST_MARKER" "$APPCAST" || fail "$APPCAST 里没有 BEGIN-ITEMS marker，拒绝写入（可能被手改坏了）"

  ED_PUBKEY="$(plutil -extract SUPublicEDKey raw -o - "$INFO_PLIST_SRC" 2>/dev/null || echo "")"
  if [[ -z "$ED_PUBKEY" ]]; then
    sparkle_precheck_fail "$INFO_PLIST_SRC 里 SUPublicEDKey 是空的。首次发布前，在本机生成一次 Sparkle EdDSA 密钥（私钥自动存登录钥匙串）：
  1. 解析 SPM（如果还没做过）：
       xcodegen generate
       xcodebuild -project $PROJECT -scheme $SCHEME -derivedDataPath $DERIVED_DATA -resolvePackageDependencies
  2. 生成密钥（打印公钥）：
       $SPARKLE_BIN_DIR/generate_keys
  3. 把打印的公钥粘进 $INFO_PLIST_SRC 的 SUPublicEDKey，再跑一次 xcodegen generate
  4. 重新跑本脚本
  ⚠️ 公钥一旦随首次发布公开，严禁更换——否则所有已装版本都会拒绝以后的更新。"
  else
    [[ -x "$SPARKLE_BIN_DIR/sign_update" ]] \
      || sparkle_precheck_fail "Sparkle 的 sign_update 工具不存在（$SPARKLE_BIN_DIR），SPM 包缓存里没解析出 Sparkle，重新跑一次上面那条 -resolvePackageDependencies 命令"
    if [[ -x "$SPARKLE_BIN_DIR/generate_keys" ]]; then
      "$SPARKLE_BIN_DIR/generate_keys" -p >/dev/null 2>&1 \
        || sparkle_precheck_fail "Sparkle EdDSA 私钥不在登录钥匙串里（公钥已经填在 $INFO_PLIST_SRC，但对应私钥找不到）。换了台机器就恢复备份的私钥（generate_keys -f <key.pem>）；如果这是第一次发布却看到这条报错，说明公钥和这台机器的私钥对不上，需要重新走一遍生成流程。"
    fi
  fi
fi

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

# ── Sparkle：签 zip + 更新 appcast.xml（预发布版跳过，见文件头说明）─────
if [[ -z "$PRERELEASE" ]]; then
  echo "==> 用 Sparkle EdDSA 密钥签名 zip"
  SIGN_LINE="$("$SPARKLE_BIN_DIR/sign_update" "$ZIP")"
  ED_SIG="$(echo "$SIGN_LINE" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')"
  ASSET_LEN="$(echo "$SIGN_LINE" | sed -E 's/.*length="([^"]+)".*/\1/')"
  if [[ -z "$ED_SIG" || -z "$ASSET_LEN" || "$ED_SIG" == "$SIGN_LINE" ]]; then
    fail "解析不了 sign_update 的输出: $SIGN_LINE"
  fi
  echo "    edSignature ${ED_SIG:0:24}…  length ${ASSET_LEN}"

  DOWNLOAD_URL="https://github.com/$GH_REPO/releases/download/$TAG/$(basename "$ZIP")"
  RELEASE_NOTES_LINK="https://github.com/$GH_REPO/releases/tag/$TAG"

  echo "==> 更新 $APPCAST"
  python3 - "$APPCAST" "$TAG" "$VERSION" "$NEXT_BUILD" "$ED_SIG" "$ASSET_LEN" \
      "$DOWNLOAD_URL" "$RELEASE_NOTES_LINK" "$NOTES_FILE" <<'PYEOF'
import sys, html, re
from datetime import datetime, timezone

appcast, tag, short_ver, build, ed_sig, length, dl_url, notes_link, notes_md_file = sys.argv[1:]

pub_date = datetime.now(timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000')

# ── 极简 Markdown → HTML（够用：标题/列表/**粗体**/`code`/裸链接），先转义再替换，
# 免得发布日志里出现 "fix: handle <empty>" 这种文本被当成标签吞掉。
def md_to_html(md):
    def inline(s):
        s = html.escape(s, quote=False)
        s = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', s)
        s = re.sub(r'\*([^*\n]+?)\*', r'<em>\1</em>', s)
        s = re.sub(r'`(.+?)`', r'<code>\1</code>', s)
        s = re.sub(r'(https?://[^\s<]+)', r'<a href="\1">\1</a>', s)
        return s
    out, in_list = [], False
    def close_list():
        nonlocal in_list
        if in_list:
            out.append('</ul>'); in_list = False
    for raw in md.splitlines():
        line = raw.rstrip()
        heading = re.match(r'^(#{1,6})\s+(.*)$', line)
        bullet = re.match(r'^[-*]\s+(.*)$', line)
        if bullet:
            if not in_list:
                out.append('<ul>'); in_list = True
            out.append(f'<li>{inline(bullet.group(1))}</li>')
        elif re.match(r'^([-*_])\1{2,}\s*$', line):
            close_list(); out.append('<hr>')
        elif heading:
            close_list()
            lvl = min(len(heading.group(1)) + 1, 6)
            out.append(f'<h{lvl}>{inline(heading.group(2))}</h{lvl}>')
        elif line:
            close_list(); out.append(f'<p>{inline(line)}</p>')
        else:
            close_list()
    close_list()
    return '\n'.join(out)

# ── 按 "<!-- lang:xx -->" marker 拆多语言段落——发布日志目前是 "## 中文" / "## English"
# 两段，往后写新日志时在每段标题前加一行 <!-- lang:zh --> / <!-- lang:en -->（不可见 HTML 注释，
# gh release 那份 GitHub 正文不受影响），appcast 就能按用户系统语言各自显示对应段落。没打 marker
# 的旧文件走 fallback：整份塞进一个不带 xml:lang 的 description（两种语言堆在一起，能用但不智能）。
def split_langs(md):
    parts = re.split(r'(?im)^[ \t]*<!--[ \t]*lang:([a-z]{2})[ \t]*-->[ \t]*$', md)
    if len(parts) == 1:
        return [(None, md)]
    it = iter(parts[1:])
    return [(lang.lower(), chunk) for lang, chunk in zip(it, it) if chunk.strip()]

FOOTER = {'en': 'View full release on GitHub →', 'zh': '在 GitHub 查看完整更新 →'}

def build_description(lang, chunk):
    notes_html = md_to_html(chunk)
    foot = FOOTER.get(lang or 'en', FOOTER['en'])
    notes_html += f'\n<p><a href="{html.escape(notes_link)}">{foot}</a></p>'
    notes_html = notes_html.replace(']]>', ']]&gt;')
    lang_attr = f' xml:lang="{lang}"' if lang else ''
    return (f"      <description{lang_attr}><![CDATA[\n"
            f"{notes_html}\n"
            "      ]]></description>\n")

with open(notes_md_file, 'r', encoding='utf-8') as f:
    description = "".join(build_description(l, c) for l, c in split_langs(f.read()))

item = (
    "    <item>\n"
    f"      <title>{tag}</title>\n"
    f"      <pubDate>{pub_date}</pubDate>\n"
    f"      <sparkle:version>{build}</sparkle:version>\n"
    f"      <sparkle:shortVersionString>{short_ver}</sparkle:shortVersionString>\n"
    "      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>\n"
    f"{description}"
    f"      <enclosure url=\"{dl_url}\" length=\"{length}\" "
    f"type=\"application/octet-stream\" sparkle:edSignature=\"{ed_sig}\" />\n"
    "    </item>\n"
)

with open(appcast, 'r', encoding='utf-8') as f:
    src = f.read()

marker = "<!-- BEGIN-ITEMS (release.sh inserts new entries here, newest first) -->\n"
if marker not in src:
    sys.exit(f"ERROR: marker line not found in {appcast}; refuse to mangle it.")

with open(appcast, 'w', encoding='utf-8') as f:
    f.write(src.replace(marker, marker + item, 1))
PYEOF

  # 回读一遍刚写的签名，确认没有中途出岔子（并发改动/编码问题之类）再往下走。
  APPCAST_SIG="$(grep -m1 "sparkle:edSignature=" "$APPCAST" | sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/')"
  [[ "$APPCAST_SIG" == "$ED_SIG" ]] || fail "$APPCAST 顶部的签名和刚生成的对不上，拒绝继续"
else
  echo "==> [--prerelease] 跳过 Sparkle 签名和 $APPCAST 更新"
fi

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

# ── 推送 appcast.xml（此时 zip 已经能从 GitHub release 下到，appcast 指向的下载链接才是有效的）──
if [[ -z "$PRERELEASE" ]]; then
  echo "==> 推送 $APPCAST"
  git add "$APPCAST"
  git commit -q -m "appcast: $TAG"
  git push origin main
fi

echo ""
echo "================================================================"
echo "已发布 $TAG"
echo "  zip : $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "  dmg : $DMG ($(du -h "$DMG" | cut -f1))"
echo "  页面: https://github.com/$GH_REPO/releases/tag/$TAG"
if [[ -z "$PRERELEASE" ]]; then
  echo "  Sparkle 更新已推送，老用户下次按检查间隔/手动检查会看到这个版本"
else
  echo "  预发布版，未进 Sparkle 更新通道"
fi
echo "================================================================"
