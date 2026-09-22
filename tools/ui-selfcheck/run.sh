#!/bin/bash
# ============================================================
# 界面结构门禁：渲染设置页，检查卡片有没有「被拆散」
#
# 用法: ./tools/ui-selfcheck/run.sh
# 覆盖: SettingsCard / MarketCard 这类容器型 View 的「多子视图 modifier 分发」回归 ——
#       content 若是多个平铺子视图，背景与描边会逐个子视图各画一遍，
#       一张卡片变成 N 个小卡片，行间多出约 4pt 的隐式间距。
#       编译全绿、签名通过、启动不崩，只有像素看得出来，所以这里真的渲染一次再判。
#
# 分工：main.swift 只负责渲染出 PNG（Swift 侧取像素在本机不可靠，见 analyze.py 注释），
#       analyze.py 负责判读。判据是「相邻卡片段之间的底色横缝短于 15pt」——
#       拆散时行间会露出约 4pt 的面板底色，正常卡片之间是 23pt（区块间距）
#       或 56pt（间距 + 区块标题）。深色浅色两套主题各判一次；
#       浅色下两种底色同为纯白，颜色判据不适用，此时只比两套主题的整页高度是否一致。
#
# 出图的高度 = 内容真实高度（main.swift 会把窗口收到 ScrollView 的 documentView 高度），
# 不是窗口高度 —— 否则图片底部会留一大片空白，高度读数也失去意义。
#
# 反向验证（改判据时必须重跑，否则可能写出"永远通过"的门禁）：
#   把 DesignSystem.swift 里 SettingsCard/MarketCard 的 VStack(spacing: 0) 包裹去掉，
#   再跑本脚本，应看到 dark 主题报 6 处 4.0pt 横缝、整页高从 1256pt 变成 1286pt 且失败退出。
#
# 源码清单从 build_dmg.sh 第 1 步提取，与正式构建共用同一份，避免两处漂移。
# 全部通过时退出码 0，任何一条失败退出码 1。
# ============================================================

set -e
cd "$(dirname "$0")/../.."

OUT="${TMPDIR:-/tmp}/invest-ui-selfcheck"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "========== 编译 =========="
FILES=$(sed -n '/^xcrun swiftc/,/-o "投资监控"/p' build_dmg.sh \
        | sed '1d;$d' | tr -d '\\' | tr '\n' ' ' | tr -s ' ' \
        | sed 's#InvestmentBarApp.swift##')
COUNT=$(echo "$FILES" | wc -w | tr -d ' ')
if [ "$COUNT" -lt 10 ]; then
  echo "从 build_dmg.sh 提取源文件清单失败（只取到 ${COUNT} 个）。"
  echo "请检查 build_dmg.sh 第 1 步的命令格式是否变了。"
  exit 1
fi
echo "源文件 ${COUNT} 个（提取自 build_dmg.sh，与正式构建同一份）"

xcrun swiftc -Onone $FILES tools/ui-selfcheck/main.swift \
  -o "$OUT/ui-shot" -framework SwiftUI -framework AppKit -lsqlite3 -parse-as-library

echo "========== 组装临时 .app =========="
# UserNotifications 要求进程有 bundle 标识，裸二进制会在 MenuBarController.init
# 里直接抛 NSInternalInconsistencyException 退出，所以套一层最小 .app
APP="$OUT/UIShot.app"
mkdir -p "$APP/Contents/MacOS"
cp "$OUT/ui-shot" "$APP/Contents/MacOS/ui-shot"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>ui-shot</string>
	<key>CFBundleIdentifier</key><string>com.dreamanual.investmonitor.uishot</string>
	<key>CFBundleName</key><string>UIShot</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "========== 渲染 =========="
"$APP/Contents/MacOS/ui-shot" "$OUT"

echo "========== 判读 =========="
# 只用标准库（zlib / array / struct），不引第三方依赖
PY=""
for c in /usr/bin/python3 "$(command -v python3 2>/dev/null)" \
         "$HOME/.workbuddy/binaries/python/versions/3.13.12/bin/python3"; do
  if [ -n "$c" ] && [ -x "$c" ] && "$c" -c "import zlib, array, struct" 2>/dev/null; then
    PY="$c"
    break
  fi
done
if [ -z "$PY" ]; then
  echo "找不到可用的 python3（只需要标准库 zlib / array / struct）"
  exit 1
fi
"$PY" tools/ui-selfcheck/analyze.py "$OUT/settings-dark.png" "$OUT/settings-light.png"
