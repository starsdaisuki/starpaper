#!/usr/bin/env bash
#
# 造一份「全新设备第一次打开」的 StarPaper，用来肉眼验收首启体验。
#
# 做法：拿当前构建复制一份，换掉 bundle id —— 于是它拿到一个**全新的空
# UserDefaults 域**，等价于一台新设备。每次跑这个脚本都会把那个域清空，
# 所以每次都是干净的第一次启动。
#
# ⚠️ 它**不会碰**你真实 StarPaper 的任何设置（不同的 bundle id = 不同的域）。
# ⚠️ 可执行文件也一起改名，这样 `pkill -x StarPaper` 只会打到真的那份。
#
#   ./tools/first-run-preview.sh          # 重置并启动预览版（新用户默认：时钟关）
#   ./tools/first-run-preview.sh --clock  # 同上，但预先把桌面时钟打开
#   ./tools/first-run-preview.sh --clean  # 只清理，不启动
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/StarPaper.app"
PREVIEW_ID="com.starsdaisuki.starpaper.preview"
PREVIEW_APP="$HOME/Applications/StarPaper Preview.app"

# 先把两份都停掉：同时跑会互相盖壁纸，看不出首启是什么样
pkill -f "StarPaper Preview.app/Contents/MacOS/" 2>/dev/null || true
pkill -x StarPaper 2>/dev/null || true
sleep 0.5

# 清掉预览版自己的设置域 → 下一次启动就是「第一次」
defaults delete "$PREVIEW_ID" 2>/dev/null || true

# 时钟默认是关的（新用户就该看不到）。验收「启动会不会闪出好几个时钟」时
# 需要它开着，否则看不出来 —— 这就是 --clock 的用途。
if [ "${1:-}" = "--clock" ]; then
  defaults write "$PREVIEW_ID" clockEnabled -bool true
  echo "（已预先打开桌面时钟，专门用来看启动会不会闪出重影）"
fi

if [ "${1:-}" = "--clean" ]; then
  [ ! -e "$PREVIEW_APP" ] || /usr/bin/trash "$PREVIEW_APP"
  echo "已清理：预览版 app 进废纸篓，设置域已删。"
  echo "真正的 StarPaper 用这条启动：open ~/Applications/StarPaper.app"
  exit 0
fi

[ -d "$SRC" ] || { echo "先跑一次 make bundle"; exit 1; }

[ ! -e "$PREVIEW_APP" ] || /usr/bin/trash "$PREVIEW_APP"
mkdir -p "$HOME/Applications"
cp -R "$SRC" "$PREVIEW_APP"

# 可执行文件改名，免得跟真的那份在 pkill / 活动监视器里撞在一起
mv "$PREVIEW_APP/Contents/MacOS/StarPaper" "$PREVIEW_APP/Contents/MacOS/StarPaperPreview"
PL="$PREVIEW_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $PREVIEW_ID" "$PL"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable StarPaperPreview" "$PL"
/usr/libexec/PlistBuddy -c "Set :CFBundleName StarPaper Preview" "$PL"
codesign --force --sign - --timestamp=none "$PREVIEW_APP" >/dev/null 2>&1

open "$PREVIEW_APP"
echo "→ 已按「全新设备第一次打开」启动：$PREVIEW_APP"
echo "  应该看到：桌面立刻开始播黑洞 + 弹出设置窗口。"
echo "  再看一次首启：重跑这个脚本。"
echo "  看完收摊：./tools/first-run-preview.sh --clean"
echo "  真正的 StarPaper：open ~/Applications/StarPaper.app"
