import SwiftUI

/// 分时线图表模式
enum TrendChartMode {
    case aStock       // A股板块：固定时段 09:30-11:30/13:00-15:00
    case shfeGold     // 沪金：夜盘 21:00-02:30 + 日盘 09:00-11:30 / 13:30-15:00（跨日，午休跳过）
}

/// 分时线图表：价格线 + 均价线 + 昨收虚线 + 涨跌填充 + 坐标标注 + 底部刻度尺 + hover 十字线
struct TrendChart: View {
    let trend: TrendData
    var mode: TrendChartMode = .aStock

    @State private var hoverX: Double? = nil  // 鼠标在 Canvas 内的 x 坐标
    @State private var lastHoverUpdate: Date = .distantPast  // 方案B：hover 重绘节流

    /// 从最后一个数据点提取截止时间文案，如 "09/05 02:30" 或 "14:59"
    private var lastUpdateText: String {
        guard let last = trend.points.last else { return "" }
        let raw = last.time
        // shfeGold 模式保留完整 "YYYY-MM-DD HH:mm"，aStock 模式只有 "HH:mm"
        if let spaceIdx = raw.firstIndex(of: " ") {
            let dateStr = String(raw[..<spaceIdx])           // 2026-09-05
            let timeStr = String(raw[raw.index(after: spaceIdx)...])  // 02:30
            // 提取 MM/DD
            let parts = dateStr.split(separator: "-")
            if parts.count >= 3 {
                return "\(parts[1])/\(parts[2]) \(timeStr)"
            }
            return timeStr
        }
        return raw
    }

    var body: some View {
        if trend.points.isEmpty {
            Text("暂无分时数据")
                .font(.caption)
                .foregroundColor(Color.dmInk2)
                .frame(maxWidth: .infinity)
                .frame(height: 130)
        } else {
            VStack(spacing: 0) {
                Canvas { context, size in
                    drawChart(context: context, size: size)
                    if let hx = hoverX {
                        drawHover(context: context, size: size, mouseX: hx)
                    }
                }
                .frame(height: 130)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        // 方案B：对 hover 更新做节流，避免高频移动鼠标时不断触发 Canvas 全量重绘
                        let now = Date()
                        guard now.timeIntervalSince(lastHoverUpdate) >= 0.033 else { return }
                        lastHoverUpdate = now
                        // 仅在 x 坐标变化时才触发重绘，避免无谓的 state 更新
                        if abs((hoverX ?? .infinity) - location.x) >= 0.5 {
                            hoverX = location.x
                        }
                    case .ended:
                        if hoverX != nil { hoverX = nil }
                    }
                }
                // 数据截止时间提示
                HStack(spacing: 0) {
                    Spacer()
                    Text("最后更新 \(lastUpdateText)")
                        .font(.system(size: 9))
                        .foregroundColor(Color.dmInk3)
                }
                .padding(.top, 2)
            }
        }
    }

    // Canvas 实际尺寸通过渲染时捕获，用于 hover 边界判断

    /// A股交易分钟数（09:30=0, 11:30=120, 13:00=120, 15:00=240）
    private func tradingMinutes(_ time: String) -> Double {
        // 兼容 "YYYY-MM-DD HH:mm" 和 "HH:mm" 两种格式
        let timePart: String
        if let spaceIdx = time.firstIndex(of: " ") {
            timePart = String(time[time.index(after: spaceIdx)...])
        } else {
            timePart = time
        }
        let parts = timePart.split(separator: ":")
        guard parts.count == 2, let h = Double(parts[0]), let m = Double(parts[1]) else { return 0 }
        let totalMin = (h * 60 + m) - (9 * 60 + 30)
        if totalMin > 120 { return totalMin - 90 }
        return totalMin
    }

    /// 沪金交易分钟数映射
    /// 夜盘 21:00-02:30 = 330 分钟（21:00→0, 02:30→330）
    /// 日盘上午 09:00-11:30 = 150 分钟（09:00→330, 11:30→480）
    /// 午休 11:30-13:30 跳过（不占 x 轴）
    /// 日盘下午 13:30-15:00 = 90 分钟（13:30→480, 15:00→570）
    /// 总交易时长 570 分钟
    private func shfeGoldMinutes(_ datetime: String) -> Double {
        let timePart: String
        if let spaceIdx = datetime.firstIndex(of: " ") {
            timePart = String(datetime[datetime.index(after: spaceIdx)...])
        } else {
            timePart = datetime
        }
        let parts = timePart.split(separator: ":")
        guard parts.count == 2, let h = Double(parts[0]), let m = Double(parts[1]) else { return 0 }
        let totalMin = h * 60 + m

        if totalMin >= 21 * 60 {
            // 夜盘 21:00-02:30 → 0~330
            return totalMin - 21 * 60
        } else if totalMin <= 2 * 60 + 30 {
            // 夜盘跨日 → 0~330
            return totalMin + 3 * 60
        } else if totalMin >= 9 * 60 && totalMin <= 11 * 60 + 30 {
            // 日盘上午 09:00-11:30 → 330~480
            return totalMin - 9 * 60 + 330
        } else if totalMin > 11 * 60 + 30 && totalMin < 13 * 60 + 30 {
            // 午休 11:30-13:30 → 归到上午末尾
            return 480
        } else if totalMin >= 13 * 60 + 30 {
            // 日盘下午 13:30-15:00 → 480~570
            return totalMin - (13 * 60 + 30) + 480
        }
        return 480
    }

    private static let shfeGoldTotalMinutes: Double = 570

    // MARK: - 布局参数

    private var leftPad: Double { 8.0 }
    private var topPad: Double { 10.0 }
    private var bottomPad: Double { 24.0 }
    private var rightPad: Double { 4.0 }

    private func chartGeom(_ size: CGSize) -> (chartX: Double, chartY: Double, chartW: Double, chartH: Double) {
        let chartW = size.width - leftPad - rightPad
        let chartH = size.height - topPad - bottomPad
        return (leftPad, topPad, chartW, chartH)
    }

    // MARK: - 数据范围

    private var valueRange: (lo: Double, hi: Double) {
        let points = trend.points
        let preClose = trend.preClose
        let validAvgs = points.map { $0.avgPrice }.filter { $0 > 0 }
        let allPrices = points.map { $0.price } + validAvgs + [preClose]
        let minP = allPrices.min() ?? preClose
        let maxP = allPrices.max() ?? preClose
        let range = maxP - minP
        let padding = range > 0 ? range * 0.1 : maxP * 0.001
        return (minP - padding, maxP + padding)
    }

    // MARK: - x 坐标映射

    private func xPos(_ i: Int, points: [TrendPoint], chartX: Double, chartW: Double) -> Double {
        switch mode {
        case .aStock:
            let mins = tradingMinutes(points[i].time)
            return chartX + mins / 240.0 * chartW
        case .shfeGold:
            let mins = shfeGoldMinutes(points[i].time)
            return chartX + mins / Self.shfeGoldTotalMinutes * chartW
        }
    }

    private func yPos(_ v: Double, chartY: Double, chartH: Double, lo: Double, valRange: Double) -> Double {
        chartY + chartH - (v - lo) / valRange * chartH
    }

    /// 通过鼠标 x 坐标找到最近的数据点索引
    private func indexAtX(_ mouseX: Double, points: [TrendPoint], chartX: Double, chartW: Double) -> Int? {
        guard !points.isEmpty else { return nil }
        var bestIdx = 0
        var bestDist = Double.infinity
        for i in 0..<points.count {
            let x = xPos(i, points: points, chartX: chartX, chartW: chartW)
            let dist = abs(x - mouseX)
            if dist < bestDist {
                bestDist = dist
                bestIdx = i
            }
        }
        return bestIdx
    }

    // MARK: - 绘图

    private func drawChart(context: GraphicsContext, size: CGSize) {
        let points = trend.points
        let preClose = trend.preClose
        let (chartX, chartY, chartW, chartH) = chartGeom(size)
        let (lo, hi) = valueRange
        let valRange = hi - lo
        let count = points.count
        guard count > 1 else { return }

        func xp(_ i: Int) -> Double { xPos(i, points: points, chartX: chartX, chartW: chartW) }
        func yp(_ v: Double) -> Double { yPos(v, chartY: chartY, chartH: chartH, lo: lo, valRange: valRange) }

        // 1. 绘图区边框
        context.stroke(
            Path(CGRect(x: chartX, y: chartY, width: chartW, height: chartH)),
            with: .color(.gray.opacity(0.12)),
            style: StrokeStyle(lineWidth: 0.5)
        )

        // 1b. 未交易区域底色
        let lastX = xp(count - 1)
        let chartRight = chartX + chartW
        if lastX < chartRight - 1 {
            let untradedRect = CGRect(x: lastX, y: chartY, width: chartRight - lastX, height: chartH)
            context.fill(Path(untradedRect), with: .color(.gray.opacity(0.06)))
        }

        // 2. A股午休 / 沪金断档分界线
        if mode == .aStock {
            let midX = chartX + 0.5 * chartW
            drawDashedVLine(context, x: midX, chartY: chartY, chartH: chartH, opacity: 0.15, dash: [4, 4])
        } else if mode == .shfeGold {
            let nightEndRatio = 330.0 / Self.shfeGoldTotalMinutes
            let lunchEndRatio = 480.0 / Self.shfeGoldTotalMinutes
            drawDashedVLine(context, x: chartX + nightEndRatio * chartW, chartY: chartY, chartH: chartH, opacity: 0.15, dash: [4, 4])
            drawDashedVLine(context, x: chartX + lunchEndRatio * chartW, chartY: chartY, chartH: chartH, opacity: 0.15, dash: [4, 4])
        }

        // 3. 昨收水平虚线
        let preCloseY = yp(preClose)
        var preCloseLine = Path()
        preCloseLine.move(to: CGPoint(x: chartX, y: preCloseY))
        preCloseLine.addLine(to: CGPoint(x: chartX + chartW, y: preCloseY))
        context.stroke(preCloseLine, with: .color(.gray.opacity(0.4)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

        // 4. 价格区域填充
        let lastPrice = points.last!.price
        let fillColor: Color = Color.trend(lastPrice - preClose).opacity(0.08)
        let lineColor: Color = Color.trend(lastPrice - preClose)

        var fillPath = Path()
        fillPath.move(to: CGPoint(x: xp(0), y: chartY + chartH))
        for (i, p) in points.enumerated() {
            fillPath.addLine(to: CGPoint(x: xp(i), y: yp(p.price)))
        }
        fillPath.addLine(to: CGPoint(x: xp(count - 1), y: chartY + chartH))
        fillPath.closeSubpath()
        context.fill(fillPath, with: .color(fillColor))

        // 5. 价格线
        var pricePath = Path()
        for (i, p) in points.enumerated() {
            let pt = CGPoint(x: xp(i), y: yp(p.price))
            if i == 0 { pricePath.move(to: pt) }
            else { pricePath.addLine(to: pt) }
        }
        context.stroke(pricePath, with: .color(lineColor), style: StrokeStyle(lineWidth: 1))

        // 6. 均价线
        if points.contains(where: { $0.avgPrice > 0 }) {
            var avgPath = Path()
            var started = false
            for (i, p) in points.enumerated() {
                guard p.avgPrice > 0 else { continue }
                let pt = CGPoint(x: xp(i), y: yp(p.avgPrice))
                if !started { avgPath.move(to: pt); started = true }
                else { avgPath.addLine(to: pt) }
            }
            context.stroke(avgPath, with: .color(Color.dmWarn.opacity(0.6)), style: StrokeStyle(lineWidth: 0.8, dash: [2, 2]))
        }

        // 7. 最新价标记点
        if let last = points.last {
            let lx = xp(count - 1)
            let ly = yp(last.price)
            context.fill(
                Path(ellipseIn: CGRect(x: lx - 2.5, y: ly - 2.5, width: 5, height: 5)),
                with: .color(lineColor)
            )
        }

        // 9. 底部刻度尺
        let ticks: [(String, Double)]
        switch mode {
        case .aStock:
            ticks = [
                ("09:30", 0.0), ("10:30", 0.25), ("11:30/13:00", 0.5), ("14:00", 0.75), ("15:00", 1.0)
            ]
        case .shfeGold:
            let breakRatio = 330.0 / Self.shfeGoldTotalMinutes
            let lunchRatio = 480.0 / Self.shfeGoldTotalMinutes
            ticks = [
                ("21:00", 0.0),
                ("02:30/09:00", breakRatio),
                ("11:30/13:30", lunchRatio),
                ("15:00", 1.0)
            ]
        }

        for (label, ratio) in ticks {
            let x = chartX + ratio * chartW
            if ratio > 0 && ratio < 1 {
                drawDashedVLine(context, x: x, chartY: chartY, chartH: chartH, opacity: 0.1, dash: [2, 3])
            }
            var tickLine = Path()
            tickLine.move(to: CGPoint(x: x, y: chartY + chartH))
            tickLine.addLine(to: CGPoint(x: x, y: chartY + chartH + 4))
            context.stroke(tickLine, with: .color(.gray.opacity(0.5)), style: StrokeStyle(lineWidth: 0.5))
            if !label.isEmpty {
                context.draw(
                    Text(label).font(.system(size: 9)).foregroundColor(Color.dmInk2),
                    at: CGPoint(x: x, y: chartY + chartH + 7),
                    anchor: ratio == 0 ? .topLeading : (ratio == 1.0 ? .topTrailing : .top)
                )
            }
        }

        // 底部基线
        var baseLine = Path()
        baseLine.move(to: CGPoint(x: chartX, y: chartY + chartH))
        baseLine.addLine(to: CGPoint(x: chartX + chartW, y: chartY + chartH))
        context.stroke(baseLine, with: .color(.gray.opacity(0.3)), style: StrokeStyle(lineWidth: 0.5))
    }

    // MARK: - Hover 十字线 + 气泡

    private func drawHover(context: GraphicsContext, size: CGSize, mouseX: Double) {
        let points = trend.points
        let preClose = trend.preClose
        let (chartX, chartY, chartW, chartH) = chartGeom(size)
        let (lo, hi) = valueRange
        let valRange = hi - lo

        guard let idx = indexAtX(mouseX, points: points, chartX: chartX, chartW: chartW) else { return }
        let pt = points[idx]
        let px = xPos(idx, points: points, chartX: chartX, chartW: chartW)
        let py = yPos(pt.price, chartY: chartY, chartH: chartH, lo: lo, valRange: valRange)

        // 十字线（竖线 + 横线）
        context.stroke(
            Path { p in
                p.move(to: CGPoint(x: px, y: chartY))
                p.addLine(to: CGPoint(x: px, y: chartY + chartH))
            },
            with: .color(.gray.opacity(0.5)),
            style: StrokeStyle(lineWidth: 0.5, dash: [2, 2])
        )
        context.stroke(
            Path { p in
                p.move(to: CGPoint(x: chartX, y: py))
                p.addLine(to: CGPoint(x: chartX + chartW, y: py))
            },
            with: .color(.gray.opacity(0.5)),
            style: StrokeStyle(lineWidth: 0.5, dash: [2, 2])
        )

        // 交点圆点
        context.fill(
            Path(ellipseIn: CGRect(x: px - 3, y: py - 3, width: 6, height: 6)),
            with: .color(.white)
        )
        context.stroke(
            Path(ellipseIn: CGRect(x: px - 3, y: py - 3, width: 6, height: 6)),
            with: .color(Color.trend(pt.price - preClose)),
            style: StrokeStyle(lineWidth: 1.5)
        )

        // 气泡：时间+价格 → 均价 → 昨收
        let timeStr = displayTime(pt.time)
        let priceStr = String(format: "%.2f", pt.price)
        let preCloseStr = String(format: "昨收 %.2f", preClose)
        let avgStr = pt.avgPrice > 0 ? String(format: "均价 %.2f", pt.avgPrice) : nil

        var lines: [String] = ["\(timeStr)  ¥\(priceStr)"]
        if let avgStr = avgStr { lines.append(avgStr) }
        lines.append(preCloseStr)

        let attrLines = lines.map {
            Text($0).font(.system(size: 10)).foregroundColor(.white)
        }

        // 解析测量气泡尺寸
        let resolvedLines = attrLines.map { context.resolve($0) }
        let lineH: Double = 12
        let bubblePad: Double = 5
        let bubbleH = lineH * Double(resolvedLines.count) + bubblePad * 2
        var bubbleW: Double = 0
        for r in resolvedLines {
            let ts = r.measure(in: CGSize(width: 200, height: 20))
            bubbleW = max(bubbleW, ts.width)
        }
        bubbleW += bubblePad * 2

        // 气泡位置：优先放在十字线右侧，空间不够放左侧
        var bubbleX = px + 6
        if bubbleX + bubbleW > chartX + chartW {
            bubbleX = px - bubbleW - 6
        }
        let bubbleY = max(chartY + 2, py - bubbleH - 4)

        // 气泡背景（圆角）
        context.fill(
            Path(roundedRect: CGRect(x: bubbleX, y: bubbleY, width: bubbleW, height: bubbleH), cornerRadius: 6),
            with: .color(.black.opacity(0.75))
        )

        // 气泡文字
        for (i, r) in resolvedLines.enumerated() {
            let textY = bubbleY + bubblePad + lineH * Double(i) + lineH / 2
            context.draw(r, at: CGPoint(x: bubbleX + bubbleW / 2, y: textY), anchor: .center)
        }
    }

    /// 用于显示的时间字符串（提取 HH:mm）
    private func displayTime(_ raw: String) -> String {
        if let spaceIdx = raw.firstIndex(of: " ") {
            return String(raw[raw.index(after: spaceIdx)...])
        }
        return raw
    }

    // MARK: - 辅助绘图

    private func drawDashedVLine(_ context: GraphicsContext, x: Double, chartY: Double, chartH: Double, opacity: Double, dash: [CGFloat]) {
        var line = Path()
        line.move(to: CGPoint(x: x, y: chartY))
        line.addLine(to: CGPoint(x: x, y: chartY + chartH))
        context.stroke(line, with: .color(.gray.opacity(opacity)), style: StrokeStyle(lineWidth: 0.5, dash: dash))
    }
}
