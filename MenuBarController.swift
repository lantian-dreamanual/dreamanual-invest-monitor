import AppKit
import SwiftUI
import Combine

/// 可聚焦的 NSPanel：nonactivatingPanel 默认 canBecomeKey 为 false，
/// 导致面板内 TextField 无法获得焦点（输入框点不动）。
/// 覆写后点击输入框时面板可作为 key window 接收键盘输入，同时保持非激活特性。
final class FocusablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 状态栏控制器：负责状态栏图标、定时刷新、面板弹出
final class MenuBarController: NSObject, ObservableObject {
    // MARK: 模态弹窗状态（自绘 DmModal，由 MainPanelView 根部统一呈现。
    // 收敛到控制器：添加弹窗在设置页触发、编辑弹窗在提醒列表行触发，
    // 遮罩必须盖住整面板，行/页各自的局部 overlay 都做不到。）
    @Published var showAddAlert = false
    @Published var editingRule: AlertRule?

    @Published var gold: GoldQuote?
    @Published var lastUpdate: Date?
    @Published var isLoading = false
    @Published var errorMessage: String?       // 主要数据（黄金/板块）错误
    @Published var fundErrorMessage: String?    // 基金数据错误（独立显示）
    // M3 板块
    @Published var sector: SectorQuote?
    @Published var sectorStocks: [StockQuote] = []
    // M4 基金
    @Published var funds: [FundDetail] = []
    @Published var fundStockChanges: [String: Double] = [:]
    // M5 配置
    @Published var configStore: ConfigStore
    @Published var allSectors: [SectorQuote] = []   // 所有配置板块指数
    @Published var currentSectorCode: String        // 当前选中板块
    // 分时线
    @Published var trendData: TrendData?       // 板块分时
    @Published var goldTrendData: TrendData?   // 黄金分时
    // M6 预警
    @Published var alertConfig: AlertConfig
    /// 无判定价留痕：ruleId → 首次拿不到判定价的时刻（有价时自愈清掉）
    @Published var unjudgedRules: [String: Date] = [:]
    /// 事件表快照（ruleId → 最新一行）：规则行状态从这里派生，避免每行一次查库
    @Published var alertEvents: [String: AlertEventStore.Event] = [:]
    // 刷新倒计时（秒），右上角展示「x 秒后更新」
    @Published var countdown = 30
    // 右上角状态文案
    @Published var allMarketsClosed = false
    @Published var panelStatusText: String = ""
    /// 通知点击后待切换的 Tab（nil 表示无需切换）
    @Published var pendingTab: MainPanelView.Tab?
    /// 版本更新检查器
    @Published var updateChecker = UpdateChecker()

    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var timer: Timer?
    private var countdownTimer: Timer?
    /// 上一轮刷新的时刻（定时器按窗口分档要用）
    private var lastRefreshAt: Date?
    private var wakeObserver: NSObjectProtocol?
    private let service = GoldService()
    private let sectorService = SectorService()
    private let fundService = FundService()
    private var cancellables = Set<AnyCancellable>()
    private let notifier = AlertNotifier.shared

    override init() {
        let store = ConfigStore()
        self.configStore = store
        self.currentSectorCode = store.config.sectors.first?.code ?? "BK0475"
        self.alertConfig = AlertConfig()
        super.init()
        // 先把事件表快照读进来，规则行首屏就有状态
        refreshAlertEvents()
        // configStore 变化转发到 controller，驱动 SwiftUI 视图刷新
        store.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        alertConfig.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        // 请求通知权限
        notifier.requestPermission()
        // 通知点击回调：通过规则 ID 查找标的类型，切换到对应 Tab 并打开面板
        notifier.onNotificationTap = { [weak self] ruleId in
            DispatchQueue.main.async {
                self?.handleNotificationTap(ruleId: ruleId)
            }
        }
        setupStatusItem()
        // 再把上一轮行情铺上，冷启动不出现空窗（首轮请求回来即覆盖）
        //
        // ⚠️ 必须排在 setupStatusItem() 之后：本函数末尾要调 updateStatusTitle()，
        //    而 statusItem 是隐式解包可选，在它被创建之前解包会直接 SIGTRAP。
        //    2026-09-22 实测踩到：编译/签名全绿，一启动就退，crash 报告指到
        //    restoreSnapshot → updateStatusTitle。之所以潜伏很久才暴露，是因为
        //    SnapshotStore.save() 只在抓取成功路径上调用，之前一直抓不到数据、
        //    快照从未写成功，每次冷启动都在快照判空处提前 return。
        restoreSnapshot()
        setupPanel()
        observeWake()
        startTimer()
        // 启动后延迟 2 秒检查更新（避免与启动刷新竞争网络）
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.updateChecker.checkForUpdate()
        }
        // 每 6 小时定时检查一次
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.updateChecker.checkForUpdate()
        }
    }

    // MARK: - 状态栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick)
            // 监听左右键鼠标抬起，区分左键切面板 / 右键弹菜单
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusTitle()
    }

    /// 统一入口：左键 toggle 面板，右键弹出菜单
    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else {
            togglePopover(nil)
            return
        }
        if event.type == .rightMouseUp {
            closePanel() // 右键时先收起面板
            statusItem.popUpMenu(buildContextMenu())
        } else {
            togglePopover(nil)
        }
    }

    /// 右键菜单：退出应用
    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        // 退出
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    /// 退出应用
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    /// 更新状态栏文字：根据配置显示黄金或板块指数，交易时段带箭头
    func updateStatusTitle() {
        // statusItem 由 setupStatusItem() 创建。init 早期（快照回填）也会走到这里，
        // 那时它还是 nil —— 隐式解包会 SIGTRAP，所以先显式判空
        guard statusItem != nil, let button = statusItem.button else { return }
        let source = configStore.config.statusBarSource ?? "gold"

        if source == "gold" {
            // 黄金
            guard let g = gold else { button.title = "--"; return }
            let title: String
            if goldMarketStatus == .trading || goldMarketStatus == .delayed {
                let arrow = g.changePct >= 0 ? "▲" : "▼"
                title = String(format: "%@ %.2f", arrow, g.priceCNY)
            } else {
                title = String(format: "%.2f", g.priceCNY)
            }
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: DmText.t12, weight: .medium)]
            )
        } else {
            // 板块指数
            guard let s = allSectors.first(where: { $0.code == source }) ?? sector
            else { button.title = "--"; return }
            let title: String
            if stockMarketStatus == .trading {
                let arrow = s.changePct >= 0 ? "▲" : "▼"
                title = String(format: "%@ %.2f", arrow, s.index)
            } else {
                title = String(format: "%.2f", s.index)
            }
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: DmText.t12, weight: .medium)]
            )
        }
    }

    // MARK: - 弹窗（自定义 NSPanel，无三角箭头）

    private func setupPanel() {
        let contentView = MainPanelView(controller: self)
        let hosting = NSHostingView(rootView: contentView)
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 500)
        // 圆角裁剪：面板本身透明，内容视图裁出圆角
        // 取「弹窗 / 大容器」档（r16），与 audio 的结果弹窗同一角色
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = DmRadius.r16
        hosting.layer?.masksToBounds = true

        panel = FocusablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
    }

    @objc private func togglePopover(_ sender: Any?) {
        if panel.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button else { return }
        // 弹出前立即刷新一次，保证数据最新
        Task { await refresh() }

        // 定位到状态栏按钮下方居中，屏幕边界内钳制
        let size = panel.frame.size
        let btnFrame = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? button.bounds
        var x = btnFrame.midX - size.width / 2
        let y = btnFrame.minY - size.height - 4
        if let screen = button.window?.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            x = min(max(x, vf.minX + 4), vf.maxX - size.width - 4)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
        // 延迟启动监控，避免触发弹出的那次点击被 monitor 捕获导致面板瞬关
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard self?.panel.isVisible == true else { return }
            self?.startMonitoring()
        }
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        stopMonitoring()
    }

    // MARK: - 外部点击关闭

    private func startMonitoring() {
        stopMonitoring()
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.handleOutsideClick() }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.handleOutsideClick()
            return event
        }
    }

    private func stopMonitoring() {
        if let m = globalEventMonitor { NSEvent.removeMonitor(m); globalEventMonitor = nil }
        if let m = localEventMonitor { NSEvent.removeMonitor(m); localEventMonitor = nil }
    }

    /// 点击面板外部时关闭；点击状态栏按钮区域交给 toggle 逻辑处理，不在此关闭
    private func handleOutsideClick() {
        guard panel.isVisible else { return }
        let mouseLoc = NSEvent.mouseLocation // 屏幕坐标（左下原点），与 panel.frame 同坐标系
        if let button = statusItem.button, let win = button.window {
            let btnFrame = win.convertToScreen(button.convert(button.bounds, to: nil))
                .insetBy(dx: -4, dy: -4)
            if btnFrame.contains(mouseLoc) { return }
        }
        if panel.frame.contains(mouseLoc) { return }
        // 点击落在本 App 的其他窗口（如 SwiftUI Popover、Alert 弹窗等）时不关闭
        if NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(mouseLoc) }) { return }
        closePanel()
    }

    // MARK: - 定时器

    /// 黄金交易时段：夜盘 21:00-02:30 + 日盘 09:00-11:30 / 13:30-15:00
    ///
    /// 交易日判定走 TradingCalendar（含法定节假日）；陈旧判定统一走 DataFreshness。
    /// 原先黄金用分时线最后点算 120s 阈值，板块完全没有 —— 同一件事两套口径，
    /// 结果是三个 Tab 的「延迟」表现不一致。
    var goldMarketStatus: MarketStatus {
        guard TradingCalendar.isTradingDay() else { return .closed }
        let now = minuteOfDay
        // 夜盘 21:00-02:30
        if now >= 21 * 60 || now <= 2 * 60 + 30 { return sessionStatus(gold?.quoteAt) }
        // 日盘 09:00-11:30
        if now >= 9 * 60 && now <= 11 * 60 + 30 { return sessionStatus(gold?.quoteAt) }
        // 午休 11:30-13:30
        if now > 11 * 60 + 30 && now < 13 * 60 + 30 { return .break_ }
        // 日盘 13:30-15:00
        if now >= 13 * 60 + 30 && now <= 15 * 60 { return sessionStatus(gold?.quoteAt) }
        return .closed
    }

    /// A股交易时段：09:30-11:30 + 13:00-15:00
    ///
    /// 这里原先永远只返回 .trading / .closed，从不返回 .delayed ——
    /// 板块接口卡住时界面照旧显示「交易中」，看不出数据已经不动了
    var stockMarketStatus: MarketStatus {
        guard TradingCalendar.isTradingDay() else { return .closed }
        let now = minuteOfDay
        let quoteAt = sector?.quoteAt ?? allSectors.first?.quoteAt
        if now >= 9 * 60 + 30 && now <= 11 * 60 + 30 { return sessionStatus(quoteAt) }
        if now > 11 * 60 + 30 && now < 13 * 60 { return .break_ }
        if now >= 13 * 60 && now <= 15 * 60 { return sessionStatus(quoteAt) }
        return .closed
    }

    /// 交易时段内的状态：陈旧则 delayed。
    ///
    /// 从未拿到过行情（quoteAt 为 nil）时归 .trading 而不是 .delayed ——
    /// 「市场状态」与「数据有没有到手」是两件事，后者由 errorMessage 与
    /// 预警规则行的「未生效 · 无行情」表达。否则每次启动的头几秒都在喊延迟。
    private func sessionStatus(_ quoteAt: Date?) -> MarketStatus {
        guard let at = quoteAt else { return .trading }
        return DataFreshness.isStale(at) ? .delayed : .trading
    }

    private var minuteOfDay: Int {
        let c = Calendar.current
        return c.component(.hour, from: Date()) * 60 + c.component(.minute, from: Date())
    }

    /// 净值窗口：交易日 15:05 之后
    ///
    /// 这一段原本是死区 —— 黄金日盘 15:00 收、夜盘 21:00 才开，A 股 15:00 收，
    /// 于是 15:00–21:00 刷新门禁恒为 false，而基金净值 15:05 起就陆续披露了。
    ///
    /// 「交易日」用 TradingCalendar 而不是「非周末」：国庆长假里净值不披露，
    /// 按非周末算会连着七天做无用请求，还会把「净值日期没变」误判成异常。
    var fundNavWindow: Bool {
        TradingCalendar.isTradingDay() && minuteOfDay >= 15 * 60 + 5
    }

    /// 有任一窗口开着就该刷新
    private var shouldRefresh: Bool {
        if goldMarketStatus == .trading || goldMarketStatus == .delayed { return true }
        if stockMarketStatus == .trading || stockMarketStatus == .delayed { return true }
        return fundNavWindow
    }

    /// 刷新间隔按窗口分档
    ///   · 交易时段 30s —— 告警判定挂在刷新上，面板开不开都一样
    ///   · 净值窗口：面板收起 5 分钟（净值一天只变一次），面板打开 60s
    ///   · 其余 5 分钟（实际走不到，shouldRefresh 已经拦住）
    private var refreshInterval: TimeInterval {
        if goldMarketStatus == .trading || goldMarketStatus == .delayed { return 30 }
        if stockMarketStatus == .trading || stockMarketStatus == .delayed { return 30 }
        if fundNavWindow { return panel?.isVisible == true ? 60 : 300 }
        return 300
    }

    /// 后台常驻定时器：心跳 30 秒，实际刷新按当前窗口的档位决定
    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.shouldRefresh else { return }
            if let last = self.lastRefreshAt,
               Date().timeIntervalSince(last) < self.refreshInterval - 1 { return }
            Task { await self.refresh() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        startCountdownTimer()
        // 启动立即刷新（这一轮天然完成「启动补判」）
        Task { await refresh() }
    }

    /// 睡眠唤醒后补判
    ///
    /// Mac 睡一下午，收盘判定的那一刻正好错过，那条线当天就永远不响了。
    /// 补判判据用事件表（「这条线的今天 pdate 有没有行」）而不是时间戳 —— 后者不可靠。
    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    /// 每秒倒计时，驱动右上角文案
    private func startCountdownTimer() {
        guard countdownTimer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let gold = self.goldMarketStatus
            let stock = self.stockMarketStatus
            let anyTrading = gold == .trading || gold == .delayed
                || stock == .trading || stock == .delayed
            let anyBreak = gold == .break_ || stock == .break_
            // 倒计时要跟着实际档位走，否则净值窗口里会一直显示「30 秒后更新」
            // 而实际 5 分钟才刷一次
            let span = Int(self.refreshInterval)

            if anyTrading {
                self.allMarketsClosed = false
                if self.isLoading { return }
                self.countdown -= 1
                if self.countdown <= 0 { self.countdown = span }
            } else if anyBreak {
                self.allMarketsClosed = false
                self.countdown = 0
                self.panelStatusText = StatusDescriptor.break_.text
            } else if self.fundNavWindow {
                // 15:05–21:00：场内休市，但场外净值在陆续披露
                self.allMarketsClosed = false
                self.countdown = 0
                self.panelStatusText = StatusDescriptor.navUpdating.text
            } else {
                self.allMarketsClosed = true
                self.countdown = 0
                self.panelStatusText = StatusDescriptor.closed.text
            }
        }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        countdownTimer = t
    }

    // MARK: - 刷新

    @MainActor
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        isLoading = true
        defer {
            isRefreshing = false
            isLoading = false
            // 对齐当前档位，而不是写死 30
            countdown = Int(refreshInterval)
            lastRefreshAt = Date()
        }
        // 板块被删除后，修正当前选中到第一个可用板块
        if !configStore.config.sectors.contains(where: { $0.code == currentSectorCode }) {
            currentSectorCode = configStore.config.sectors.first?.code ?? "BK0475"
        }
        let sectorCodes = configStore.config.sectors.map { $0.code }
        let sectorName = configStore.config.sectors.first(where: { $0.code == currentSectorCode })?.name ?? ""

        // 每个族各自降级：一族抓不到只影响它自己。
        // 此前五路 async let 共用一个 try，任一路失败就整块跳到 catch —— 基金明明
        // 取到了也被一起放弃，面板只剩一句「（已显示上次数据）」，看起来像全网都挂了。
        var failed: [String] = []
        var goldOK = false
        var sectorOK = false

        // 黄金族：现价 + 分时线（国际品种，独立拉取）
        do {
            self.gold = try await service.fetch()
            goldOK = true
        } catch {
            failed.append("黄金")
        }
        do {
            self.goldTrendData = try await sectorService.fetchGoldTrends()
        } catch {
            failed.append("黄金分时")
        }

        // 板块族：指数 + 成分股 + 分时线（同一族的三个面，任一失败按该族没拿到算）
        do {
            async let indexTask = sectorService.fetchIndex(code: currentSectorCode, name: sectorName)
            async let stocksTask = sectorService.fetchStocks(code: currentSectorCode)
            async let trendsTask = sectorService.fetchTrends(code: currentSectorCode, name: sectorName)
            let (s, st, td) = try await (indexTask, stocksTask, trendsTask)
            self.sector = alignSectorName(s)
            self.sectorStocks = st
            self.trendData = td
            sectorOK = true
        } catch {
            failed.append("板块")
        }

        // 所有板块指数（Tab 快切用）：与当前板块各算各的，失败不回退已取到的当前板块
        if sectorCodes.count > 1 {
            if let list = try? await sectorService.fetchIndices(
                codes: sectorCodes,
                names: configStore.config.sectors.map { $0.name }
            ) {
                self.allSectors = list.map(alignSectorName)
            } else if sectorOK, let s = self.sector {
                self.allSectors = [s]
            }
        } else if sectorOK, let s = self.sector {
            self.allSectors = [s]
        }

        // M4 基金：净值 + 重仓 + 实时行情估算
        let fundOK = await self.refreshFunds()

        if failed.isEmpty {
            self.lastUpdate = Date()
            self.errorMessage = nil
        } else {
            // 一句话说清三件事：哪几块没拿到、现在显示的是什么、会不会自愈。
            // 没抓到与抓到的数据没法用，对用户是同一件事：界面这次没更新、会自动重试。
            // 原因留在数据层，提示条只给结论 —— 此前写法分出「数据异常」一支，
            // 既露了内部判定，还漏掉「稍后自动重试」，与另一支口径不一致。
            var names = failed
            if names.contains("黄金") { names.removeAll { $0 == "黄金分时" } }
            let label = names.joined(separator: "、")
            self.errorMessage = "\(label)没更新，显示的是上次数据，稍后自动重试"
        }
        self.updateStatusTitle()

        // 落盘快照：确有族刷新了才写，全失败时不必把旧数据重复存一遍
        if goldOK || sectorOK || fundOK {
            SnapshotStore.save(gold: self.gold, sector: self.sector,
                               sectors: self.allSectors, funds: self.funds)
        }

        // M6 预警检查：只评估本轮真抓到的族。
        // 保留旧数据。整族抓取失败也要走一轮判定 —— 拿不到判定价的线必须留痕，
        // 否则你在规则列表上看不出那条线已经一天没在工作
        var succeeded: Set<AlertTargetType> = []
        if goldOK { succeeded.insert(.goldCNY) }
        if sectorOK { succeeded.insert(.sector) }
        if fundOK { succeeded.insert(.fund) }
        self.checkAlerts(scope: AlertScope(
            attempted: [.goldCNY, .sector, .fund], succeeded: succeeded
        ))
    }

    /// 当前板块代码
    private var currentSector: String {
        currentSectorCode
    }

    /// 刷新基金：净值 → 重仓 → 批量行情 → 估算
    /// - Returns: 本轮基金数据是否可用（决定基金族的规则是否参与判定）
    @MainActor
    @discardableResult
    func refreshFunds() async -> Bool {
        // 立即移除已从配置删除的基金，UI 瞬间反映
        let validCodes = Set(configStore.config.funds.map { $0.code })
        self.funds = self.funds.filter { validCodes.contains($0.quote.code) }

        do {
            let details = try await fundService.fetchAll(codes: configStore.config.funds.map { $0.code })
            // 配了基金却一条都没解析出来 → 按抓取失败处理，
            // 否则该族规则会被当成「有数据」而漏掉「无行情」留痕
            if !configStore.config.funds.isEmpty && details.isEmpty {
                self.fundErrorMessage = "基金数据获取失败，稍后自动重试"
                return false
            }
            // 合并所有重仓股，去重
            var holdings: [(code: String, exchange: Int)] = []
            var seen = Set<String>()
            for d in details {
                for h in d.holdings {
                    let key = h.code
                    if !seen.contains(key) {
                        seen.insert(key)
                        holdings.append((code: h.code, exchange: h.exchange))
                    }
                }
            }
            // 批量拉取实时涨跌
            let changes = try await sectorService.fetchStockChanges(codes: holdings)
            // 计算估算：交易日（非周末）且净值未更新到今日时计算估算，
            // 时段限制在当日 9:30 之后——开盘前重仓股无当日行情，估算无意义
            // 收盘后到净值发布前保留当日估算快照作为参考
            // 净值已更新到今日则估算无意义，不再计算
            let today = MarketClock.today()
            // 交易日走 TradingCalendar：长假里净值不更新，按「非周末」算会
            // 连着一周做无用估算，还会把「净值日期没变」误判成异常
            let isTradingDay = TradingCalendar.isTradingDay()
            let afterOpen = minuteOfDay >= 9 * 60 + 30 // 已过 9:30
            var updated = details
            for i in updated.indices {
                guard isTradingDay, afterOpen, updated[i].quote.navDate != today else { continue }
                let est = FundEstimator.estimate(holdings: updated[i].holdings, stockMap: changes)
                updated[i].estChangePct = est?.pct
                updated[i].estCoverage = est?.coverage
                if let pct = est?.pct {
                    updated[i].estNav = FundEstimator.estimateNav(nav: updated[i].quote.nav, changePct: pct)
                }
            }
            self.funds = updated
            self.fundStockChanges = changes
            self.fundErrorMessage = nil
            return true
        } catch is FetchError {
            self.fundErrorMessage = "基金数据获取失败，稍后自动重试"
            // 基金失败不阻塞主流程，保留旧数据
            return false
        } catch {
            self.fundErrorMessage = "基金数据获取失败，稍后自动重试"
            return false
        }
    }

    func refreshNow() async {
        await refresh()
    }

    /// 方案C：切换板块时只刷新当前板块相关数据（指数 + 成分股 + 分时线），
    /// 行情对象的显示名对齐配置名。板块以 code 为唯一标识，东财返回的官方名
    /// （如 BK0475 → 银行Ⅱ）在用户改名后会一直顶着，展示层会分裂成
    /// 「选择器显示配置名、行情卡显示官方名」（2026-10-09 实测）。统一在这里对齐。
    private func alignSectorName(_ quote: SectorQuote) -> SectorQuote {
        var quote = quote
        if let cfg = configStore.config.sectors.first(where: { $0.code == quote.code }) {
            quote.name = cfg.name
        }
        return quote
    }

    /// 不触发黄金/基金的增量请求，降低板块切换时的卡顿
    @MainActor
    func refreshSector(code: String) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let sectorName = configStore.config.sectors.first(where: { $0.code == code })?.name ?? ""
        do {
            async let sectorTask = sectorService.fetchIndex(code: code, name: sectorName)
            async let stocksTask = sectorService.fetchStocks(code: code)
            async let trendsTask = sectorService.fetchTrends(code: code, name: sectorName)
            let (s, st, td) = try await (sectorTask, stocksTask, trendsTask)
            self.sector = alignSectorName(s)
            self.sectorStocks = st
            self.trendData = td
        } catch {
            // 板块切换失败保留旧数据，不阻塞主流程
            self.errorMessage = "板块没更新，显示的是上次数据，稍后自动重试"
        }
    }

    // MARK: - 预警

    /// 预警检查：日终判定 → 落事件表 → 合并推送 → 无判定价留痕
    @MainActor
    func checkAlerts(scope: AlertScope) {
        let result = AlertEngine.evaluate(
            rules: alertConfig.rules, gold: gold, sectors: allSectors, funds: funds,
            scope: scope, today: MarketClock.today(), now: Date(),
            store: AlertEventStore.shared
        )

        applyUnjudged(result)

        // 同品种同日多条线命中 → 合并为一条（一次暴跌同时击穿两条线时，
        // 两条高度重叠的通知反而削弱警报的严肃性）
        for group in AlertEngine.grouped(result.pending) {
            var notice = AlertEngine.notice(from: group.main)
            notice.rest = group.rest.map { AlertEngine.notice(from: $0) }
            notifier.sendNotification(notice)
            // 标记「这一天推送过了」—— 频控最后一道（判定价没变就不再推）用的就是它
            for e in [group.main] + group.rest {
                AlertEventStore.shared.markNotified(ruleId: e.rule.id, pdate: e.pdate)
            }
        }

        refreshAlertEvents()
    }

    /// 刷新事件表快照，驱动规则行重算
    private func refreshAlertEvents() {
        alertEvents = AlertEventStore.shared.latest()
    }

    /// 冷启动回填：把上一轮快照铺到界面上
    ///
    /// 只负责消除空白，不做任何判定 —— 这些数据带着自己的行情时间戳，
    /// 时效提示会照实显示「截至 09-22 15:00」，不会伪装成刚抓到的
    private func restoreSnapshot() {
        guard let snap = SnapshotStore.load() else { return }
        if let g = snap.gold?.quote { gold = g }
        if let s = snap.sector?.quote { sector = s }
        if !snap.sectors.isEmpty { allSectors = snap.sectors.map(\.quote) }
        if !snap.funds.isEmpty { funds = snap.funds.map(\.detail) }
        updateStatusTitle()
    }

    /// 规则行的状态呈现（五种 kind，优先级 hit > counting > confirmed > dead > last > none）
    ///
    /// 两条优先级规则：
    ///   · `hit` 排在 state 前面 —— 否则用户永远看不到「今日已触发」那一天
    ///   · `dead` 排在 `counting` / `confirmed` 之后 —— 「没拿到行情」是数据运行态，
    ///     「连续第几天」是长期结论；让前者盖掉后者，一次网络抖动就把「纪律还在成立」藏起来了
    func alertRowState(for rule: AlertRule) -> AlertRowState {
        let today = MarketClock.today()
        if let ev = alertEvents[rule.id] {
            if ev.state == .confirmed, ev.notified, ev.pdate == today {
                return AlertRowState(kind: .hit, text: "今日已触发")
            }
            switch ev.state {
            case .counting:
                return AlertRowState(kind: .counting,
                                     text: "已连续 \(ev.days)/\(rule.effectiveConfirmDays) 天")
            case .confirmed:
                return AlertRowState(kind: .confirmed, text: "连续 \(ev.days) 天")
            case .idle:
                break
            }
        }
        if unjudgedRules[rule.id] != nil {
            return AlertRowState(kind: .dead, text: "待判定 · 无行情")
        }
        if let ev = alertEvents[rule.id] {
            return AlertRowState(kind: .last, text: "最近判定 \(ev.pdate)")
        }
        return AlertRowState(kind: .none, text: "尚未判定")
    }

    /// 无判定价留痕与自愈
    ///
    /// 只在**首次**标记时写时间：持续无行情时时间戳稳定，否则每轮都变，
    /// 界面轮询到变化就重绘，且看不出「从什么时候开始没行情」。
    private func applyUnjudged(_ result: AlertEvalResult) {
        var next = unjudgedRules
        for m in result.missing where next[m.ruleId] == nil {
            next[m.ruleId] = Date()
        }
        // 有判定价的一轮要清掉标记，否则一次网络抖动会永久挂着「未生效」
        for id in result.judged { next[id] = nil }
        if next != unjudgedRules { unjudgedRules = next }
    }

    /// 通知点击：通过规则 ID 查找标的类型，切换到对应 Tab 并打开面板
    private func handleNotificationTap(ruleId: String) {
        // 查找规则
        guard let rule = alertConfig.rules.first(where: { $0.id == ruleId }) else {
            // 找不到规则（可能已删除），仅打开面板
            showPanel()
            return
        }

        // 根据标的类型决定切换到哪个 Tab
        switch rule.targetType {
        case .goldCNY:
            pendingTab = .gold
        case .sector:
            pendingTab = .cpo
            // 如果规则关联的板块不是当前板块，切换板块
            if !rule.targetCode.isEmpty && rule.targetCode != currentSectorCode {
                currentSectorCode = rule.targetCode
                Task { await refreshSector(code: rule.targetCode) }
            }
        case .fund:
            pendingTab = .fund
        }

        // 打开面板
        showPanel()
    }

    private var isRefreshing = false

    /// 今日日期字符串 YYYY-MM-DD（用于判断基金净值日期是否为今日）
    static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.string(from: Date())
    }
}