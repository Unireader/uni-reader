#!/bin/bash
# App 侧服务器客户端的端到端测试（spike/server-client-test.swift）：起一个临时服务器 → 编译并运行 spike → 关掉、清理。
# 用法：bash spike/server-client-test.sh
# 端口 18790（App 占 8770~8773，服务器默认 8790），数据目录是临时的，不碰任何现有数据。
#
# 对着 Linux 上的服务器跑（Linux 版没法跑 swift test，靠这个验；会先 server/scripts/build-linux.sh 编一次）：
#   REMOTE=nas REMOTE_ADDR=192.168.1.160 REMOTE_DIR=/storage/data/98_Misc/unireader-server-test bash spike/server-client-test.sh
#   REMOTE       ssh 主机名          REMOTE_ADDR  本机连它用的地址
#   REMOTE_DIR   远端的临时目录放在哪（在它下面建 e2e-<时间>/，跑完删掉）   REMOTE_ARCH  aarch64（默认）/ x86_64
set -euo pipefail
cd "$(dirname "$0")/.."

PORT=18790
TMP=$(mktemp -d -t unireader-client-test)
PID=""
RDIR=""
cleanup() {
    local rc=$?
    if [ "$rc" -ne 0 ]; then       # 失败时把服务器日志尾巴打出来再删
        echo "--- 服务器日志（最后 40 行）---"
        if [ -n "$RDIR" ]; then
            # shellcheck disable=SC2029
            ssh "$REMOTE" "tail -40 '$RDIR/server.log'" || true
        else
            tail -40 "$TMP/server.log" 2>/dev/null || true
        fi
    fi
    if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; fi
    if [ -n "$RDIR" ]; then
        # shellcheck disable=SC2029  # 变量就是要在本机展开
        ssh "$REMOTE" "kill \$(cat '$RDIR/pid' 2>/dev/null) 2>/dev/null; sleep 1; rm -rf '$RDIR'" || true
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT

if [ -n "${REMOTE:-}" ]; then
    : "${REMOTE_ADDR:?要 REMOTE_ADDR}" "${REMOTE_DIR:?要 REMOTE_DIR}"
    BIN=$(server/scripts/build-linux.sh "${REMOTE_ARCH:-aarch64}" 2> "$TMP/build.log" | tail -1) \
        || { cat "$TMP/build.log"; exit 1; }
    RDIR="$REMOTE_DIR/e2e-$(date +%Y%m%d-%H%M%S)"
    # shellcheck disable=SC2029
    ssh "$REMOTE" "mkdir -p '$RDIR'"
    scp -q "$BIN" "$REMOTE:$RDIR/unireader-server"
    # shellcheck disable=SC2029
    ssh "$REMOTE" "cd '$RDIR' && (nohup ./unireader-server serve --data data --host 0.0.0.0 --port $PORT --no-discovery \
        > server.log 2>&1 & echo \$! > pid)"
    URL="http://$REMOTE_ADDR:$PORT"
else
    (cd server && swift build --disable-automatic-resolution --product unireader-server > "$TMP/build.log" 2>&1) \
        || { cat "$TMP/build.log"; exit 1; }
    # 产物位置随 SwiftPM 版本变（.build/debug 还可能被 Linux 交叉编译改指过去），问它要
    BIN="$(cd server && swift build --disable-automatic-resolution --show-bin-path)/unireader-server"
    "$BIN" serve --data "$TMP/data" --port "$PORT" > "$TMP/server.log" 2>&1 &
    PID=$!
    URL="http://127.0.0.1:$PORT"
fi
for _ in $(seq 1 40); do
    curl -s -o /dev/null "$URL/v1/info" && break
    sleep 0.25
done
if [ -n "$RDIR" ]; then
    # shellcheck disable=SC2029
    CODE=$(ssh "$REMOTE" "cd '$RDIR' && ./unireader-server pairing-code --data data")
else
    CODE=$("$BIN" pairing-code --data "$TMP/data")
fi

cp spike/server-client-test.swift "$TMP/main.swift"
swiftc Sources/Store/*.swift Sources/Sync/*.swift \
    Sources/ServerSync/ServerClient.swift Sources/ServerSync/ServerSyncIO.swift \
    "$TMP/main.swift" -o "$TMP/sct"
SERVER_URL="$URL" PAIRING_CODE="$CODE" WORK_DIR="$TMP" "$TMP/sct"
