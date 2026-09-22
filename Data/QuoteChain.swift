import Foundation

// ============ 行情降级链 ============

/// 一个候选数据源：名字（用于错误提示与来源标记）+ 抓取动作
struct QuoteSource<T> {
    let name: String
    let run: () async throws -> T

    init(_ name: String, _ run: @escaping () async throws -> T) {
        self.name = name
        self.run = run
    }
}

/// 抓取结果：值 + 命中的来源名
struct Sourced<T> {
    let value: T
    let source: String
}

/// 有序降级链：按声明顺序依次尝试，第一个成功即返回；全败抛出带全部来源名的错误。
///
/// 为什么必须成链：这些接口是唯一数据来源，挂了就是整天没数 —— 而 App 常驻后台，
/// 用户不会知道今天的数据是空的还是没变。链上每一级都要是**同口径**的源：
/// 数值差一点都会让绝对价格阈值误判，宁可不降级（黄金的新浪源就因此被排除）。
enum QuoteChain {
    static func run<T>(_ sources: [QuoteSource<T>]) async throws -> Sourced<T> {
        var failed: [String] = []
        for s in sources {
            do {
                let v = try await s.run()
                return Sourced(value: v, source: s.name)
            } catch {
                failed.append(s.name)
            }
        }
        throw FetchError.allSourcesFailed(failed)
    }
}
