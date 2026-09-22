import Foundation

/// 冷启动快照：上一轮成功的行情落盘，启动时先铺上再抓取
///
/// 快照一定带**行情自身时间**（quoteAt / quoteDate / navDate），不带抓取时刻 ——
/// 重启后看到一份标着「刚刚」的旧盘面，比看到空白更危险。
/// 分时线与重仓股不入快照：体积大，启动后一轮请求内就能重新拿到。
enum SnapshotStore {
    private static let key = "com.dreamanual.investmonitor.Snapshot.v1"

    /// 超过这个时长的快照不再回填：留着一份两天前的盘面只会误导
    static let maxAge: TimeInterval = 24 * 3600

    struct Snapshot: Codable {
        /// 落盘时刻（只用于判断快照本身是否过期，不用于展示）
        var savedAt: Date
        var gold: Gold?
        var sector: Sector?
        var sectors: [Sector]
        var funds: [Fund]

        struct Gold: Codable {
            var priceCNY, prevCNY, highCNY, lowCNY, changePct: Double
            var time, date, source: String
            var quoteAt: Date?

            init(_ q: GoldQuote) {
                priceCNY = q.priceCNY; prevCNY = q.prevCNY
                highCNY = q.highCNY; lowCNY = q.lowCNY; changePct = q.changePct
                time = q.time; date = q.date; source = q.source; quoteAt = q.quoteAt
            }

            var quote: GoldQuote {
                GoldQuote(priceCNY: priceCNY, prevCNY: prevCNY, highCNY: highCNY,
                          lowCNY: lowCNY, changePct: changePct, time: time, date: date,
                          quoteAt: quoteAt, source: source)
            }
        }

        struct Sector: Codable {
            var code, name: String
            var index, changePct, prevIndex, amount: Double
            var quoteDate, source: String
            var quoteAt: Date?

            init(_ q: SectorQuote) {
                code = q.code; name = q.name; index = q.index; changePct = q.changePct
                prevIndex = q.prevIndex; amount = q.amount
                quoteDate = q.quoteDate; source = q.source; quoteAt = q.quoteAt
            }

            var quote: SectorQuote {
                SectorQuote(code: code, name: name, index: index, changePct: changePct,
                            prevIndex: prevIndex, amount: amount,
                            quoteDate: quoteDate, quoteAt: quoteAt, source: source)
            }
        }

        struct Fund: Codable {
            var code, name, navDate, source: String
            var nav, navChangePct: Double
            var estNav, estChangePct, estCoverage: Double?

            init(_ d: FundDetail) {
                code = d.quote.code; name = d.quote.name; nav = d.quote.nav
                navChangePct = d.quote.navChangePct; navDate = d.quote.navDate
                source = d.quote.source
                estNav = d.estNav; estChangePct = d.estChangePct; estCoverage = d.estCoverage
            }

            /// 重仓列表留空：展开时会等到当轮刷新完成，好过显示昨天的重仓
            var detail: FundDetail {
                FundDetail(
                    quote: FundQuote(code: code, name: name, nav: nav,
                                     navChangePct: navChangePct, navDate: navDate, source: source),
                    holdings: [],
                    estNav: estNav, estChangePct: estChangePct, estCoverage: estCoverage
                )
            }
        }
    }

    /// defaults 可注入：自检用独立 suite，避免覆盖用户真实的快照
    static func save(gold: GoldQuote?, sector: SectorQuote?, sectors: [SectorQuote],
                     funds: [FundDetail], defaults: UserDefaults = .standard) {
        let snap = Snapshot(
            savedAt: Date(),
            gold: gold.map(Snapshot.Gold.init),
            sector: sector.map(Snapshot.Sector.init),
            sectors: sectors.map(Snapshot.Sector.init),
            funds: funds.map(Snapshot.Fund.init)
        )
        guard let data = try? JSONEncoder().encode(snap) else { return }
        defaults.set(data, forKey: key)
    }

    static func load(defaults: UserDefaults = .standard) -> Snapshot? {
        guard let data = defaults.data(forKey: key),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        guard Date().timeIntervalSince(snap.savedAt) < maxAge else { return nil }
        return snap
    }
}
