import Foundation
import Combine

/// 版本更新信息（从远程 JSON / GitHub API 解析）
struct UpdateInfo: Codable {
    let version: String
    let notes: String?
    let downloadUrl: String
    let releaseUrl: String?

    enum CodingKeys: String, CodingKey {
        case version
        case notes
        case downloadUrl = "download_url"
        case releaseUrl = "release_url"
    }
}

/// 版本检查器：A 源（网站 JSON）主、B 源（GitHub API）备，双源容错
final class UpdateChecker: ObservableObject {

    /// 检测到新版本时赋值，UI 据此显示横幅
    @Published var availableUpdate: UpdateInfo?

    /// 是否正在检查中
    @Published private(set) var isChecking = false

    /// 手动检查的状态反馈（设置页「立即检查」按钮旁展示）
    enum ManualCheckStatus: Equatable {
        case idle       // 未检查
        case checking   // 检查中
        case upToDate   // 已是最新
        case newVersion // 发现新版本
        case failed     // 检查失败
    }
    @Published var manualCheckStatus: ManualCheckStatus = .idle

    /// 标记当前检查是否由手动触发（用于结果反馈）
    private var isManualCheck = false

    /// 当前 app 版本号（从 Info.plist 读取）
    let currentVersion: String

    /// URL 常量：固定不变，每次发版只改服务器上的文件
    private let primaryURL = URL(string: "https://dreamanual.com/works/downloads/invest-version.json")!
    private let githubAPIURL = URL(string: "https://api.github.com/repos/lantian-dreamanual/invest-monitor/releases/latest")!

    /// 固定的下载链接（invest-version.json 和 GitHub Release 中 URL 永不变）
    private let websiteDownloadURL = "https://dreamanual.com/works/downloads/Dreamanual 投资监控.dmg"
    private let githubReleaseURL = "https://github.com/lantian-dreamanual/invest-monitor/releases"

    /// UserDefaults key
    private let ignoredVersionKey = "com.dreamanual.investmonitor.ignoredVersion"
    private let autoCheckKey = "com.dreamanual.investmonitor.autoCheckUpdate"

    init() {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - 公开属性

    /// 用户是否开启自动检查更新（默认开）
    var autoCheckEnabled: Bool {
        get {
            // 首次使用默认为 true（未设置 key 时返回 true）
            if UserDefaults.standard.object(forKey: autoCheckKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: autoCheckKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoCheckKey) }
    }

    /// 用户忽略的版本号
    var ignoredVersion: String? {
        get { UserDefaults.standard.string(forKey: ignoredVersionKey) }
        set { UserDefaults.standard.set(newValue, forKey: ignoredVersionKey) }
    }

    // MARK: - 版本检查

    /// 自动检查（受 autoCheckEnabled 开关控制）
    func checkForUpdate() {
        guard autoCheckEnabled else { return }
        performCheck()
    }

    /// 手动触发检查（设置页「立即检查」按钮，不受 autoCheckEnabled 限制）
    func manualCheck() {
        guard !isChecking else { return }
        availableUpdate = nil
        ignoredVersion = nil
        isManualCheck = true
        manualCheckStatus = .checking
        performCheck()
    }

    private func performCheck() {
        guard !isChecking else { return }
        isChecking = true

        Task { [weak self] in
            guard let self else { return }

            // A 源：网站 invest-version.json（3 秒超时）
            let primaryResult = await self.fetchFromPrimary()
            if let info = primaryResult {
                await self.handleResult(info)
                return
            }

            // B 源：GitHub Releases API（3 秒超时）
            let secondaryResult = await self.fetchFromGitHub()
            if let info = secondaryResult {
                await self.handleResult(info)
                return
            }

            // 双源均失败
            await MainActor.run {
                self.isChecking = false
                if self.isManualCheck {
                    self.manualCheckStatus = .failed
                    self.isManualCheck = false
                }
            }
        }
    }

    // MARK: - 网络请求

    /// A 源：网站 invest-version.json
    private func fetchFromPrimary() async -> UpdateInfo? {
        var request = URLRequest(url: primaryURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.setValue("DreamanualInvestMonitor/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let info = try JSONDecoder().decode(UpdateInfo.self, from: data)
            // 用网站的 download_url，release_url 用 JSON 中的或回退固定值
            return UpdateInfo(
                version: info.version,
                notes: info.notes,
                downloadUrl: info.downloadUrl,
                releaseUrl: info.releaseUrl ?? githubReleaseURL
            )
        } catch {
            return nil
        }
    }

    /// B 源：GitHub Releases API
    private func fetchFromGitHub() async -> UpdateInfo? {
        var request = URLRequest(url: githubAPIURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.setValue("DreamanualInvestMonitor/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            // 解析 GitHub Release JSON
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tagName = json["tag_name"] as? String {
                // tag_name 格式如 "v1.0.0"，去掉前缀 'v'
                let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
                let notes = json["body"] as? String
                // B 源获取 → 推 GitHub 链接
                return UpdateInfo(
                    version: version,
                    notes: notes,
                    downloadUrl: "https://github.com/lantian-dreamanual/invest-monitor/releases/latest",
                    releaseUrl: githubReleaseURL
                )
            }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - 结果处理

    private func handleResult(_ info: UpdateInfo) async {
        await MainActor.run {
            self.isChecking = false
            // 版本号对比：远程 > 本地 才提示
            guard self.isNewer(info.version, than: self.currentVersion) else {
                self.availableUpdate = nil
                if self.isManualCheck {
                    self.manualCheckStatus = .upToDate
                    self.isManualCheck = false
                }
                return
            }
            // 用户已忽略此版本 → 不提示
            if info.version == self.ignoredVersion {
                self.availableUpdate = nil
                if self.isManualCheck {
                    self.manualCheckStatus = .upToDate
                    self.isManualCheck = false
                }
                return
            }
            self.availableUpdate = info
            if self.isManualCheck {
                self.manualCheckStatus = .newVersion
                self.isManualCheck = false
            }
        }
    }

    /// 版本号比较：a > b 则 true（语义化版本 x.y.z）
    private func isNewer(_ a: String, than b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(aParts.count, bParts.count)
        for i in 0..<maxLen {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av > bv { return true }
            if av < bv { return false }
        }
        return false
    }

    // MARK: - 用户操作

    /// 忽略当前版本（不再提示，直到更高版本发布）
    func ignoreCurrentVersion() {
        if let info = availableUpdate {
            ignoredVersion = info.version
            availableUpdate = nil
        }
    }
}
