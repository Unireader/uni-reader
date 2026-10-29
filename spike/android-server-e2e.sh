#!/bin/bash
# 安卓客户端对着真服务器的端到端 + Mac ↔ 安卓经服务器互通（方案 SERVER-MODE-PLAN.md S3）。
# 用法（仓库根目录，平板经 USB 接着、adb devices 里恰好一台）：bash spike/android-server-e2e.sh
#
# 1. 本机起一个临时服务器（127.0.0.1:18791，临时数据目录，跑完删）；
# 2. Mac 造一个工作区传上去（spike/android-server-interop.swift seed）；
# 3. `adb reverse` 让平板的 127.0.0.1:18791 通到本机，跑插桩测试 ServerSyncE2ETest（地址 / 配对码 / Mac 工作区经参数传）；
# 4. Mac 拉下来核对安卓改的（verify）。
set -euo pipefail
cd "$(dirname "$0")/.."

PORT=18791
TMP=$(mktemp -d -t unireader-android-e2e)
PID=""
cleanup() {
    local rc=$?
    if [ "$rc" -ne 0 ]; then echo "--- 服务器日志（最后 40 行）---"; tail -40 "$TMP/server.log" 2>/dev/null || true; fi
    if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; fi
    adb reverse --remove "tcp:$PORT" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

[ "$(adb devices | grep -c 'device$')" = "1" ] || { echo "要恰好一台安卓设备（adb devices）"; exit 1; }

(cd server && swift build --disable-automatic-resolution --product unireader-server > "$TMP/build.log" 2>&1) \
    || { cat "$TMP/build.log"; exit 1; }
BIN="$(cd server && swift build --disable-automatic-resolution --show-bin-path)/unireader-server"
"$BIN" serve --data "$TMP/data" --port "$PORT" > "$TMP/server.log" 2>&1 &
PID=$!
URL="http://127.0.0.1:$PORT"
for _ in $(seq 1 40); do curl -s -o /dev/null "$URL/v1/info" && break; sleep 0.25; done
CODE=$("$BIN" pairing-code --data "$TMP/data")

echo "== Mac 造工作区传上去"
cp spike/android-server-interop.swift "$TMP/main.swift"
swiftc Sources/Store/*.swift Sources/Sync/*.swift \
    Sources/ServerSync/ServerClient.swift Sources/ServerSync/ServerSyncIO.swift \
    "$TMP/main.swift" -o "$TMP/interop"
MAC_WS=$(SERVER_URL="$URL" PAIRING_CODE="$CODE" WORK_DIR="$TMP" "$TMP/interop" seed | sed -n 's/^MAC_WORKSPACE=//p')
[ -n "$MAC_WS" ] || { echo "Mac 没传上去"; exit 1; }

echo "== 安卓插桩测试"
adb reverse "tcp:$PORT" "tcp:$PORT"
touch "$TMP/mark"
R="-Pandroid.testInstrumentationRunnerArguments"
(cd android && ./gradlew connectedDebugAndroidTest \
    "$R.class=com.xvan.unireader.local.server.ServerSyncE2ETest" \
    "$R.serverUrl=$URL" "$R.pairingCode=$CODE" "$R.macWorkspace=$MAC_WS") || {
    echo "看 android/app/build/outputs/androidTest-results/ 里那份 XML"; exit 1; }
# 同一台经 mDNS 注册两次时 Gradle 会在「第二台」上跑出 0 个用例（android/AGENTS.md）：以 XML 为准
XML=$(find android/app/build/outputs/androidTest-results -name '*.xml' -newer "$TMP/mark" -size +0 \
    -exec grep -l 'ServerSyncE2ETest' {} + | head -1)
[ -n "$XML" ] || { echo "找不到这次的测试结果 XML"; exit 1; }
grep -o 'tests="[0-9]*" failures="[0-9]*" errors="[0-9]*" skipped="[0-9]*"' "$XML" || true
grep -q 'skipped="0"' "$XML" || { echo "有用例被跳过（参数没传进去？）"; exit 1; }

echo "== Mac 拉下来核对"
SERVER_URL="$URL" PAIRING_CODE="$CODE" WORK_DIR="$TMP" "$TMP/interop" verify "$MAC_WS"
