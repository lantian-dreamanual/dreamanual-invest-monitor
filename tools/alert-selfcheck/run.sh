#!/bin/bash
# ============================================================
# 预警判定层 + R 系列 自检（纯逻辑，不联网）
#
# 用法: ./tools/alert-selfcheck/run.sh
# 覆盖: W1 判定口径 / W2 确认天数 / W4 判定窗口 / 频控与轮次边界 /
#       W7 同品种合并 / W8 无判定价留痕 / 状态机边界 / 规则解码向后兼容 /
#       R1 交易日历 / R2 降级链 / R3 数据时效 / R5 估值覆盖度 / R7 配置容错
#
# 断言跑在独立的临时库文件上，不碰 ~/Library/Application Support 里的真实数据。
# 全部通过时退出码 0，任何一条失败退出码 1 —— 可以直接挂进提交前检查。
# 联网部分另见 tools/net-selfcheck/run.sh。
# ============================================================

set -e
cd "$(dirname "$0")/../.."

OUT="${TMPDIR:-/tmp}/invest-alert-selfcheck"
mkdir -p "$OUT"

echo "========== 编译 =========="
xcrun swiftc -Onone \
  Alert/AlertRule.swift Alert/AlertStateMachine.swift Alert/JudgeWindow.swift \
  Alert/AlertEngine.swift Alert/AlertEventStore.swift \
  Config/ConfigStore.swift Config/TradingCalendar.swift \
  Data/DataLayer.swift Data/QuoteChain.swift Data/FundEstimator.swift Data/SnapshotStore.swift \
  Panel/DesignSystem.swift Panel/DataFreshness.swift \
  tools/alert-selfcheck/main.swift \
  -o "$OUT/alerttests" -framework SwiftUI -framework AppKit -lsqlite3 \

echo "========== 运行 =========="
"$OUT/alerttests"
