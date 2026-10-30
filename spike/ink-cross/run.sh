#!/bin/bash
# 笔迹绘制对比工具（Mac ↔ 安卓）—— 一键驱动。网页采集页 2026-10-30 删除，web 那一端随之去掉。
#
#   spike/ink-cross/run.sh              # 两端都跑 + 出报告
#   spike/ink-cross/run.sh mac          # 只跑这几端（省掉安卓那 30 秒）
#   spike/ink-cross/run.sh report       # 用已有的图重出报告
#   spike/ink-cross/run.sh gen          # 重新生成向量（改了 gen-vectors.py 之后）
#
# 产物：`spike/ink-cross/out/{mac,android}/<笔画名>.png` + `out/report.html`（用浏览器打开）。
#
# 两端出图的**共同口径**（改一处必须同时改另一处，否则比的是口径不是算法）：
#   · 位图 = canvas.w × canvas.h × canvas.scale 物理像素（当前 1800×1200）
#   · 笔宽 = vectors 里的 width × canvas.scale 物理像素
#     mac 走 `ImageRenderer.scale=2`；android 走 `InkRenderer(scale)`
#     （安卓那个参数名叫 density，但这里喂的是 scale，**不是设备真实 density**——见测试里的红线）
#   · 白色不透明底，无缩放重采样
#
# 兼容 bash 3.2（系统自带那个），别加关联数组/mapfile。

set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT="$PWD"
HERE="$ROOT/spike/ink-cross"
OUT="$HERE/out"
VEC="$HERE/vectors.json"
PY="${INKCROSS_PY:-$HOME/.agents/_internal/_tmp/.venv/bin/python}"

want() { case " $TARGETS " in *" $1 "*) return 0;; *) return 1;; esac; }

TARGETS="$*"
[ -z "$TARGETS" ] && TARGETS="mac android report"
case "$TARGETS" in *gen*) ;; *) ;; esac

mkdir -p "$OUT"

# ---------- 向量 ----------
if want gen || [ ! -f "$VEC" ]; then
  echo "▸ 生成向量"
  python3 "$HERE/gen-vectors.py" || exit 1
fi

# ---------- macOS ----------
if want mac; then
  echo "▸ macOS 出图"
  mkdir -p "$OUT/mac"
  # 🔴 文件名**必须**是 `main.swift`：swiftc 只允许这一个文件名带顶层表达式，叫别的名字
  # 会报一串 "expressions are not allowed at the top level"（报的是结果不是原因，很容易去改代码）。
  mkdir -p /tmp/inkcross-build
  cp "$HERE/mac.swift" /tmp/inkcross-build/main.swift
  # 🔴 只编渲染那几个文件——`UniReaderApp.swift` 带 @main 且拖着整个 App 层，编不进 spike。
  swiftc \
    "$ROOT/Sources/Views/InkLayers.swift" \
    "$ROOT/Sources/App/InkModel.swift" \
    "$ROOT/Sources/App/InkLayerModel.swift" \
    "$ROOT/Sources/App/PenPreset.swift" \
    "$ROOT/Sources/App/NoteTypeModel.swift" \
    "$ROOT/Sources/App/TextNoteModel.swift" \
    "$ROOT/Sources/Store/LibraryModels.swift" \
    "$ROOT/Sources/Support/L.swift" \
    /tmp/inkcross-build/main.swift -o /tmp/inkcross-mac || { echo "✗ macOS 端编译失败"; exit 1; }
  /tmp/inkcross-mac "$VEC" "$OUT/mac" || exit 1
fi

# ---------- android ----------
if want android; then
  echo "▸ 安卓出图"
  if ! adb devices | grep -qE "device$"; then
    echo "  ⚠️ 没有在线设备（adb devices 为空），跳过安卓端。"
    echo "     模拟器：\$ANDROID_HOME/emulator/emulator -avd <名字> &"
  else
    mkdir -p "$OUT/android"
    rm -f "$OUT/android"/*.png
    mkdir -p "$ROOT/android/app/src/androidTest/assets"
    cp "$VEC" "$ROOT/android/app/src/androidTest/assets/ink-cross-vectors.json"
    # 🔴 `leaveApksInstalledAfterRun` 不能省：AGP 默认跑完就卸载 app，而图写在 app 专属目录里，
    # 卸载连图一起没——第一次就栽在这儿（测试全绿、目录不存在）。
    ( cd "$ROOT/android" && ./gradlew connectedDebugAndroidTest \
        -Pandroid.testInstrumentationRunnerArguments.class=com.xvan.unireader.shared.InkCrossProbeTest \
        -Pandroid.injected.androidTest.leaveApksInstalledAfterRun=true ) \
      >/tmp/inkcross-android.log 2>&1
    if [ $? -ne 0 ]; then
      echo "✗ 安卓端测试失败，看 /tmp/inkcross-android.log"
      tail -20 /tmp/inkcross-android.log
    else
      adb pull /sdcard/Android/data/com.xvan.unireader/files/ink-cross/. "$OUT/android/" >/dev/null 2>&1
      echo "  安卓端出图 $(ls "$OUT/android" | wc -l | tr -d ' ') 张"
    fi
  fi
fi

# ---------- 报告 ----------
if want report; then
  echo "▸ 汇总报告"
  if [ ! -x "$PY" ]; then
    echo "✗ 找不到带 numpy/PIL 的 python：$PY"
    echo "  建环境的命令交给用户跑：cd ~/.agents && bash scripts/setup-python-scienv.sh"
    exit 1
  fi
  "$PY" "$HERE/report.py" "$VEC" "$OUT" || exit 1
  echo "  → open $OUT/report.html"
fi
