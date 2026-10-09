import SwiftUI
import AppKit

/// 基金页：对齐黄金/板块页卡片风格，每只基金一张卡片
/// 卡片内分区：净值信息区 → 重仓列表区（表头 + 行）
struct FundView: View {
    @ObservedObject var controller: MenuBarController

    var body: some View {
        VStack(spacing: 0) {
            if controller.funds.isEmpty {
                // 区分「未配置基金」和「加载中/出错」
                if controller.configStore.config.funds.isEmpty {
                    VStack(spacing: DmSpace.s8) {
                        Spacer()
                        LucideIcon("fund", size: DmIcon.i24)
                            .foregroundColor(Color.dmInk2)
                        Text("暂未添加基金")
                            .font(.system(size: DmText.t13))
                            .foregroundColor(Color.dmInk2)
                        Text("在设置页「自选基金」中添加")
                            .font(.system(size: DmText.t11))
                            .foregroundColor(Color.dmInk3)
                        Spacer()
                    }
                } else {
                    VStack(spacing: DmSpace.s8) {
                        Spacer()
                        if let err = controller.fundErrorMessage {
                            LucideIcon("wifi-error", size: DmIcon.i24)
                                .foregroundColor(Color.dmInk2)
                            Text(err)
                                .font(.system(size: DmText.t12))
                                .foregroundColor(Color.dmInk2)
                        } else {
                            ProgressView("加载基金数据…")
                        }
                        Spacer()
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: DmSpace.s14) {
                        let fundCount = controller.funds.count
                        ForEach(controller.funds, id: \.quote.code) { fund in
                            FundCard(fund: fund, changes: controller.fundStockChanges, marketStatus: controller.stockMarketStatus, defaultExpanded: fundCount == 1)
                        }
                    }
                    .padding(DmSpace.s14)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// 单只基金卡片：一张卡片内完成净值 + 盘中估算 + 重仓列表
/// 重仓列表支持收起/展开，减少多基金时的滚动距离
struct FundCard: View {
    let fund: FundDetail
    let changes: [String: Double]
    let marketStatus: MarketStatus

    @State private var isExpanded = false
    @State private var isHeaderHovered = false

    init(fund: FundDetail, changes: [String: Double], marketStatus: MarketStatus, defaultExpanded: Bool = false) {
        self.fund = fund
        self.changes = changes
        self.marketStatus = marketStatus
        self._isExpanded = State(initialValue: defaultExpanded)
    }

    private var canExpand: Bool { !fund.holdings.isEmpty }

    /// 覆盖度文案：「前 10 大重仓行情覆盖 62%」（覆盖的对象是重仓的实时行情）
    private func coverageLabel(_ cov: Double) -> String {
        let n = fund.holdings.count
        let pct = Int(cov.rounded())
        return n > 0 ? "前 \(n) 大重仓行情覆盖 \(pct)%" : "重仓行情覆盖 \(pct)%"
    }

    /// 覆盖度不足一半：估值数字置灰，让它不再被当成权威读数
    private var isLowCoverage: Bool { (fund.estCoverage ?? 100) < 50 }

    var body: some View {
        VStack(spacing: 0) {
            // ===== 净值信息区（整区可点击切换收起/展开） =====
            VStack(alignment: .leading, spacing: DmSpace.s6) {
                // 标题行：名称 + 代码（左侧）  展开指示箭头（右侧）
                HStack(spacing: DmSpace.s8) {
                    Text(fund.quote.name)
                        .font(.system(size: DmText.t13, weight: .semibold))
                        .lineLimit(1)
                    Text(fund.quote.code)
                        .font(.system(size: DmText.t11))
                        .foregroundColor(Color.dmInk2)
                    Spacer()
                    if canExpand {
                        LucideIcon(isExpanded ? "chevron-down" : "chevron-right", size: DmIcon.i12)
                            .foregroundColor(Color.dmInk2)
                            .frame(width: 20, height: 20)
                    }
                }

                // 净值大数 + 涨跌
                HStack(alignment: .firstTextBaseline, spacing: DmSpace.s8) {
                    Text(Format.navPrice(fund.quote.nav))
                        .font(.system(size: DmText.t28, weight: .bold, design: .rounded))
                        .foregroundColor(Color.trend(fund.quote.navChangePct))
                    Text(Format.pct(fund.quote.navChangePct))
                        .font(.system(size: DmText.t14, weight: .semibold))
                        .foregroundColor(Color.trend(fund.quote.navChangePct))
                    Spacer()
                }
                .padding(.top, DmSpace.s2)

                // 净值日期 + 覆盖度 + 盘中估算
                HStack(spacing: DmSpace.s8) {
                    Text("净值日期 \(DataFreshness.shortDate(fund.quote.navDate))")
                        .font(.system(size: DmText.t10))
                        .foregroundColor(Color.dmInk3)
                    Spacer()
                    if let estNav = fund.estNav {
                        // 覆盖度必须跟估值一起出现：10 只重仓只有 2 只有行情时，
                        // 单独一个估值数字看不出它只代表那 2 只
                        if let cov = fund.estCoverage {
                            Text(coverageLabel(cov))
                                .font(.system(size: DmText.t10))
                                .foregroundColor(isLowCoverage ? Color.dmWarn : Color.dmInk3)
                        }
                        Text(marketStatus == .trading ? "盘中估算" : "今日估算")
                            .font(.system(size: DmText.t10))
                            .foregroundColor(Color.dmInk3)
                        Text(Format.navPrice(estNav))
                            .font(.system(size: DmText.t12, weight: .medium))
                            .foregroundColor(isLowCoverage ? Color.dmInk2 : Color.dmInk)
                    }
                }
            }
            .padding(.horizontal, DmSpace.s14)
            .padding(.vertical, DmSpace.s12)
            .background(
                canExpand
                    ? Color.white.opacity(isHeaderHovered ? 0.06 : 0)
                    : Color.clear
            )
            .contentShape(Rectangle())
            .onTapGesture {
                guard canExpand else { return }
                withAnimation(.easeInOut(duration: DmMotion.base)) { isExpanded.toggle() }
            }
            .onHover { hovering in
                guard canExpand else { return }
                isHeaderHovered = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }

            // ===== 重仓列表区（收起时隐藏） =====
            if isExpanded {
                Divider().opacity(0.5)
                if fund.holdings.isEmpty {
                    Text("暂无重仓数据")
                        .font(.system(size: DmText.t11))
                        .foregroundColor(Color.dmInk2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DmSpace.s12)
                } else {
                    holdingHeader
                    Divider().opacity(0.5)
                    let rows = Array(fund.holdings.prefix(5))
                    ForEach(Array(rows.enumerated()), id: \.element.code) { idx, h in
                        holdingRow(idx: idx, holding: h)
                        if idx < rows.count - 1 {
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
        .background(Color.dmPanel2)
        .cornerRadius(DmRadius.r12)
        .overlay(
            RoundedRectangle(cornerRadius: DmRadius.r12)
                .stroke(Color.dmLine2, lineWidth: DmLine.hairline)
        )
    }

    /// 重仓列表表头
    private var holdingHeader: some View {
        HStack(spacing: DmSpace.s8) {
            Text("#")
                .frame(width: 28, alignment: .leading)
            Text("名称").frame(width: 84, alignment: .leading)
            Spacer()
            Text("占比").frame(width: 48, alignment: .trailing)
            Text("今日涨跌").frame(width: 62, alignment: .trailing)
        }
        .font(.system(size: DmText.t12, weight: .medium))
        .foregroundColor(Color.dmInk.opacity(0.7))
        .padding(.horizontal, DmSpace.s14)
        .padding(.vertical, DmSpace.s8)
        .background(Color.dmPanel3)
    }

    /// 单只重仓行（对齐板块成分股行样式）
    private func holdingRow(idx: Int, holding: FundHolding) -> some View {
        HStack(spacing: DmSpace.s8) {
            Text("\(idx + 1)")
                .foregroundColor(Color.dmInk2)
                .frame(width: 28, alignment: .leading)
            Text(holding.name)
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)
            Spacer()
            Text(String(format: "%.1f%%", holding.weight))
                .foregroundColor(Color.dmInk2)
                .frame(width: 48, alignment: .trailing)
            if let pct = changes[FundEstimator.normalizeCode(holding.code)] {
                Text(Format.pct(pct))
                    .foregroundColor(Color.trend(pct))
                    .frame(width: 62, alignment: .trailing)
            } else {
                Text("--")
                    .foregroundColor(Color.dmInk2)
                    .frame(width: 62, alignment: .trailing)
            }
        }
        .font(.system(size: DmText.t12))
        .padding(.horizontal, DmSpace.s14)
        .padding(.vertical, DmSpace.s8)
    }
}