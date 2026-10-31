#!/bin/bash
# 发布服务器（流程见 server/AGENTS.md「发布」）：检查 → 改版本号（ServerInfo.version）→ 本机编一次、核对 --version →
# 提交（连同发布日志）→ 打 tag server-v<版本> → 推送 main 和 tag。
# 推上去之后由 GitHub Actions（.github/workflows/server-release.yml）跑网页测试 + Linux 单元测试、
# 编 Linux aarch64 / x86_64 + macOS arm64、发 GitHub Release（不标成 Latest，不影响 App 的发布）。
#
#   server/scripts/release.sh <版本> [--dry-run]
#
# 发布日志先写好：server/release-notes/v<版本>.md（中文 + 英文，用日常说法，只写上次发布以来的改动）。
# --dry-run：只做检查 + 改版本号 + 本机编译，跑完把版本号改回去（不提交、不打 tag、不推送）。
# 要兼容 macOS 自带的 bash 3.2（AGENTS 约定），写完 shellcheck。
set -euo pipefail

VER=${1:-}
DRY=0
if [ "${2:-}" = "--dry-run" ]; then DRY=1; fi

fail() { echo "❌ $*" >&2; exit 1; }
step() { echo "==> $*"; }

[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "用法：server/scripts/release.sh <版本，如 0.2.0> [--dry-run]"

cd "$(dirname "$0")/../.."
VFILE=server/Sources/UniServerCore/WorkspaceHost.swift
NOTES=server/release-notes/v$VER.md
TAG=server-v$VER
WORKFLOW_URL=https://github.com/Unireader/uni-reader/actions/workflows/server-release.yml

current_version() { sed -nE 's/.*static let version = "([0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' "$VFILE"; }

step "版本 $VER  •  tag $TAG$( [ $DRY = 1 ] && echo '  •  演练（不提交、不推送）')"

step "发布前检查"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail "要在 main 上发布"
dirty=$(git status --porcelain --untracked-files=all | grep -vF " $NOTES" || true)
[ -z "$dirty" ] || fail "工作区不干净（发布日志除外）：
$dirty"
[ -f "$NOTES" ] || fail "先写发布日志 $NOTES"
git fetch -q origin main --tags
[ "$(git rev-list --count HEAD..origin/main)" = 0 ] || fail "本地落后 origin/main，先 git pull"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then fail "本地已有 tag $TAG"; fi
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then fail "origin 上已有 tag $TAG"; fi
OLD=$(current_version)
[ -n "$OLD" ] || fail "没从 $VFILE 读到 ServerInfo.version"

# 中途失败（或演练结束）把版本号改回去；提交之后就不再动它
COMMITTED=0
restore() { if [ $COMMITTED = 0 ]; then git checkout -q -- "$VFILE"; fi; }
trap restore EXIT

step "版本号 $OLD → $VER"
sed -i '' -E "s/(static let version = \")[0-9]+\.[0-9]+\.[0-9]+\"/\1$VER\"/" "$VFILE"
[ "$(current_version)" = "$VER" ] || fail "没改成版本号（$VFILE）"

step "本机编译（macOS，Debug）"
(cd server && swift build --disable-automatic-resolution --product unireader-server)
BIN="$(cd server && swift build --disable-automatic-resolution --show-bin-path)/unireader-server"
GOT=$("$BIN" --version)
[ "$GOT" = "$VER" ] || fail "编出来的程序报版本 $GOT，应为 $VER"
echo "    编译通过，--version = $GOT"

if [ $DRY = 1 ]; then
    step "[演练] 到此为止，版本号改回 $OLD"
    exit 0
fi

step "提交 + 打 tag"
git add "$VFILE" "$NOTES"
git commit -q -m "release(server): v$VER"
COMMITTED=1
git tag -a "$TAG" -m "UniReader 服务器 $VER"

step "推送 main 和 $TAG"
if ! git push --atomic origin main "$TAG"; then
    echo "推送失败，远端没变。撤销本地的提交和 tag：" >&2
    echo "  git tag -d $TAG && git reset --hard HEAD~1" >&2
    exit 1
fi

step "已推送。GitHub Actions 接着测试、编译、发布：$WORKFLOW_URL"
echo "    跟进度：gh run watch \$(gh run list --workflow server-release.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
