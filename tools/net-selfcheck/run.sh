#!/bin/bash
# 真机联网自检：三类行情的降级链是否真的取到数、命中了哪一级
#
# 与 alert-selfcheck 的分工：那个跑纯逻辑断言（不联网），这个真发请求。
# 接口口径变了、字段改名了、Referer 要求变了，只有真请求才知道。
#
# 用法：./tools/net-selfcheck/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

echo "编译自检程序…"
xcrun swiftc -Onone \
  Config/TradingCalendar.swift \
  Data/DataLayer.swift Data/QuoteChain.swift Data/FundEstimator.swift \
  Panel/DesignSystem.swift Panel/DataFreshness.swift \
  tools/net-selfcheck/main.swift \
  -o "$OUT/netselfcheck" -framework SwiftUI -framework AppKit 2>&1 | tail -20

echo "开始真机联网验证…"
"$OUT/netselfcheck"
