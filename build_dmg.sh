#!/bin/bash
# ============================================================
# InvestmentBar 一键打包脚本
# 用法:
#   ./build_dmg.sh               # 全流程：编译 → 组装 → 签名 → 启动冒烟 → 界面门禁 → 打包 DMG
#   ./build_dmg.sh --app-only    # 只到 app，跳过 DMG（先本地测试用）
#   ./build_dmg.sh --skip-smoke  # 跳过启动冒烟（不想在构建时真启动 app 时用）
#   ./build_dmg.sh --skip-ui     # 跳过界面结构门禁（只想快速拿个包时用）
# 前置: app 图标/背景图/安装说明已放在 assets/dmg/
# ============================================================
#
# 【第 5 步：界面结构门禁】
#   2026-09-22 踩过一次：设置页「运行状态」卡片被拆成 4 张小卡片。
#   编译全绿、签名通过、启动不崩、冒烟也过 —— 只有真渲染出来的像素看得出来
#   （SettingsCard 把 .background/.cornerRadius/.overlay 逐个分发到了每行上）。
#   所以这里真的渲染一次设置页，量卡片之间的横缝宽度判定，失败即中断构建。
#   反向验证过：把修复回退后的版本跑这条门禁会报 6 处 4pt 横缝。
#   细节见 tools/ui-selfcheck/ 下三个文件的头注释。
#
# 【第 4 步：启动冒烟】
#   构建全绿 ≠ 能启动。2026-09-22 踩过一次：xcrun 编译成功、codesign 通过，
#   一启动就 SIGTRAP 退出（init 里 restoreSnapshot() 排在 setupStatusItem() 之前，
#   updateStatusTitle() 解包了还是 nil 的 statusItem）。光看编译输出完全看不出来。
#   所以这里把二进制真的跑起来，观察 8 秒，用「进程还活着」判定，
#   失败时把新产生的崩溃报告路径和 app 输出一起打出来，并让整个构建以非零码退出。
#
# 【.app 组装在 dist/，不留在项目根】
#   2026-09-23 之前组装在项目根。项目根下的 .app 会被 LaunchServices 注册、
#   被 Spotlight 索引，于是启动台里出现两份同名应用（副标题写着它所在的文件夹）。
#   现在组装到 dist/，打包完 DMG 之后自动装进 /Applications 并从 dist/ 移走。
#   appdmg 要读 dist/ 里的这个包当输入，所以安装必须排在打包之后。
#
# 【DMG 打包方案与踩过的坑】
#   - 工具: appdmg 0.6.6，通过 npx 调用。脚本自己定位 node，
#     不依赖你终端 PATH 里有没有 node。
#   - appdmg 依赖 ds-store 包直接写 .DS_Store，不走 Finder AppleScript，
#     所以不需要任何系统权限，也不会弹「允许控制 Finder」。
#   - 报 ERR_DLOPEN_FAILED / "NODE_MODULE_VERSION 不匹配" 时：npx 缓存里的原生模块
#     macos-alias 是针对别的 node 版本编译的（如按 Node 24 编译、现在跑 Node 22）。
#     清掉缓存重装即可：
#       mv ~/.npm/_npx/e7416f65c8e13ed4 ~/.Trash/    # 或删掉整个 ~/.npm/_npx
#   - 找不到 node，或 appdmg 失败时：自动降级为原生 hdiutil 打包
#     （内容一致，窗口为默认布局、无背景图），并打印原因。
# ============================================================

set -e

cd "$(dirname "$0")"

APP_NAME="dist/Dreamanual 投资监控.app"
APP_BASE="$(basename "$APP_NAME")"
VOL_NAME="Dreamanual 投资监控"
DMG_OUT="dist/Dreamanual 投资监控.dmg"

APP_ONLY=0
SKIP_SMOKE=0
SKIP_UI=0
for arg in "$@"; do
  case "$arg" in
    --app-only|--no-dmg) APP_ONLY=1 ;;
    --skip-smoke) SKIP_SMOKE=1 ;;
    --skip-ui) SKIP_UI=1 ;;
  esac
done

# 步骤总数：编译 / 组装 / 签名 固定三步，冒烟、界面门禁与 DMG 按需加
TOTAL=3
if [ "$SKIP_SMOKE" -eq 0 ]; then TOTAL=$((TOTAL + 1)); fi
if [ "$SKIP_UI" -eq 0 ]; then TOTAL=$((TOTAL + 1)); fi
if [ "$APP_ONLY" -eq 0 ]; then TOTAL=$((TOTAL + 1)); fi

echo "========== 1/$TOTAL 编译 =========="
# -disable-sandbox：本机 Xcode 的 swift-plugin-server 在被沙箱隔离时会异常退出（信号 137），
# 所有宏（@State / @Observable 等）展开失败并报 "produced malformed response"。说明见
# tools/ui-selfcheck/run.sh。终端里本就不受限，加了对正常流程无影响。
xcrun swiftc -disable-sandbox -O \
  Config/AlertConfig.swift Config/ConfigStore.swift Config/TradingCalendar.swift \
  Alert/AlertRule.swift Alert/AlertStateMachine.swift Alert/JudgeWindow.swift \
  Alert/AlertEngine.swift Alert/AlertEventStore.swift Alert/AlertNotifier.swift \
  Data/DataLayer.swift Data/QuoteChain.swift Data/FundEstimator.swift Data/SnapshotStore.swift \
  Panel/DreamanualTheme.invest.swift Panel/DesignSystem.swift Panel/DataFreshness.swift Panel/MainPanelView.swift Panel/SettingsView.swift \
  Panel/AlertView.swift Panel/SectorView.swift Panel/FundView.swift Panel/TrendChart.swift \
  MenuBarController.swift UpdateChecker.swift InvestmentBarApp.swift \
  -o "投资监控" -framework SwiftUI -framework AppKit -lsqlite3 -parse-as-library
echo "编译成功"

echo "========== 2/$TOTAL 组装 app =========="
rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/Contents/MacOS"
mkdir -p "$APP_NAME/Contents/Resources/icons"
cp "投资监控" "$APP_NAME/Contents/MacOS/投资监控"
cp Info.plist "$APP_NAME/Contents/Info.plist"
cp "assets/dmg/AppIcon.icns" "$APP_NAME/Contents/Resources/AppIcon.icns"
# 图标 PNG：从 assets/icons/*.svg 转换（若 PNG 已存在直接复制）
if ls assets/icons/*.png &>/dev/null; then
  cp assets/icons/*.png "$APP_NAME/Contents/Resources/icons/"
elif ls assets/icons/*.svg &>/dev/null; then
  swift .temp/convert_icons.swift 2>/dev/null || true
  cp assets/icons/*.png "$APP_NAME/Contents/Resources/icons/" 2>/dev/null || true
fi
echo "app 组装完成"

echo "========== 3/$TOTAL 签名 =========="
codesign --force --deep --sign - "$APP_NAME"
echo "签名完成"

# 启动冒烟：把刚组装的二进制真的跑起来，8 秒内不退出才算通过。
# 判定用「进程存活」这个硬信号，崩溃报告只作补充信息（ReportCrash 落盘有延迟，
# 不能只靠它判定，否则失败会漏报）。
smoke_launch() {
  local marker out pid alive=0 crash i
  marker="$(mktemp)"
  out="$(mktemp)"
  echo "启动临时实例，观察 8 秒…"
  "$APP_NAME/Contents/MacOS/投资监控" >"$out" 2>&1 &
  pid=$!
  for i in 1 2 3 4 5 6 7 8; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then alive=1; fi
  crash="$(find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -name '投资监控*.ips' -newer "$marker" 2>/dev/null | head -1 || true)"
  if [ "$alive" -eq 1 ]; then kill "$pid" 2>/dev/null || true; fi
  # 回收子进程：不加 wait 时 shell 会额外打印一行 "Terminated"，看着像出错
  wait "$pid" 2>/dev/null || true
  if [ "$alive" -eq 1 ]; then
    rm -f "$marker" "$out"
    echo "启动冒烟通过（8 秒内未退出；临时实例已退出）"
    return 0
  fi
  echo ""
  echo "❌ 启动冒烟失败：app 在 8 秒内退出（编译成功但跑不起来）"
  if [ -n "$crash" ]; then echo "   崩溃报告: $crash"; fi
  if [ -s "$out" ]; then
    echo "   ---- app 输出 ----"
    cat "$out"
    echo "   ------------------"
  fi
  rm -f "$marker" "$out"
  return 1
}

# 把组装好的 app 装进 /Applications，dist/ 里不留 .app。
# 为什么要有这一步：dist/ 下的 .app 是个结构完整的应用包，会被 LaunchServices
# 注册、被 Spotlight 索引 —— 启动台里于是出现两份同名应用，副标题写着它所在的
# 文件夹（这里就是「投资监控」）。装完挪走，开发目录只留 DMG。
# 注意：必须在 DMG 打包之后调用 —— appdmg 要读 dist/ 里的这个包当输入。
install_app() {
  local name stamp trash old_ver src_hash dst_hash
  name="$APP_BASE"
  stamp="$(date +%Y%m%d-%H%M%S)"
  trash="$HOME/.Trash"

  if [ ! -d "$APP_NAME" ]; then
    # 变量后面紧跟中文标点时要写成 ${VAR}：$VAR，这种写法 bash 会把标点的字节
    # 吃进变量名，整个变量展开为空，只留下乱码。
    echo "找不到 ${APP_NAME}，跳过安装"
    return 1
  fi

  if [ -e "/Applications/$name" ]; then
    old_ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "/Applications/$name/Contents/Info.plist" 2>/dev/null || true)"
    mv "/Applications/$name" "$trash/$name.replaced-$stamp"
    echo "  旧包已移入废纸篓（版本 ${old_ver:-未知}）：$trash/$name.replaced-$stamp"
  fi

  if ! ditto "$APP_NAME" "/Applications/$name"; then
    echo "❌ 复制失败；旧包在废纸篓里，可手工放回"
    return 1
  fi

  src_hash="$(shasum -a 256 "$APP_NAME/Contents/MacOS/投资监控" 2>/dev/null | cut -d' ' -f1 || true)"
  dst_hash="$(shasum -a 256 "/Applications/$name/Contents/MacOS/投资监控" 2>/dev/null | cut -d' ' -f1 || true)"
  if [ -z "$src_hash" ] || [ "$src_hash" != "$dst_hash" ]; then
    echo "❌ 校验失败：装过去的二进制与源对不上，回滚"
    echo "   源 ${src_hash:-读不到} / 目标 ${dst_hash:-读不到}"
    rm -rf "/Applications/$name"
    if [ -e "$trash/$name.replaced-$stamp" ]; then
      echo "   旧包在废纸篓：$trash/$name.replaced-$stamp"
    fi
    return 1
  fi

  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$name" 2>/dev/null || true
  echo "  已安装：/Applications/${name}（二进制 ${src_hash:0:12}…）"

  if mv "$APP_NAME" "$trash/$name.source-$stamp"; then
    echo "  dist 里的副本已移入废纸篓：$trash/$name.source-$stamp"
  else
    echo "  dist 里的副本没挪走（不影响安装）"
  fi
}

STEP=3
if [ "$SKIP_SMOKE" -eq 0 ]; then
  STEP=$((STEP + 1))
  echo "========== $STEP/$TOTAL 启动冒烟（冷启动不崩） =========="
  # 覆盖范围：只有「存在快照」时才会走到 init 里 restoreSnapshot() 末尾那次
  # updateStatusTitle()（没有快照会提前 return），所以先说明当前有无快照
  if defaults read com.dreamanual.investmonitor com.dreamanual.investmonitor.Snapshot.v1 >/dev/null 2>&1; then
    echo "（检测到上一轮快照 → 本次覆盖「有快照冷启动」路径）"
  else
    echo "（当前无快照 → 未覆盖「有快照冷启动」路径；先正常启动一次 app 再重跑即可覆盖）"
  fi
  smoke_launch
fi

# 界面结构门禁：编译、签名、启动都绿了也不代表长得对，所以真渲染一次设置页。
# 失败时把「怎么修」直接打出来 —— 这条门禁拦的是写法问题，不看源码定位不到。
if [ "$SKIP_UI" -eq 1 ]; then
  echo "========== 界面结构门禁（已按 --skip-ui 跳过） =========="
else
  STEP=$((STEP + 1))
  echo "========== $STEP/$TOTAL 界面结构门禁（卡片没被拆散） =========="
  if ! tools/ui-selfcheck/run.sh; then
    echo ""
    echo "❌ 界面结构门禁未通过：设置页有卡片被「拆散」成多个小块。"
    echo "   编译、签名、启动冒烟都是绿的，但真渲染出来的像素能看出来。"
    echo "   最常见原因：SettingsCard / FormCard 这类容器型 View 的 content 是多个"
    echo "   平铺子视图（ViewBuilder 的 TupleView），.background / .cornerRadius / .overlay"
    echo "   会逐个子视图各画一遍 —— 一张卡片变成 N 张，行间还会多出约 4pt 隐式间距。"
    echo "   修法：容器内先包一层 VStack(spacing: 0)，再套背景与描边。"
    echo "   截图留在: ${TMPDIR:-/tmp}/invest-ui-selfcheck/"
    exit 1
  fi
fi

if [ "$APP_ONLY" -eq 1 ]; then
  echo "========== 跳过 DMG 打包（--app-only） =========="
  echo "app 已组装: $APP_NAME"
  echo ""
  echo "========== 收尾：安装到 /Applications =========="
  install_app || exit 1
  echo ""
  echo "重启以测试:"
  echo "  pkill -f '投资监控'; sleep 1; open '/Applications/$APP_BASE'"
  exit 0
fi

STEP=$((STEP + 1))
echo "========== $STEP/$TOTAL 打包 DMG =========="

# 定位 node：优先系统 node，其次 WorkBuddy 托管运行时（取最高版本）
find_node() {
  local c best
  for c in "$(command -v node 2>/dev/null)" /opt/homebrew/bin/node /usr/local/bin/node; do
    if [ -n "$c" ] && [ -x "$c" ]; then echo "$c"; return 0; fi
  done
  best="$(ls -d "$HOME"/.workbuddy/binaries/node/versions/*/bin/node 2>/dev/null | sort -V | tail -1)"
  if [ -n "$best" ] && [ -x "$best" ]; then echo "$best"; return 0; fi
  return 1
}

# 降级方案：原生 hdiutil（不依赖 node；窗口为默认布局、无背景图）
dmg_via_hdiutil() {
  local work stage tmp mnt
  work="$(mktemp -d)"
  stage="$work/stage"
  mkdir -p "$stage"
  cp -R "$APP_NAME" "$stage/"
  cp "assets/dmg/安装说明.txt" "$stage/"
  ln -s /Applications "$stage/Applications"
  tmp="$work/tmp.dmg"
  hdiutil create -volname "$VOL_NAME" -srcfolder "$stage" -ov -format UDRW -fs HFS+ "$tmp" >/dev/null
  mnt="$(hdiutil attach "$tmp" -readwrite -noverify -noautoopen | grep -o '/Volumes/.*' | head -1)"
  hdiutil detach "$mnt" >/dev/null 2>&1 || hdiutil detach "$mnt" -force >/dev/null 2>&1 || true
  hdiutil convert "$tmp" -format UDZO -imagekey zlib-level=9 -o "$DMG_OUT" >/dev/null
  rm -rf "$work"
}

rm -f "$DMG_OUT"

NODE_BIN="$(find_node || true)"
DMG_OK=0

if [ -z "$NODE_BIN" ]; then
  echo "未找到 node，跳过 appdmg，改用原生 hdiutil 打包"
  echo "（想要带背景图的 DMG，请先安装 node 再重跑本脚本）"
else
  echo "使用 node: $NODE_BIN ($("$NODE_BIN" -v 2>/dev/null))"
  if PATH="$(dirname "$NODE_BIN"):$PATH" npx --yes appdmg "assets/dmg/dmg_config.json" "$DMG_OUT"; then
    DMG_OK=1
  else
    echo ""
    echo "appdmg 打包失败。最常见原因：npx 缓存里的原生模块与当前 node 版本不匹配。"
    echo "  修复: mv ~/.npm/_npx/e7416f65c8e13ed4 ~/.Trash/ 之后重跑本脚本"
    echo "现改用原生 hdiutil 降级打包。"
  fi
fi

if [ "$DMG_OK" -eq 1 ]; then
  echo "DMG 打包完成（appdmg，含背景图与图标位置）"
else
  dmg_via_hdiutil
  echo "DMG 打包完成（降级模式：默认窗口布局，无背景图）"
fi

echo "========== 完成 =========="
ls -lh "$DMG_OUT"
echo ""
echo "========== 收尾：安装到 /Applications =========="
install_app || exit 1
echo ""
echo "可选: 启动新版 app"
echo "  pkill -f '投资监控'; sleep 1; open '/Applications/$APP_BASE'"
