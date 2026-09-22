import Foundation

/// 自选板块配置
struct SectorConfig: Codable, Identifiable, Hashable {
    var code: String    // 板块代码
    var name: String    // 板块名称
    var id: String { code }
}

/// 自选基金配置
struct FundConfig: Codable, Identifiable, Hashable {
    var code: String    // 基金代码
    var name: String    // 基金名称
    var id: String { code }
}

/// 用户自选配置（UserDefaults 持久化 JSON）
struct WatchConfig: Codable {
    var sectors: [SectorConfig]
    var funds: [FundConfig]
    /// 状态栏显示来源：nil = 黄金，板块代码 = 对应板块指数
    var statusBarSource: String?

    static let `default` = WatchConfig(
        sectors: [
            SectorConfig(code: "BK0475", name: "半导体"),
            SectorConfig(code: "BK0547", name: "黄金概念"),
            SectorConfig(code: "BK1128", name: "CPO概念"),
        ],
        funds: [
            FundConfig(code: "161725", name: "招商中证白酒指数C"),
            FundConfig(code: "110011", name: "易方达蓝筹精选"),
            FundConfig(code: "005827", name: "易方达蓝筹精选C"),
        ],
        statusBarSource: nil
    )
}

/// 配置存储：UserDefaults JSON
final class ConfigStore: ObservableObject {
    @Published var config: WatchConfig {
        didSet { save() }
    }

    /// 本次启动时被跳过的坏配置项数（0 = 全部完好）。
    /// 设置页用它提示「N 项配置已重置」——不提示的话，用户只会发现自己少了两只基金
    @Published var repairedCount = 0

    private let key = "com.dreamanual.investmonitor.WatchConfig"

    /// 逐项解码
    ///
    /// 原先整体 `try?` 解码：一条坏记录就让整份配置退回 `.default`，
    /// 用户的自选板块与基金全部消失且毫无提示。现在坏项跳过并计数，
    /// 其余照常保留 —— 坏的是那一项，不是整份配置。
    init() {
        let r = Self.decode(UserDefaults.standard.data(forKey: key))
        self.config = r.config
        self.repairedCount = r.repaired
    }

    /// 纯函数版本（不碰 UserDefaults），便于自检直接构造坏数据
    static func decode(_ data: Data?) -> (config: WatchConfig, repaired: Int) {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (.default, 0)
        }
        var repaired = 0
        let sectors: [SectorConfig] = decodeList(root["sectors"], repair: &repaired)
        let funds: [FundConfig] = decodeList(root["funds"], repair: &repaired)
        return (
            WatchConfig(sectors: sectors, funds: funds,
                        statusBarSource: root["statusBarSource"] as? String),
            repaired
        )
    }

    private static func decodeList<T: Decodable>(_ any: Any?, repair: inout Int) -> [T] {
        guard let arr = any as? [Any] else { return [] }
        var out: [T] = []
        for item in arr {
            guard let d = try? JSONSerialization.data(withJSONObject: item),
                  let v = try? JSONDecoder().decode(T.self, from: d) else {
                repair += 1
                continue
            }
            out.append(v)
        }
        return out
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: - 增删

    func addSector(_ s: SectorConfig) {
        guard !config.sectors.contains(where: { $0.code == s.code }) else { return }
        config.sectors.append(s)
    }

    func removeSector(_ s: SectorConfig) {
        config.sectors.removeAll { $0.code == s.code }
    }

    func addFund(_ f: FundConfig) {
        guard !config.funds.contains(where: { $0.code == f.code }) else { return }
        config.funds.append(f)
    }

    func removeFund(_ f: FundConfig) {
        config.funds.removeAll { $0.code == f.code }
    }
}
