import Foundation
import SwiftUI

// ============ 全局颜色系统 ============

extension Color {
    /// 涨跌色来自设计令牌（`--up` / `--down`，四个 app 里只有本 app 用）。
    ///
    /// 跌色落在 green-600 而不是 emerald-500 —— 两者色相差 18°，肉眼可辨。
    /// 官网 tokens.css 的 `--dt-success` 就是 #16a34a，站上看到的绿和 App 里看到的绿
    /// 要始终是同一个，这条优先于色族统一。取舍理由见 design/tokens.json 的 apps.invest。
    static let up = Color.dmUp       // red-500 #ef4444
    static let down = Color.dmDown   // green-600 #16a34a
    static let flat = Color.dmInk2   // 平

    /// 涨跌颜色：>0 红、<0 绿、==0 灰
    static func trend(_ v: Double) -> Color {
        v > 0 ? .up : (v < 0 ? .down : .flat)
    }
}

// ============ 数据模型 ============

/// 黄金行情（沪金主连，直接 CNY/g）
struct GoldQuote {
    var priceCNY: Double         // 现价 人民币/克
    var prevCNY: Double          // 昨收 人民币/克
    var highCNY: Double          // 今日最高
    var lowCNY: Double           // 今日最低
    var changePct: Double        // 涨跌幅 %
    var time: String             // 行情自身时间 HH:mm:ss（来自 f124）
    var date: String             // 行情自身日期 YYYY-MM-DD（来自 f124）
    /// 行情自身更新时刻。判定价日期与「数据时效」都用它 —— 抓取时刻不会记在这里
    var quoteAt: Date? = nil
    /// 命中的数据源名（降级链），用于错误提示与来源可见性
    var source: String = ""
}

// ============ 错误 ============
enum FetchError: Error, LocalizedError {
    case badResponse
    case invalidData(String)
    case timeout
    case noConnection
    /// 降级链全部失败。带上每一级的名字 —— 「东财延时域名 / 东财主域名 / 东财单只接口」
    /// 比「更新失败」有用得多：用户能看出是整条链塌了还是只有某一级
    case allSourcesFailed([String])

    var errorDescription: String? {
        switch self {
        case .badResponse: return "服务器响应异常"
        case .invalidData(let s): return s.isEmpty ? "数据格式异常" : "数据格式异常（\(s)）"
        case .timeout: return "网络连接超时"
        case .noConnection: return "无法连接服务器"
        case .allSourcesFailed(let names):
            return "全部数据源失败（\(names.joined(separator: " / "))）"
        }
    }
}

/// 新浪行情是 GBK/GB18030 编码。Foundation 没有直接暴露这个常量，
/// 走 CoreFoundation 的编码标识换算一次（比写死 0x80000632 可读）
extension String.Encoding {
    static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )
}

// ============ 网络请求基座 ============

/// 共享 HTTP 客户端：统一 UA/Referer/超时 + JSON 解析 + 友好错误分类
enum NetworkClient {
    static let defaultUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/126.0"
    static let defaultReferer = "https://quote.eastmoney.com/"
    /// 新浪行情接口对 Referer 是硬要求：不带直接回 `Forbidden`（实测）
    static let sinaReferer = "https://finance.sina.com.cn"

    // ===== 行情域名降级 =====

    /// 行情域名候选表（host → 同义备用 host，按尝试顺序）。
    ///
    /// 为什么放在这一层：东财的行情网关是一组**同口径、同接口**的域名，但对
    /// 同一个网络的可用性并不一致 —— 2026-09-22 实测，本机访问 `push2delay` /
    /// `push2` / `push2his` 全部拿到空响应（TLS 握手完成后服务端直接断开，
    /// curl 报 `Empty reply from server`，`remote_ip` 与证书都正常），
    /// 而 `push2delay2` 同口径全量可用（f18 昨收逐值一致）。
    /// 域名级切换集中在这里：所有调用点不必各写一遍，将来新增接口自动受益，
    /// 且原域名仍排在最前 —— 对本来正常的网络行为零改变。
    private static let hostFallbacks: [String: [String]] = [
        "push2delay.eastmoney.com": ["push2delay2.eastmoney.com", "push2.eastmoney.com"],
        "push2.eastmoney.com": ["push2delay2.eastmoney.com", "push2delay.eastmoney.com"],
        "push2his.eastmoney.com": ["push2delay2.eastmoney.com"],
    ]

    /// 原 URL 及其同义域名的 URL，原 host 优先。
    /// 不在候选表里的域名原样返回 —— 新浪/基金等域名零额外开销。
    private static func candidateURLs(_ url: URL) -> [URL] {
        guard let host = url.host, let alts = hostFallbacks[host] else { return [url] }
        var out = [url]
        for alt in alts {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.host = alt
            if let u = comps?.url { out.append(u) }
        }
        return out
    }

    /// 只对「连接类」失败换域名：数据格式或业务错误换个域名结果一样，重试纯属浪费
    private static func isRetryable(_ error: Error) -> Bool {
        guard let e = error as? FetchError else { return false }
        switch e {
        case .badResponse, .timeout, .noConnection: return true
        case .invalidData, .allSourcesFailed: return false
        }
    }

    static func getJSON(
        url: URL,
        ua: String = defaultUA,
        referer: String = defaultReferer
    ) async throws -> [String: Any] {
        var lastError: Error = FetchError.badResponse
        for candidate in candidateURLs(url) {
            do {
                return try await getJSONOnce(url: candidate, ua: ua, referer: referer)
            } catch {
                guard isRetryable(error) else { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    private static func getJSONOnce(
        url: URL,
        ua: String,
        referer: String
    ) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.timeoutInterval = 10
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw FetchError.badResponse
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw FetchError.invalidData("JSON 解析失败")
            }
            return obj
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw FetchError.timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
                throw FetchError.noConnection
            default:
                throw FetchError.badResponse
            }
        }
    }

    /// 取纯文本（新浪 `hq.sinajs.cn` 是 GBK 编码的 JS 片段，不是 JSON）
    ///
    /// 先按 GBK 解，解不出再用 UTF-8 —— 新浪偶有接口混用编码，
    /// 顺序反过来会把中文基金名解成乱码而不报错，那比解码失败更难发现。
    static func getText(
        url: URL,
        ua: String = defaultUA,
        referer: String = sinaReferer
    ) async throws -> String {
        var lastError: Error = FetchError.badResponse
        for candidate in candidateURLs(url) {
            do {
                return try await getTextOnce(url: candidate, ua: ua, referer: referer)
            } catch {
                guard isRetryable(error) else { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    private static func getTextOnce(
        url: URL,
        ua: String,
        referer: String
    ) async throws -> String {
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.timeoutInterval = 10
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw FetchError.badResponse
            }
            if let s = String(data: data, encoding: .gb18030) { return s }
            if let s = String(data: data, encoding: .utf8) { return s }
            throw FetchError.invalidData("文本解码失败")
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw FetchError.timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost:
                throw FetchError.noConnection
            default:
                throw FetchError.badResponse
            }
        }
    }
}

// ============ 行情时间与 JSON 取值 ============

/// 行情时间工具：unix 秒 → 上海时区
///
/// ⚠️ 时区要在这个口径上取，而不是把时间戳当 UTC 直接读日期 ——
/// 晚 20:00 之后整体差一天，夜盘尤其明显（f124 换算过去已是次日 UTC 16:00）。
enum MarketClock {
    static let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    private static func date(_ unixSec: Double?) -> Date? {
        guard let sec = unixSec, sec > 0, sec.isFinite else { return nil }
        return Date(timeIntervalSince1970: sec)
    }

    /// unix 秒 → Date（无效值返回 nil）
    static func fromUnix(_ unixSec: Double?) -> Date? { date(unixSec) }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = shanghai
        return f
    }

    /// unix 秒 → "YYYY-MM-DD"（上海时区）
    static func dateString(_ unixSec: Double?) -> String? {
        guard let d = date(unixSec) else { return nil }
        return formatter("yyyy-MM-dd").string(from: d)
    }

    /// unix 秒 → "HH:mm:ss"（上海时区）
    static func timeString(_ unixSec: Double?) -> String? {
        guard let d = date(unixSec) else { return nil }
        return formatter("HH:mm:ss").string(from: d)
    }

    /// 今天的日期字符串（判定价闸门与净值比较共用）
    static func today(_ now: Date = Date()) -> String {
        formatter("yyyy-MM-dd").string(from: now)
    }
}

/// JSON 取值：东财同一个字段在不同接口会换类型（数字 / 字符串 / "-"）
enum JSONValue {
    static func double(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String, s != "-", s != "" { return Double(s) }
        return nil
    }

    static func string(_ v: Any?) -> String? { v as? String }
}

// ============ 黄金聚合服务（东财沪金主连 113.aum，直接 CNY/g） ============

/// 沪金主连三级降级链：`push2delay` ulist → `push2` ulist → `push2` stock/get
///
/// 三级全在东财内的理由：新浪 `hq.sinajs.cn/list=nf_AU0`（黄金连续）实测最新价 935.78、
/// 昨结 940.28，而东财 113.aum 是 933.02 / 940.18 —— 不是同一合约口径（一个是黄金连续，
/// 一个是主力拼接）。绝对价格阈值（「跌破 935」这类）在两源之间切换会凭空触发一次，
/// 宁可不降级也不用异源。三级覆盖的是「单域名故障」与「单接口形态下线」。
actor GoldService {
    private let delayBase = "https://push2delay.eastmoney.com"
    private let pushBase = "https://push2.eastmoney.com"

    /// ulist 字段：f2 现价 / f3 涨跌幅 / f15 最高 / f16 最低 / f18 昨收 / f124 行情时间
    private static let ulistFields = "f2,f3,f12,f14,f15,f16,f18,f124"

    func fetch() async throws -> GoldQuote {
        try await QuoteChain.run([
            QuoteSource("东财延时") { try await self.fetchUlist(base: self.delayBase, source: "东财延时") },
            QuoteSource("东财主站") { try await self.fetchUlist(base: self.pushBase, source: "东财主站") },
            QuoteSource("东财单只") { try await self.fetchSingle() },
        ]).value
    }

    /// 接口形态一：批量列表（ulist.np）
    private func fetchUlist(base: String, source: String) async throws -> GoldQuote {
        let url = URL(string: "\(base)/api/qt/ulist.np/get?fltt=2&secids=113.aum&fields=\(Self.ulistFields)")!
        let json = try await NetworkClient.getJSON(url: url)
        guard let data = json["data"] as? [String: Any],
              let diff = data["diff"] as? [[String: Any]],
              let first = diff.first else {
            throw FetchError.invalidData("沪金解析失败")
        }
        // f2 缺失或为 0 都算「没拿到」。东财在非推送时段会回 f2: 0.0，
        // 把它当合法价会让「跌破 900」这类低线被 0 假触发 —— 比不触发更糟
        guard let price = JSONValue.double(first["f2"]), price != 0 else {
            throw FetchError.invalidData("沪金当前无行情")
        }
        let quoteTime = JSONValue.double(first["f124"])
        return GoldQuote(
            priceCNY: price,
            prevCNY: JSONValue.double(first["f18"]) ?? 0,
            highCNY: JSONValue.double(first["f15"]) ?? 0,
            lowCNY: JSONValue.double(first["f16"]) ?? 0,
            changePct: JSONValue.double(first["f3"]) ?? 0,
            time: MarketClock.timeString(quoteTime) ?? "",
            date: MarketClock.dateString(quoteTime) ?? "",
            quoteAt: MarketClock.fromUnix(quoteTime),
            source: source
        )
    }

    /// 接口形态二：单只查询（stock/get）
    ///
    /// 字段与 ulist 不同名：f43 现价 / f44 最高 / f45 最低 / f60 昨收 / f86 行情时间 /
    /// f170 涨跌幅。带 `fltt=2` 后直接返回小数，不必自己按 f59 缩放（实测两形态逐值一致）。
    private func fetchSingle() async throws -> GoldQuote {
        let url = URL(string: "\(pushBase)/api/qt/stock/get?fltt=2&secid=113.aum&fields=f43,f44,f45,f58,f60,f86,f170")!
        let json = try await NetworkClient.getJSON(url: url)
        guard let data = json["data"] as? [String: Any] else {
            throw FetchError.invalidData("沪金单只解析失败")
        }
        guard let price = JSONValue.double(data["f43"]), price != 0 else {
            throw FetchError.invalidData("沪金当前无行情")
        }
        let quoteTime = JSONValue.double(data["f86"])
        return GoldQuote(
            priceCNY: price,
            prevCNY: JSONValue.double(data["f60"]) ?? 0,
            highCNY: JSONValue.double(data["f44"]) ?? 0,
            lowCNY: JSONValue.double(data["f45"]) ?? 0,
            changePct: JSONValue.double(data["f170"]) ?? 0,
            time: MarketClock.timeString(quoteTime) ?? "",
            date: MarketClock.dateString(quoteTime) ?? "",
            quoteAt: MarketClock.fromUnix(quoteTime),
            source: "东财单只"
        )
    }
}

// ============ 东财板块/个股 模型 ============

/// 板块指数行情（东财 push2delay）
struct SectorQuote {
    var code: String        // 板块代码
    var name: String        // 板块名称
    var index: Double       // 板块指数点位
    var changePct: Double   // 涨跌幅 %
    var prevIndex: Double   // 昨收
    var amount: Double      // 成交额（元）
    /// 行情**自身**日期 YYYY-MM-DD（来自 f124）。判定价的日期来源；空串表示没拿到
    var quoteDate: String = ""
    /// 行情自身更新时刻（同一 f124 的 Date 形态）。「数据时效」用它
    var quoteAt: Date? = nil
    /// 命中的数据源名（降级链）
    var source: String = ""
}

/// 板块成分股（按成交额）
struct StockQuote {
    var code: String
    var name: String
    var price: Double       // 现价
    var changePct: Double   // 涨跌幅 %
    var amount: Double      // 成交额（元）
}

// ============ 分时线模型 ============

/// 分时线数据点
struct TrendPoint {
    var time: String      // HH:mm
    var price: Double     // 价格（收盘价）
    var avgPrice: Double  // 均价
    var volume: Double    // 成交量
    var amount: Double    // 成交额
}

/// 分时线完整数据
struct TrendData {
    var name: String
    var preClose: Double  // 昨收
    var points: [TrendPoint]
}

// ============ 东财接口解析 ============
enum EastMoneyParser {
    /// 解析板块指数 JSON：ulist.np/get
    static func parseSector(_ json: [String: Any], source: String = "") -> SectorQuote? {
        guard let data = json["data"] as? [String: Any],
              let diff = data["diff"] as? [[String: Any]],
              let first = diff.first else { return nil }
        let quoteTime = JSONValue.double(first["f124"])
        return SectorQuote(
            code: (first["f12"] as? String) ?? "",
            name: (first["f14"] as? String) ?? "",
            index: JSONValue.double(first["f2"]) ?? 0,
            changePct: JSONValue.double(first["f3"]) ?? 0,
            prevIndex: JSONValue.double(first["f18"]) ?? 0,
            amount: JSONValue.double(first["f6"]) ?? 0,
            quoteDate: MarketClock.dateString(quoteTime) ?? "",
            quoteAt: MarketClock.fromUnix(quoteTime),
            source: source
        )
    }

    /// 解析板块指数 JSON：stock/get（单只形态，字段名与 ulist 不同）
    static func parseSectorSingle(_ json: [String: Any], code: String, name: String, source: String) -> SectorQuote? {
        guard let data = json["data"] as? [String: Any],
              let index = JSONValue.double(data["f43"]), index != 0 else { return nil }
        let quoteTime = JSONValue.double(data["f86"])
        return SectorQuote(
            code: code,
            name: (data["f58"] as? String) ?? name,
            index: index,
            changePct: JSONValue.double(data["f170"]) ?? 0,
            prevIndex: JSONValue.double(data["f60"]) ?? 0,
            amount: 0,
            quoteDate: MarketClock.dateString(quoteTime) ?? "",
            quoteAt: MarketClock.fromUnix(quoteTime),
            source: source
        )
    }

    /// 解析成分股列表 JSON：clist/get
    static func parseStocks(_ json: [String: Any]) -> [StockQuote] {
        guard let data = json["data"] as? [String: Any],
              let diff = data["diff"] as? [[String: Any]] else { return [] }
        return diff.map {
            StockQuote(
                code: ($0["f12"] as? String) ?? "",
                name: ($0["f14"] as? String) ?? "",
                price: ($0["f2"] as? Double) ?? 0,
                changePct: ($0["f3"] as? Double) ?? 0,
                amount: ($0["f6"] as? Double) ?? 0
            )
        }
    }
}

// ============ 东财板块聚合服务 ============
actor SectorService {
    private let delayBase = "https://push2delay.eastmoney.com/api/qt"
    private let pushBase = "https://push2.eastmoney.com/api/qt"
    private let hisBase = "https://push2his.eastmoney.com/api/qt"

    /// 板块指数（三级：延时网关 → 主站网关 → 主站单只接口）
    func fetchIndex(code: String = "BK0475", name: String = "半导体") async throws -> SectorQuote {
        try await QuoteChain.run([
            QuoteSource("东财延时") {
                try await self.fetchSectorList(base: self.delayBase, secids: "90.\(code)", source: "东财延时")
            },
            QuoteSource("东财主站") {
                try await self.fetchSectorList(base: self.pushBase, secids: "90.\(code)", source: "东财主站")
            },
            QuoteSource("东财单只") {
                let url = URL(string: "\(self.pushBase)/stock/get?fltt=2&secid=90.\(code)&fields=f43,f58,f60,f86,f170")!
                let json = try await NetworkClient.getJSON(url: url)
                guard let s = EastMoneyParser.parseSectorSingle(json, code: code, name: name, source: "东财单只") else {
                    throw FetchError.invalidData("板块单只解析失败")
                }
                return s
            },
        ]).value
    }

    /// 板块指数：ulist 形态
    private func fetchSectorList(base: String, secids: String, source: String) async throws -> SectorQuote {
        let url = URL(string: "\(base)/ulist.np/get?fltt=2&secids=\(secids)&fields=f2,f3,f12,f14,f18,f6,f124")!
        let json = try await NetworkClient.getJSON(url: url)
        guard let s = EastMoneyParser.parseSector(json, source: source) else {
            throw FetchError.invalidData("板块解析失败")
        }
        return s
    }

    /// 批量拉取多个板块指数（secids 逗号连接，一次请求；两级）
    func fetchIndices(codes: [String], names: [String]) async throws -> [SectorQuote] {
        guard !codes.isEmpty else { return [] }
        let secids = codes.map { "90.\($0)" }.joined(separator: ",")
        return try await QuoteChain.run([
            QuoteSource("东财延时") {
                try await self.fetchSectorBatch(base: self.delayBase, secids: secids, codes: codes, names: names, source: "东财延时")
            },
            QuoteSource("东财主站") {
                try await self.fetchSectorBatch(base: self.pushBase, secids: secids, codes: codes, names: names, source: "东财主站")
            },
        ]).value
    }

    /// 批量板块：ulist 形态
    private func fetchSectorBatch(base: String, secids: String, codes: [String], names: [String], source: String) async throws -> [SectorQuote] {
        let url = URL(string: "\(base)/ulist.np/get?fltt=2&secids=\(secids)&fields=f2,f3,f12,f14,f18,f6,f124")!
        let json = try await NetworkClient.getJSON(url: url)
        guard let data = json["data"] as? [String: Any],
              let diff = data["diff"] as? [[String: Any]] else { return [] }
        var result: [SectorQuote] = []
        for item in diff {
            let code = (item["f12"] as? String) ?? ""
            let idx = codes.firstIndex(of: code) ?? 0
            let name = idx < names.count ? names[idx] : ((item["f14"] as? String) ?? "")
            let quoteTime = JSONValue.double(item["f124"])
            result.append(SectorQuote(
                code: code,
                name: name,
                index: JSONValue.double(item["f2"]) ?? 0,
                changePct: JSONValue.double(item["f3"]) ?? 0,
                prevIndex: JSONValue.double(item["f18"]) ?? 0,
                amount: JSONValue.double(item["f6"]) ?? 0,
                quoteDate: MarketClock.dateString(quoteTime) ?? "",
                quoteAt: MarketClock.fromUnix(quoteTime),
                source: source
            ))
        }
        return result
    }

    /// 板块成分股（按成交额排序前 topN；两级）
    func fetchStocks(code: String = "BK0475", topN: Int = 10) async throws -> [StockQuote] {
        try await QuoteChain.run([
            QuoteSource("东财延时") { try await self.fetchStockList(base: self.delayBase, code: code, topN: topN) },
            QuoteSource("东财主站") { try await self.fetchStockList(base: self.pushBase, code: code, topN: topN) },
        ]).value
    }

    private func fetchStockList(base: String, code: String, topN: Int) async throws -> [StockQuote] {
        let url = URL(string: "\(base)/clist/get?pn=1&pz=\(topN)&po=1&np=1&fltt=2&invt=2&fid=f6&fs=b:\(code)&fields=f2,f3,f6,f12,f14")!
        let json = try await NetworkClient.getJSON(url: url)
        let list = EastMoneyParser.parseStocks(json)
        // 「解析为空」与「抓到空列表」要分开：前者该降级，后者会被误读成
        // 「这个板块没有成分股」，界面上永远停在「加载成分股…」
        guard !list.isEmpty else { throw FetchError.invalidData("成分股解析为空") }
        return list
    }

    /// 批量拉取个股实时涨跌幅（用于基金重仓估值；两级）
    /// - Parameter codes: [代码, 交易所] 元组数组；交易所 1=沪 2=深 5=港
    /// - Returns: 代码 → 涨跌幅%
    func fetchStockChanges(codes: [(code: String, exchange: Int)]) async throws -> [String: Double] {
        guard !codes.isEmpty else { return [:] }
        let secids = codes.map { secid(code: $0.code, exchange: $0.exchange) }.joined(separator: ",")
        return try await QuoteChain.run([
            QuoteSource("东财延时") { try await self.fetchChanges(base: self.delayBase, secids: secids) },
            QuoteSource("东财主站") { try await self.fetchChanges(base: self.pushBase, secids: secids) },
        ]).value
    }

    private func fetchChanges(base: String, secids: String) async throws -> [String: Double] {
        let url = URL(string: "\(base)/ulist.np/get?fltt=2&secids=\(secids)&fields=f3,f12")!
        let json = try await NetworkClient.getJSON(url: url)
        guard let data = json["data"] as? [String: Any],
              let diff = data["diff"] as? [[String: Any]] else {
            throw FetchError.invalidData("个股行情解析失败")
        }
        var map: [String: Double] = [:]
        for item in diff {
            if let code = item["f12"] as? String,
               let pct = JSONValue.double(item["f3"]) {
                map[code] = pct
            }
        }
        return map
    }

    /// 拉取板块分时线数据（当日全天，每分钟一笔；两级）
    func fetchTrends(code: String, name: String) async throws -> TrendData {
        try await QuoteChain.run([
            QuoteSource("东财延时") { try await self.fetchTrendsRaw(base: self.delayBase, secid: "90.\(code)", name: name) },
            QuoteSource("东财历史站") { try await self.fetchTrendsRaw(base: self.hisBase, secid: "90.\(code)", name: name) },
        ]).value
    }

    private func fetchTrendsRaw(base: String, secid: String, name: String) async throws -> TrendData {
        let url = URL(string: "\(base)/stock/trends2/get?secid=\(secid)&fields1=f1,f2,f3,f4,f5,f6,f7,f8,f9,f10,f11,f12,f13&fields2=f51,f52,f53,f54,f55,f56,f57,f58&iscr=0&ndays=1")!
        let json = try await NetworkClient.getJSON(url: url)
        guard let data = json["data"] as? [String: Any],
              let preClose = (data["preClose"] as? Double) ?? (data["preClose"] as? NSNumber)?.doubleValue,
              let trends = data["trends"] as? [String] else {
            throw FetchError.invalidData("分时线解析失败")
        }
        var points: [TrendPoint] = []
        for line in trends {
            let parts = line.split(separator: ",").map(String.init)
            guard parts.count >= 8,
                  let close = Double(parts[2]),
                  let avg = Double(parts[7]),
                  let vol = Double(parts[5]),
                  let amt = Double(parts[6]) else { continue }
            // 保留完整 "YYYY-MM-DD HH:mm" 用于截止时间提示
            let timeStr = parts[0]
            points.append(TrendPoint(time: timeStr, price: close, avgPrice: avg, volume: vol, amount: amt))
        }
        return TrendData(name: name, preClose: preClose, points: points)
    }

    /// 拉取黄金分时线数据（沪金主连 113.aum，CNY/g）
    /// ndays=1 在周末/非交易日只返回最近夜盘段，缺少日盘数据，因此用 ndays=2 取更多数据，
    /// 再按交易日分组筛选出最近一个有日盘数据的完整交易日。
    func fetchGoldTrends() async throws -> TrendData {
        try await QuoteChain.run([
            QuoteSource("东财延时") { try await self.fetchGoldTrendsRaw(base: self.delayBase) },
            QuoteSource("东财历史站") { try await self.fetchGoldTrendsRaw(base: self.hisBase) },
        ]).value
    }

    private func fetchGoldTrendsRaw(base: String) async throws -> TrendData {
        let url = URL(string: "\(base)/stock/trends2/get?secid=113.aum&fields1=f1,f2,f3,f4,f5,f6,f7,f8,f9,f10,f11,f12,f13&fields2=f51,f52,f53,f54,f55,f56,f57,f58&iscr=0&ndays=2")!
        let json = try await NetworkClient.getJSON(url: url)
        guard let data = json["data"] as? [String: Any],
              let preClose = (data["preClose"] as? Double) ?? (data["preClose"] as? NSNumber)?.doubleValue,
              let trends = data["trends"] as? [String] else {
            throw FetchError.invalidData("黄金分时线解析失败")
        }

        // 解析原始数据点，保留完整 "YYYY-MM-DD HH:mm" 用于跨日夜盘映射
        struct RawPoint { let dt: String; let close: Double; let avg: Double; let vol: Double; let amt: Double }
        var raw: [RawPoint] = []
        for line in trends {
            let parts = line.split(separator: ",").map(String.init)
            guard parts.count >= 8,
                  let close = Double(parts[2]),
                  let avg = Double(parts[7]),
                  let vol = Double(parts[5]),
                  let amt = Double(parts[6]) else { continue }
            raw.append(RawPoint(dt: parts[0], close: close, avg: avg, vol: vol, amt: amt))
        }

        // 按交易日分组：夜盘 21:00-23:59 归次日，00:00-02:30 和日盘 09:00-15:00 归当日
        let dfmt = DateFormatter()
        dfmt.dateFormat = "yyyy-MM-dd"
        dfmt.timeZone = TimeZone(identifier: "Asia/Shanghai")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        var groups: [String: [RawPoint]] = [:]
        for pt in raw {
            let segs = pt.dt.split(separator: " ")
            let dateStr = String(segs[0])
            let timeStr = segs.count > 1 ? String(segs[1]) : ""
            let hour = Int(timeStr.split(separator: ":").first ?? "0") ?? 0

            let tradingDay: String
            if hour >= 21, let d = dfmt.date(from: dateStr), let next = cal.date(byAdding: .day, value: 1, to: d) {
                tradingDay = dfmt.string(from: next)
            } else {
                tradingDay = dateStr
            }
            groups[tradingDay, default: []].append(pt)
        }

        // 优先选择最近一个有日盘数据（09:00-15:00）的交易日；否则回退到最近交易日
        let sortedDays = groups.keys.sorted(by: >)
        var selected: String?
        for day in sortedDays {
            let hasDay = (groups[day] ?? []).contains { pt in
                let segs = pt.dt.split(separator: " ")
                guard segs.count > 1 else { return false }
                let h = Int(segs[1].split(separator: ":").first ?? "0") ?? 0
                return h >= 9 && h < 15
            }
            if hasDay { selected = day; break }
        }
        if selected == nil { selected = sortedDays.first }

        let picked = selected.flatMap { groups[$0] } ?? raw
        let sortedPts = picked.sorted { $0.dt < $1.dt }
        var points: [TrendPoint] = []
        for pt in sortedPts {
            points.append(TrendPoint(time: pt.dt, price: pt.close, avgPrice: pt.avg, volume: pt.vol, amount: pt.amt))
        }
        return TrendData(name: "沪金主连", preClose: preClose, points: points)
    }

    /// 东财 secid 前缀：1=沪 0=深 116=港
    private func secid(code: String, exchange: Int) -> String {
        switch exchange {
        case 1: return "1.\(code)"
        case 5: return "116.\(code)"
        default: return "0.\(code)"
        }
    }
}

// ============ 基金 模型 ============

/// 基金净值（东财 FundMNFInfo）
struct FundQuote {
    var code: String        // 基金代码
    var name: String        // 基金名称
    var nav: Double         // 最新净值
    var navChangePct: Double // 净值日涨跌 %
    var navDate: String     // 净值日期 YYYY-MM-DD
    /// 命中的数据源名（降级链）
    var source: String = ""
}

/// 基金重仓股（FundMNInverstPosition）
struct FundHolding {
    var code: String        // 股票代码
    var name: String        // 股票名称
    var weight: Double      // 占净值比 %
    var exchange: Int       // 交易所: 1=沪 2=深 5=港
}

/// 基金完整数据（净值 + 重仓 + 估算）
struct FundDetail {
    var quote: FundQuote
    var holdings: [FundHolding]
    var estNav: Double?      // 盘中估算净值（重仓驱动）
    var estChangePct: Double? // 盘中估算涨跌 %
    /// 估算覆盖度：参与估算的重仓权重合计 %。10 只重仓只有 2 只有行情时，
    /// 单看估值数字看不出它只代表那 2 只 —— 必须带出来
    var estCoverage: Double? = nil
}

// ============ 基金接口解析 ============
enum FundParser {
    /// 解析 FundMNFInfo 净值 JSON
    static func parseQuotes(_ json: [String: Any]) -> [FundQuote] {
        guard let datas = json["Datas"] as? [[String: Any]] else { return [] }
        return datas.compactMap { d in
            guard let code = d["FCODE"] as? String,
                  let name = d["SHORTNAME"] as? String,
                  let navStr = d["NAV"] as? String,
                  let nav = Double(navStr) else { return nil }
            return FundQuote(
                code: code,
                name: name,
                nav: nav,
                navChangePct: (d["NAVCHGRT"] as? String).flatMap(Double.init) ?? 0,
                navDate: (d["PDATE"] as? String) ?? ""
            )
        }
    }

    /// 解析 FundMNInverstPosition 重仓
    static func parseHoldings(_ json: [String: Any]) -> [FundHolding] {
        guard let datas = json["Datas"] as? [String: Any],
              let stocks = datas["fundStocks"] as? [[String: Any]] else { return [] }
        return stocks.compactMap { s in
            guard let code = s["GPDM"] as? String,
                  let name = s["GPJC"] as? String,
                  let wStr = s["JZBL"] as? String,
                  let weight = Double(wStr) else { return nil }
            return FundHolding(
                code: code,
                name: name,
                weight: weight,
                exchange: (s["TEXCH"] as? NSString)?.integerValue ?? 0
            )
        }
    }
}

// ============ 新浪行情解析（hq.sinajs.cn，GBK） ============

/// 新浪行情文本解析
///
/// 基金格式：`var hq_str_f_161725="名称,净值,累计净值,前一日净值,日期,金额";`
/// 涨跌幅新浪不直接给，用它给的前一日净值算 —— 实测与东财 NAVCHGRT 一致
/// （161725：0.5323 对 0.5283 → 0.757%，东财给 0.76）。
///
/// 这是**真异源**（不同厂商、不同接口体系），与东财基金 API 互补：
/// 同厂商的两个域名会一起收紧，跨厂商不会。
enum SinaParser {
    static func parseFunds(_ text: String, source: String = "") -> [FundQuote] {
        var out: [FundQuote] = []
        for line in text.split(separator: "\n") {
            let s = String(line)
            guard s.hasPrefix("var hq_str_f_"),
                  let eq = s.firstIndex(of: "="),
                  let q1 = s.firstIndex(of: "\""),
                  let q2 = s.lastIndex(of: "\""), q1 < q2 else { continue }
            let key = String(s[s.startIndex..<eq])
            guard let code = key.split(separator: "_").last else { continue }
            let body = String(s[s.index(after: q1)..<q2])
            let parts = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5,
                  let nav = Double(parts[1]), nav > 0 else { continue }
            let prev = Double(parts[3])
            let pct = (prev.map { $0 > 0 } == true) ? (nav - prev!) / prev! * 100 : 0
            out.append(FundQuote(
                code: String(code),
                name: parts[0],
                nav: nav,
                navChangePct: pct,
                navDate: parts[4],
                source: source
            ))
        }
        return out
    }
}

// ============ 基金聚合服务 ============
actor FundService {
    private let base = "https://fundmobapi.eastmoney.com/FundMNewApi"
    private let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)"
    private let referer = "https://mpservice.eastmoney.com/"
    private let commonParams = "deviceid=Wap&plat=Wap&product=EFund&version=6.2.8"

    /// 批量拉取基金净值（两级**真异源**：东财基金 API → 新浪 f_ 接口）
    ///
    /// 基金这条链是三类行情里唯一跨厂商的：东财和新浪不是同一套接口体系，
    /// 不会一起收紧。重仓股只有东财有（新浪无该接口），因此不设降级。
    func fetchQuotes(codes: [String]) async throws -> [FundQuote] {
        guard !codes.isEmpty else { return [] }
        return try await QuoteChain.run([
            QuoteSource("东财基金") { try await self.fetchFromEastMoney(codes: codes) },
            QuoteSource("新浪基金") { try await self.fetchFromSina(codes: codes) },
        ]).value
    }

    private func fetchFromEastMoney(codes: [String]) async throws -> [FundQuote] {
        let url = URL(string: "\(base)/FundMNFInfo?Fcodes=\(codes.joined(separator: ","))&\(commonParams)")!
        let json = try await NetworkClient.getJSON(url: url, ua: ua, referer: referer)
        let list = FundParser.parseQuotes(json)
        guard !list.isEmpty else { throw FetchError.invalidData("基金净值解析为空") }
        return list.map { q in
            var m = q
            m.source = "东财基金"
            return m
        }
    }

    /// 新浪 f_ 接口：一次请求多只，GBK 文本，必须带 Referer（不带回 Forbidden）
    /// 非 private：自检脚本要单独验证这一个源，不能只测「整条链能通」
    func fetchFromSina(codes: [String]) async throws -> [FundQuote] {
        let list = codes.map { "f_\($0)" }.joined(separator: ",")
        let url = URL(string: "https://hq.sinajs.cn/list=\(list)")!
        let text = try await NetworkClient.getText(url: url)
        let parsed = SinaParser.parseFunds(text, source: "新浪基金")
        guard !parsed.isEmpty else { throw FetchError.invalidData("新浪基金解析为空") }
        return parsed
    }

    /// 拉取单只基金重仓
    func fetchHoldings(code: String) async throws -> [FundHolding] {
        let url = URL(string: "\(base)/FundMNInverstPosition?FCODE=\(code)&\(commonParams)")!
        let json = try await NetworkClient.getJSON(url: url, ua: ua, referer: referer)
        return FundParser.parseHoldings(json)
    }

    /// 合并拉取多只基金详情（净值并发 + 重仓并发）
    func fetchAll(codes: [String]) async throws -> [FundDetail] {
        let quotes = try await fetchQuotes(codes: codes)
        guard !quotes.isEmpty else { return [] }
        // 并发拉取所有基金重仓（保持与净值相同的顺序）
        return try await withTaskGroup(of: (Int, [FundHolding]).self) { group in
            for (i, q) in quotes.enumerated() {
                group.addTask {
                    do {
                        let holdings = try await self.fetchHoldings(code: q.code)
                        return (i, holdings)
                    } catch {
                        return (i, [])
                    }
                }
            }
            var slots: [(Int, [FundHolding])] = []
            slots.reserveCapacity(quotes.count)
            for await r in group {
                slots.append(r)
            }
            slots.sort { $0.0 < $1.0 }
            return quotes.enumerated().map { i, q in
                let holdings = slots[i].1
                return FundDetail(quote: q, holdings: holdings, estNav: nil, estChangePct: nil)
            }
        }
    }
}

// ============ 格式化 ============
enum Format {
    static func price(_ v: Double) -> String { String(format: "%.2f", v) }
    /// 基金净值专用：4 位小数（基金净值通常较小，需更多精度）
    static func navPrice(_ v: Double) -> String { String(format: "%.4f", v) }
    static func pct(_ v: Double) -> String { String(format: "%+.2f%%", v) }

    /// 成交额（元）→ 亿/万 缩写
    static func amount(_ v: Double) -> String {
        if v >= 1e8 { return String(format: "%.1f亿", v / 1e8) }
        if v >= 1e4 { return String(format: "%.0f万", v / 1e4) }
        return String(format: "%.0f", v)
    }
}

// ============ 代码→名称反查服务 ============

/// 通过板块/基金代码反查名称，用于设置页添加时自动填充
enum LookupService {
    /// 板块代码（BKxxxx）→ 板块名称
    static func sectorName(code: String) async -> String? {
        let url = URL(string: "https://push2delay.eastmoney.com/api/qt/ulist.np/get?fltt=2&secids=90.\(code)&fields=f12,f14")!
        guard let json = try? await NetworkClient.getJSON(url: url),
              let data = json["data"] as? [String: Any],
              let diff = data["diff"] as? [[String: Any]],
              let first = diff.first,
              let name = first["f14"] as? String else { return nil }
        return name
    }

    /// 基金代码 → 基金名称
    static func fundName(code: String) async -> String? {
        let url = URL(string: "https://fundmobapi.eastmoney.com/FundMNewApi/FundMNFInfo?pageIndex=1&pageSize=1&Fcodes=\(code)&deviceid=Wap&plat=Wap&product=EFund&version=6.2.8")!
        let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)"
        let referer = "https://mpservice.eastmoney.com/"
        guard let json = try? await NetworkClient.getJSON(url: url, ua: ua, referer: referer),
              let datas = json["Datas"] as? [[String: Any]],
              let first = datas.first,
              let name = first["SHORTNAME"] as? String else { return nil }
        return name
    }
}