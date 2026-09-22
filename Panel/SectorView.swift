import SwiftUI
import AppKit

/// CPO 板块页：板块指数 + 前 10 大成交额个股
struct SectorView: View {
    @ObservedObject var controller: MenuBarController

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if controller.configStore.config.sectors.isEmpty {
                    // 未配置任何板块
                    VStack(spacing: 8) {
                        Spacer()
                            .frame(height: 80)
                        AppIcon(name: "sector", size: 22)
                            .foregroundColor(.secondary)
                        Text("暂未添加板块")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Text("在设置页「自选板块」中添加")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                } else if let s = controller.sector {
                    // 板块指数头部卡片
                    MarketCard {
                        PriceHeader(
                            title: "\(s.name) 板块指数",
                            marketStatus: controller.stockMarketStatus,
                            price: Format.price(s.index),
                            changePct: s.changePct,
                            secondary: nil,
                            quoteAt: s.quoteAt
                        )
                    }
                }

                // 分时线图卡片
                if let td = controller.trendData {
                    MarketCard {
                        TrendChart(trend: td)
                    }
                }

                // 成分股列表卡片（系统设置列表风格：无额外内边距，行自带左右 padding）
                if controller.sectorStocks.isEmpty {
                    MarketCard {
                        HStack {
                            Spacer()
                            ProgressView("加载成分股…")
                            Spacer()
                        }
                        .frame(height: 60)
                    }
                } else {
                    VStack(spacing: 0) {
                        stockHeader
                        Divider().opacity(0.5)
                        ForEach(Array(controller.sectorStocks.enumerated()), id: \.element.code) { idx, st in
                            StockRow(rank: idx + 1, stock: st, isZebra: idx % 2 == 0)
                            if idx < controller.sectorStocks.count - 1 {
                                Divider().opacity(0.5)
                            }
                        }
                    }
                    .background(Color.zebraLight)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.cardBorder, lineWidth: 0.5)
                    )
                }
            }
            .padding(.top, controller.configStore.config.sectors.count > 1 ? 0 : 14)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
    }

    private var stockHeader: some View {
        HStack(spacing: 8) {
            Text("#")
                .frame(width: 28, alignment: .leading)
            Text("名称").frame(width: 84, alignment: .leading)
            Spacer()
            Text("现价").frame(width: 62, alignment: .trailing)
            Text("涨跌%").frame(width: 62, alignment: .trailing)
            Text("成交额").frame(width: 64, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.primary.opacity(0.7))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.zebraLight)
    }

}

    /// 个股行（统一字号，保证等高）
    struct StockRow: View {
        let rank: Int
        let stock: StockQuote
        var isZebra: Bool = false

        var body: some View {
            HStack(spacing: 8) {
                Text("\(rank)")
                    .foregroundColor(.secondary)
                    .frame(width: 28, alignment: .leading)
                Text(stock.name)
                    .lineLimit(1)
                    .frame(width: 84, alignment: .leading)
                Spacer()
                Text(Format.price(stock.price))
                    .frame(width: 62, alignment: .trailing)
                Text(Format.pct(stock.changePct))
                    .foregroundColor(Color.trend(stock.changePct))
                    .frame(width: 62, alignment: .trailing)
                Text(Format.amount(stock.amount))
                    .foregroundColor(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(isZebra ? Color.zebraDark : Color.zebraLight)
        }
    }
