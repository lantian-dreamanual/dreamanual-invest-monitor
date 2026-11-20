import SwiftUI
import AppKit
import Combine

// ============ 设计系统：共享组件 ============

// 配色不在本文件里。色值全部来自 DreamanualTheme.invest.swift（design/build.mjs 生成，
// 请勿手改），本文件只负责「哪个角色用哪个令牌」。改色 → 改 design/tokens.json → 重跑
// build.mjs → 用 scripts/check-tokens.mjs 同步并校验。
//
// 令牌角色速查（细节见 design/docs/design-system.md 第二节）：
//   dmAccent      强调文字 / 图标 / 描边
//   dmAccent2     选中态文字 / 焦点环 / 悬停文字
//   dmAccentFill  承载元素的实心块底（按钮、开关打开态、徽章）
//   dmAccentSoft  选中态底（与 dmAccent2 配对）
//   dmPanel / dmPanel2 / dmPanel3   面板 / 卡片 / 高亮行，依次提亮
//   dmInk / dmInk2 / dmInk3         三级正文，依次变暗

/// 全 app 固定深色。
///
/// 设计系统令牌只有深色一套，跟随系统会让浅色系统下的界面落到没有令牌覆盖的
/// 分支上（窗口底色、卡片、文字全部退回系统色）。定义与音频转换、视频下载
/// 逐字相同（设计系统第八节）—— 此前投资监控直接手写 `NSApp.appearance`，
/// 同一个语义在四端三种落法。
enum DreamanualAppearance {
    static func apply() {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}

/// 交易状态
enum MarketStatus: Equatable {
    case trading   // 交易中
    case delayed   // 数据延迟（交易时段但数据未实时更新）
    case break_    // 午休
    case closed    // 已收盘
}

/// 状态文案与配色的**单一来源**
///
/// 原先同一句话散在三处：枚举、badge 里的 switch、控制器的字符串赋值。
/// 改文案要记住改三个地方，漏一个就出现「徽标说已收盘、右上角说交易中」。
/// 现在枚举只负责 kind，文案只在这里出现一次，控制器与徽标都从这里取。
struct StatusDescriptor: Equatable {
    enum Tone { case live, warn, quiet }

    let text: String
    let tone: Tone

    static let trading = StatusDescriptor(text: "交易中", tone: .live)
    static let delayed = StatusDescriptor(text: "数据延迟", tone: .warn)
    static let break_ = StatusDescriptor(text: "午休", tone: .quiet)
    static let closed = StatusDescriptor(text: "已收盘", tone: .quiet)
    /// 场内休市、场外净值在披露（15:00–21:00）—— 面板状态用，不对应某个市场
    static let navUpdating = StatusDescriptor(text: "净值更新中", tone: .quiet)

    static func of(_ s: MarketStatus) -> StatusDescriptor {
        switch s {
        case .trading: return .trading
        case .delayed: return .delayed
        case .break_: return .break_
        case .closed: return .closed
        }
    }

    /// 状态徽章字色（2026-10-09 徽章改版）：
    /// live 用强调亮档（yellow-400），warn 用族加深档，quiet 用中性次级。
    /// 族 300（ink）压徽章底读感发虚，用户反馈加深一档后全族换 ink-strong。
    var color: Color {
        switch tone {
        case .live: return .dmAccent2
        case .warn: return .dmWarnInkStrong
        case .quiet: return .dmInk2
        }
    }

    /// 徽章底统一 panel-2，与卡片同底 —— 嵌在卡片里时靠 line-2 发丝描边
    /// 分层（与 FormCard「panel-2 底 + line-2 发丝」同一配方）。
    var background: Color {
        .dmPanel2
    }
}

/// 交易状态标签
struct MarketStatusBadge: View {
    let status: MarketStatus

    var body: some View {
        let d = StatusDescriptor.of(status)
        Text(d.text)
            .font(.system(size: DmText.t11, weight: .medium))
            .padding(.horizontal, DmSpace.s6)
            .padding(.vertical, DmSpace.s2)
            .background(
                RoundedRectangle(cornerRadius: DmRadius.r6).fill(d.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DmRadius.r6)
                    .strokeBorder(Color.dmLine2, lineWidth: DmLine.hairline)
            )
            .foregroundColor(d.color)
    }
}

// ============ 设计系统：分段控件 ============

/// 自定义分段控件：**内边距形态**（2026-10-12 规范反转，见 design-system.md
/// 第八节「分段控件」，基准实现是 NAS 助手的 `DmSegmented`）。
/// 容器底按所在面取（`surface.controlFill`：`panel` 面取 `panel-2`）+ `line-2` 发丝描边 + `r-8`（控件档）+ 内边距 `s2`；
/// 段高钉控件档、圆角 `r-6`、段间距 `s2`；选中段实心 `dmAccentFill` +
/// `dmOnAccent` 深字，未选中悬停字 `ink-2` → `ink`。
///
/// 取代 2026-10-09 的无缝形态（段与容器同高、容器 `r-6`、1px 描边、段间无缝）——
/// 那次为治「纵向 padding 撑高随字体漂」把内边距整个收掉了；行高钉档的结论保留，
/// 钉的对象从容器改成段，容器总高随内边距自然长出 4px（32 / 42），不另设档。
///
/// 选中态取 `dmAccentFill` 而非四态表的「取下一档 `accent-fill-2`」：本 app 与
/// NAS 助手走深字方案（fill 500 / fill2 400，下一档更亮），四态表那条是给白字
/// 方案写的。2026-10-09 从 `dmAccentSoft` 深底 + `dmAccent2` 亮字改来 —— 用户
/// 反馈「主色深档底+主色浅档字很难看」，对齐本 app 主按钮（黄底深字）。
///
/// 未选中 = 透明 + 次要色文字。解决 nonactivatingPanel 下系统分段控件选中态变灰。
///
/// **失焦降级**（2026-10-12 接入）：面板留在屏幕上但不是 key 时，选中段从「亮实心 +
/// 深字」切到「暗强调底 + 亮字」（`dmAccentSoft` + `dmAccent2`，实测 9.22:1）。
/// 白字方案那条「字保持 on-accent」在本 app 只有 1.36:1、字会看不见 —— 深字方案的
/// 降级必须连着字色一起换，见 design-system.md 第八节「深字方案两端的失焦降级」。
/// 场景真实存在：面板 `hidesOnDeactivate = false` + `canJoinAllSpaces`，Cmd+Tab 或
/// 切桌面时面板跟着走、但已不是 key（实测面板唤起后 8 秒内 key 保持稳定）。
struct SegmentedTabs<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    var label: (T) -> String
    var style: Style = .default
    /// 容器底色按所在面取（「相邻一档」口径，与 `formField` 同一条）。本 app 的 7 处
    /// 调用点所在面都是 `panel`（主 Tab 在面板、6 处在自绘弹窗卡片，卡片底就是 `panel`），
    /// 全部走默认值。2026-10-12 从写死的 `dmPanel2` 改来 —— 写死就调不到 `panel-3`，
    /// 哪天分段控件搬进 `panel-2` 卡片，容器底会与卡面同色、只剩描边可辨。
    var surface: DmSurface = .panel
    @State private var hovered: T?
    @State private var windowActive = true

    enum Style {
        case `default`      // 主 Tab：通栏等宽，段高控件档 28（容器 32）
        case compact        // 表单内：跟随内容宽度，段高表单档 38（容器 42）
    }

    var body: some View {
        HStack(spacing: DmSpace.s2) {
            ForEach(items, id: \.self) { item in
                let selected = item == selection
                Button {
                    selection = item
                } label: {
                    Text(label(item))
                        .font(.system(size: DmText.t12, weight: selected ? .medium : .regular))
                        .foregroundColor(
                            selected ? (windowActive ? Color.dmOnAccent : Color.dmAccent2)
                                     : (hovered == item ? Color.dmInk : Color.dmInk2)
                        )
                        .lineLimit(1)
                        .padding(.horizontal, style == .default ? DmSpace.s16 : DmSpace.s12)
                        .frame(maxWidth: .infinity)
                        .frame(height: style == .default ? DmControl.h28 : DmControl.h38)
                        .background(
                            RoundedRectangle(cornerRadius: DmRadius.r6)
                                .fill(windowActive ? Color.dmAccentFill : Color.dmAccentSoft)
                                .opacity(selected ? 1 : 0)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isInside in
                    if isInside {
                        hovered = item
                    } else if hovered == item {
                        hovered = nil
                    }
                }
            }
        }
        .padding(DmSpace.s2)
        // 容器底按所在面取（第八节「分段控件」）：主区与弹窗卡片都是 panel，取相邻
        // 一档 panel-2；卡面本身是 panel-2 时由调用点传 `.card` 抬 panel-3。
        .background(
            RoundedRectangle(cornerRadius: DmRadius.r8)
                .fill(surface.controlFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DmRadius.r8)
                .strokeBorder(Color.dmLine2, lineWidth: DmLine.hairline)
        )
        // 窗口 key 状态：本进程只有状态栏面板一个窗口，不过滤 object 也能拿到正确的
        // 通知来源（设计系统第八节「失焦降级」）。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            windowActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            windowActive = false
        }
    }
}

/// 文本页签：页面级视图切换的形态（设计系统第八节「分段控件」两型分工）。
///
/// 无容器、无描边、无选中底色 —— 选中只靠三件事表达：`ink` 字 + semibold +
/// 20×3 主色指示条（`Capsule`，高取 `DmLine.bold`）。NAS 助手 1.0.13 落地，
/// 本 app 于 2026-10-18 移植。
///
/// 与 `SegmentedTabs` 的分工：页面级切换（本 app 只有主面板 黄金/板块/基金 一处）
/// 用这个，表单与卡片内的紧凑互斥切换（弹窗里的标的类型/预警基准/方向）仍用容器
/// 分段。同一个页面同一层级不混用。
///
/// **为什么不做失焦降级**：选中态里没有任何实底色块，`ink` 字压面板底在窗口 key 与
/// 非 key 时都是同一读数，不需要像 `SegmentedTabs` 那样换一套降级色。
struct DmTextTabs<Item: Hashable>: View {
    let items: [Item]
    let label: (Item) -> String
    @Binding var selection: Item
    /// 等宽：窄容器（本 app 面板 400 宽）里三项按内容宽会靠左聚成一坨、右侧空 200 多
    /// 像素。开启后每格等分、指示条居中于各自那一格；宽卡片里维持默认的跟内容宽。
    var fillsWidth: Bool = false
    @State private var hovered: Item?

    init(
        _ items: [Item],
        selection: Binding<Item>,
        fillsWidth: Bool = false,
        label: @escaping (Item) -> String
    ) {
        self.items = items
        self._selection = selection
        self.fillsWidth = fillsWidth
        self.label = label
    }

    var body: some View {
        HStack(spacing: DmSpace.s20) {
            ForEach(items, id: \.self) { item in
                let isSelected = item == selection
                Button {
                    selection = item
                } label: {
                    Text(label(item))
                        .font(.system(size: DmText.t13, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundColor(isSelected || hovered == item ? Color.dmInk : Color.dmInk2)
                        .frame(maxWidth: fillsWidth ? .infinity : nil)
                        .frame(height: DmControl.h32)
                        .overlay(alignment: .bottom) {
                            if isSelected {
                                Capsule()
                                    .fill(Color.dmAccent)
                                    .frame(width: 20, height: DmLine.bold)
                                    .padding(.bottom, DmSpace.s2)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isInside in
                    if isInside {
                        hovered = item
                    } else if hovered == item {
                        hovered = nil
                    }
                }
            }
        }
    }
}

// ============ 设计系统：自定义图标 ============

/// Lucide 线性图标（PNG template 模式）。
///
/// 名字与音频转换、视频下载的 `LucideIcon` 对齐（设计系统第八节）；加载方式
/// 保留 PNG —— 投资监控的图标资源按 `icon-*.png` 打包。size 刻意不带默认值：
/// 原先默认 `ic-14`、音频转换默认 16，同一句调用在两个 app 里画出两个尺寸。
///
/// 用法：`LucideIcon("gear", size: DmIcon.i14).foregroundColor(Color.dmInk2)`
struct LucideIcon: View {
    let name: String
    var size: CGFloat

    init(_ name: String, size: CGFloat) {
        self.name = name
        self.size = size
    }

    var body: some View {
        if let nsImage = NSImage(named: "icon-\(name)") ?? loadFromBundle("icon-\(name)") {
            Image(nsImage: nsImage)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            // fallback：找不到资源时显示占位
            Image(systemName: "questionmark")
                .font(.system(size: size * 0.7))
                .frame(width: size, height: size)
        }
    }

    private func loadFromBundle(_ name: String) -> NSImage? {
        let bundle = Bundle.main
        if let path = bundle.path(forResource: name, ofType: "png", inDirectory: "icons") {
            return NSImage(contentsOfFile: path)
        }
        if let path = bundle.path(forResource: name, ofType: "png") {
            return NSImage(contentsOfFile: path)
        }
        return nil
    }
}

// ============ 设计系统：图标按钮 ============

/// 带悬浮反馈的图标按钮：解决 nonactivatingPanel 下 .borderless/.plain 无悬浮态问题
/// 悬浮时背景变亮 + 图标颜色提亮，让用户感知可点击。
/// 取「紧凑规格」的方形版：28×28 + 图标 12 + 圆角 6。
struct IconButton: View {
    let iconName: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            LucideIcon(iconName, size: DmIcon.i12)
                .foregroundColor(isHovered && isEnabled ? Color.dmInk : Color.dmInk2)
                .frame(width: DmControl.h28, height: DmControl.h28)
                .background(
                    RoundedRectangle(cornerRadius: DmRadius.r6)
                        .fill(isHovered && isEnabled ? Color.dmPanel3 : Color.clear)
                )
        }
        .buttonStyle(.plain)
        // 禁用原样整体压暗 0.5（2026-10-09 按钮禁用定版）。当前没有禁用场景，
        // 挂在这里是防将来 `.disabled()` 时静默不变暗。
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovered = $0 }
    }
}

// ============ 设计系统：开关 ============

/// 通用开关：形态基准 42×24（2026-10-10 三端统一，与密码管理 `.switch` 同规格，
/// video 同日从系统 Toggle 换成同构自绘）。轨道 Capsule：关态 `line-2`、
/// 开态 `accent-fill`；滑块直径 20、行程 18、**两态都白**（2026-10-12 四端统一，
/// 与 video / vault / NAS 同款）、带一档贴地投影 `DmShadow.knob`。
/// 动效 `DmMotion.fast`；禁用沿用按钮口径 —— 原样整体压暗 0.5。
///
/// 投影是白滑块的主要辨识来源：深字端的开态轨道取 500 档亮色，压白的亮度对比
/// 最低只有 1.91:1（yellow-500，见 design-system.md 第八节「开关」），靠这圈暗边
/// 把滑块的轮廓从轨道上托出来。
struct DmToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            Capsule(style: .continuous)
                .fill(configuration.isOn ? Color.dmAccentFill : Color.dmLine2)
                .frame(width: 42, height: 24)
                .overlay(
                    GeometryReader { geo in
                        Circle()
                            .fill(Color.white)
                            .frame(width: 20, height: 20)
                            // 贴地投影（`DmShadow.knob`）：白滑块压在亮色轨道上靠它托出轮廓。
                            .dmShadowKnob()
                            .offset(
                                x: configuration.isOn ? geo.size.width - 22 : 2,
                                y: (geo.size.height - 20) / 2
                            )
                    }
                )
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .animation(.easeInOut(duration: DmMotion.fast), value: configuration.isOn)
    }
}

// ============ 设计系统：控件 ============

/// 主按钮：实心强调色档，取设计系统「表单规格」（高 38 / 横向内边距 16 / 圆角 8 / 字号 13）。
///
/// `--accent-fill` 管承载元素的实心块底；悬停提亮到 fill-2（`dmAccentFill2`）——
/// **invest 是唯一深字方案**：fill 与 accent 同 500 档、hover 反提 400 档，与白字方案
/// 「hover 加深」相反。禁用态**原样整体压暗到 0.5**（2026-10-09 定版，与密码管理
/// `.btn:disabled` 同一口径）：旧口径「换 panel-3 灰底」会让禁用的主按钮与一排
/// 次级按钮同灰、主次消失，压暗后它还是强调色但明显暗掉。悬停冻结。
///
/// 「下载更新」「添加」「保存」此前走系统 `.borderedProminent` + `.controlSize(.small)`，
/// 高度与描边都不受令牌管；现在四处统一走它。
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: DmText.t13, weight: .medium))
            .lineLimit(1)
            .foregroundColor(Color.dmOnAccent)
            .padding(.horizontal, DmSpace.s16)
            .frame(height: DmControl.h38)
            .background(
                RoundedRectangle(cornerRadius: DmRadius.r8)
                    .fill(fillColor)
            )
            .opacity(opacity(configuration))
            .onHover { isHovered = $0 }
    }

    private var fillColor: Color {
        if isEnabled && isHovered { return .dmAccentFill2 }
        return .dmAccentFill
    }

    /// 禁用 0.5 整体压暗；按下 0.85；两者不叠加。
    private func opacity(_ configuration: Configuration) -> Double {
        if !isEnabled { return 0.5 }
        return configuration.isPressed ? 0.85 : 1
    }
}

/// 次级按钮：panel2 底 + ink2 字，悬停提到 panel3 底 + ink 字
/// （与视频下载手写行的悬停态同一套表达：panel3 底 + ink 字）。
/// 尺寸与主按钮同取「表单规格」，只有配色不同 —— 弹窗里的「取消」用它。
/// 禁用态原样整体压暗 0.5（2026-10-09 定版，与密码管理同一口径）。
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: DmText.t13))
            .lineLimit(1)
            .foregroundColor(foreground)
            .padding(.horizontal, DmSpace.s16)
            .frame(height: DmControl.h38)
            .background(
                RoundedRectangle(cornerRadius: DmRadius.r8)
                    .fill(isEnabled && isHovered ? Color.dmPanel3 : Color.dmPanel2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DmRadius.r8)
                    .strokeBorder(Color.dmLine, lineWidth: DmLine.base)
            )
            .opacity(opacity(configuration))
            .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        if isEnabled && isHovered { return Color.dmInk }
        return Color.dmInk2
    }

    /// 禁用 0.5 整体压暗；按下 0.85；两者不叠加。
    private func opacity(_ configuration: Configuration) -> Double {
        if !isEnabled { return 0.5 }
        return configuration.isPressed ? 0.85 : 1
    }
}

/// 小号按钮：取「紧凑规格」（高 28 / 横向内边距 10 / 圆角 6 / 字号 12）。
///
/// 面板内的小动作（「立即检查」「仍要添加」「选择…」）用它，取代系统
/// `.bordered` + `.controlSize(.small)` —— 系统那档的描边与文字都不受令牌管，
/// 深色下的边框是系统灰，与 `--line` 对不上。
///
/// `on:` 按落点分档（2026-10-17）：`.panel` 实底；`.card` 描边（透明底 +
/// `line-2` 描边，悬停才填 `panel-3`）。设置卡（`SettingsCard`）是 `panel-2`，
/// 卡面上的输入件已是 `panel-3` 实底 —— 按钮也做实底就与输入框同壳，只差
/// 4px 高与 1 号字，读起来像同一控件的两种尺寸。实底＝可输入、描边＝可点。
struct CompactButtonStyle: ButtonStyle {
    /// 落点：`.panel` 主区 / 弹窗，`.card` 卡面（`SettingsCard`）。
    var on: DmSurface = .panel

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: DmText.t12))
            .lineLimit(1)
            .foregroundColor(foreground)
            .padding(.horizontal, DmSpace.s10)
            .frame(height: DmControl.h28)
            .background(
                RoundedRectangle(cornerRadius: DmRadius.r6)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DmRadius.r6)
                    .strokeBorder(on == .panel ? Color.dmLine : Color.dmLine2,
                                  lineWidth: DmLine.base)
            )
            .opacity(opacity(configuration))
            .onHover { isHovered = $0 }
    }

    private var fill: Color {
        switch on {
        case .panel: return isEnabled && isHovered ? Color.dmPanel3 : Color.dmPanel2
        case .card: return isEnabled && isHovered ? Color.dmPanel3 : Color.clear
        }
    }

    private var foreground: Color {
        if isEnabled && isHovered { return Color.dmInk }
        return Color.dmInk2
    }

    /// 禁用 0.5 整体压暗；按下 0.85；两者不叠加。
    private func opacity(_ configuration: Configuration) -> Double {
        if !isEnabled { return 0.5 }
        return configuration.isPressed ? 0.85 : 1
    }
}

// ============ 设计系统：表单组件 ============

/// 表单标签：12pt secondary + medium，与控件间距 6pt（设计系统第八节）。
/// 原先是 regular，与正文同重，标签与提示文字分不开。
/// 必填项右挂星号（写作规范 10.5）：与密码管理 .req 同形态，深色底取 danger-ink。
struct FormLabel: View {
    let text: String
    var required: Bool = false

    var body: some View {
        HStack(spacing: DmSpace.s2) {
            Text(text)
                .font(.system(size: DmText.t12, weight: .medium))
                .foregroundColor(Color.dmInk2)
                // 区块标签是单行的（「阈值」「确认天数」），挤了也宁可溢出不折行 ——
                // 折成两行的标签在表单里像出了错。
                .lineLimit(1)
            if required {
                Text("*")
                    .font(.system(size: DmText.t12, weight: .medium))
                    .foregroundColor(Color.dmDangerInk)
            }
        }
    }
}

/// 控件所在的面 ——「所在面相邻一档」取色的入参（第八节「输入框」与「卡片」）。
/// 主区（`panel`）与自绘弹窗卡片（底也是 `panel`）上的控件取 `panel-2`；嵌在
/// `panel-2` 分组卡（`SettingsCard`）里的控件抬到 `panel-3` —— 不抬的话控件底与卡面
/// 同色，只剩描边可辨。
///
/// 与 NAS 助手 `DmSurface` 同名同义（2026-10-12 收口）：此前同一件事在本 app 里有两套
/// 写法 —— 分段控件容器把 `dmPanel2` 写死（调不到 panel-3），输入框用 `rowInline: Bool`
/// 兼表「面板 + 紧凑档」两件事。现在两者都从这里取。
enum DmSurface {
    case panel
    case card

    var controlFill: Color {
        switch self {
        case .panel: return .dmPanel2
        case .card: return .dmPanel3
        }
    }
}

/// 自定义输入框：可见边框 + 聚焦高亮，解决系统默认边框不可见问题。
///
/// 取设计系统**表单规格**（高 38 / 横向内边距 12 / 字号 13 / 圆角 8），与视频下载
/// 的 `formField()`、密码管理的 `.inp` 同档 —— 横向内边距比按钮小一档：按钮的标签
/// 居中、两边要留呼吸；输入框的文字起点就是内边距，再给 16 会让文字离边太远。
///
/// 底色按 `surface` 取（「输入框取所在面相邻一档」）：2026-10-09 弹窗改自绘后卡片是
/// `panel`，相邻一档即 `panel-2` —— 与密码管理主区输入框（vault `.inp`）同款；
/// 嵌在 `panel-2` 分组卡里时传 `.card` 抬到 `panel-3`（同设置分组卡的行内控件，见
/// `SettingsView`）。边框 `dmLine2` 1px 常态 / `dmAccent2` 1px 聚焦（设计系统第八节；
/// 2026-10-09 从 `dmAccentLine` 改浅档 —— 800 深档压深底辨识度不够，与 vault `.inp:focus`、
/// 视频下载 `formField()` 同一取法。更早一版聚焦是 `dmAccent2` 1.5px，宽度不对，档位是对的）。
struct FormTextField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = nil
    /// 所在面（见 `DmSurface`）。
    var surface: DmSurface = .panel
    /// 紧凑档：高 32（设置行内嵌的控件统一方案 A）。表单档是 38。
    /// 2026-10-12 从 `rowInline` 拆出来 —— 那个参数兼表「面板 + 紧凑档」两件事，
    /// 想只改一件事的时候改不动。
    var compact: Bool = false

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: DmText.t13))
            .focused($isFocused)
            .padding(.horizontal, DmSpace.s12)
            // 高度先钉、底与描边后包：反过来的话 background/overlay 只裹住 ~16pt 的
            // 裸输入框，frame 钉的 38 成了透明命中区 —— 2026-10-09 出图实测抓到，
            // 视觉上就是用户看到的「胶囊小字段」。
            .frame(height: compact ? DmControl.h32 : DmControl.h38)
            .background(
                RoundedRectangle(cornerRadius: DmRadius.r8).fill(surface.controlFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DmRadius.r8)
                    .strokeBorder(
                        isFocused ? Color.dmAccent2 : Color.dmLine2,
                        lineWidth: DmLine.base
                    )
            )
            .frame(width: width)
    }
}

/// 表单区块：标签 + 内容垂直排列，标签到内容间距 8pt
struct FormSection<Content: View>: View {
    let label: String
    var required: Bool = false
    let content: Content

    init(_ label: String, required: Bool = false, @ViewBuilder content: () -> Content) {
        self.label = label
        self.required = required
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DmSpace.s8) {
            FormLabel(text: label, required: required)
            content
        }
    }
}

/// 内容卡片：底 `panel-2` / 圆角 12 / 描边 `line-2` 0.5px / 内边距 14（设计系统第八节）。
///
/// 原先是 `FormCard` 与 `MarketCard` 两个容器并排，只差一行 `frame(maxWidth: .infinity)`；
/// 收成一个，名字取 `FormCard`（语义更通用），实现取 `MarketCard` 那份 —— 它带
/// TupleView 保护。调用点（行情页、板块页）已并入。
///
/// TupleView 风险：content 若是多个平铺子视图，下面这组 modifier 会**逐个分发到
/// 每个子视图**上 —— 背景与描边各画一遍，一张卡片被打散成 N 个独立小卡片，行间
/// 还会多出隐式间距。先收进 spacing:0 的 VStack 再套样式，调用点怎么写都不会重演
/// （ui-selfcheck 的容器回归守着这条）。
struct FormCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity)
        .padding(DmSpace.s14)
        .background(Color.dmPanel2)
        .cornerRadius(DmRadius.r12)
        .overlay(
            RoundedRectangle(cornerRadius: DmRadius.r12)
                .stroke(Color.dmLine2, lineWidth: DmLine.hairline)
        )
    }
}

/// 设置页卡片：内容区，对齐 macOS Tahoe 系统设置列表风格（标题在卡片外）
struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        // 内容先收进 alignment:.leading、spacing:0 的 VStack：content 若是多个平铺
        // 子视图（ViewBuilder 的 TupleView），下面这组 modifier 会**逐个分发到每个
        // 子视图**上 —— 背景与描边各画一遍，一张卡片被打散成 N 个独立小卡片，行间
        // 还会多出隐式间距；alignment 不给 leading 的话，说明文字这类贴内容宽的
        // 块会被卡片居中（2026-10-09 视频下载分组卡同款问题先在这里犯过）。
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(Color.dmPanel2)
        .cornerRadius(DmRadius.r12)
        .overlay(
            RoundedRectangle(cornerRadius: DmRadius.r12)
                .stroke(Color.dmLine2, lineWidth: DmLine.hairline)
        )
    }
}

/// 自绘下拉菜单模型：一份打开的浮层（同一时刻至多一份）。
///
/// 为什么自绘：面板是 `.nonactivatingPanel`，SwiftUI `Menu`、`NSMenu.popUp`、
/// `NSPopUpButton`（performClick）三条路实测都弹不出来（2026-10-09 离屏 +
/// 真机三重证实）。浮层挂独立浮窗（`DropdownWindowController`，2026-11-20
/// 与 NAS 助手右键菜单同一方案）—— 菜单可越出面板边界，不再被容器裁切。
///
/// 视频下载虽是普通窗口（系统菜单能弹），两端保持同一实现，见那边同名组件。
@MainActor
final class DropdownModel: ObservableObject {
    struct Request {
        /// 浮窗同步层的重摆记号（开一次是一份新请求；内容不变不重摆）。
        let id = UUID()
        /// 触发器在**屏幕坐标**里的 frame（AppKit 左下原点，NSView 链路直读）。
        let anchor: CGRect
        /// 菜单卡不窄于触发器
        let minWidth: CGFloat
        let labels: [String]
        let selectedIndex: Int?
        /// 选中回调（按下标）
        let pick: (Int) -> Void
    }

    @Published var current: Request?

    func toggle(
        anchor: CGRect, minWidth: CGFloat,
        labels: [String], selectedIndex: Int?,
        pick: @escaping (Int) -> Void
    ) {
        if let cur = current, cur.anchor == anchor {
            current = nil
            return
        }
        current = Request(
            anchor: anchor, minWidth: minWidth,
            labels: labels, selectedIndex: selectedIndex, pick: pick
        )
    }

    func dismiss() {
        current = nil
    }
}

/// 菜单选择器：触发器只有「当前值 + chevrons 图标」，不画自己的底
/// （field 样式套字段壳，用于面板头部这类悬空位置）。
///
/// 系统 `.pickerStyle(.menu)` 自带 bezel —— 叠在 SettingsCard / DmModalCard
/// 上像两张卡摞放（2026-10-09 用户拍板去掉）。点开的是自绘浮层
///（`DropdownModel` + 根部 `DmDropdownOverlay`），选中有勾、悬停提亮。
struct DmMenuPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [Item]
    /// bare = 裸触发（当前零调用，仅作兜底默认）；row = 设置行内嵌 —— 标准档
    /// 32 / panel-3 底（分组卡相邻一档，2026-10-10 设置行控件统一方案 A）；
    /// field = 字段壳（面板头部悬空位置，32 / panel-2）；modal = 弹窗表单档
    /// —— 38 / panel-2 / line-2，与弹窗里的 FormTextField 同档（38 档留给
    /// 弹窗和主区表单，同日方案 A 的另一半；2026-10-10 收掉预警弹窗 4 处裸触发）。
    /// row 宽度对齐 vault `.srow-ctl`：内容自适应、下限 132 —— 2026-10-10
    /// 首版错加了行尾 Spacer，在「标签 + Spacer + 控件」的行里贪婪撑满整行。
    var style: Style = .bare

    enum Style { case bare, field, row, modal }

    struct Item {
        let value: Value
        let label: String
    }

    @EnvironmentObject private var dropdown: DropdownModel
    @State private var isHovered = false
    @State private var triggerFrame: CGRect = .zero

    /// 选项里找不到当前值时退回值的字面量（配置刚改、选项未跟上等边角）
    private var display: String {
        items.first(where: { $0.value == selection })?.label ?? String(describing: selection)
    }

    var body: some View {
        Group {
            switch style {
            case .bare:
                trigger
            case .row:
                trigger
                    .padding(.horizontal, DmSpace.s12)
                    .frame(height: DmControl.h32)
                    .frame(minWidth: 132)
                    .background(
                        RoundedRectangle(cornerRadius: DmRadius.r8).fill(Color.dmPanel3)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DmRadius.r8)
                            .strokeBorder(Color.dmLine2, lineWidth: DmLine.base)
                    )
                    // 行内不贪婪：撑满整行是 bug（见 style 注释）。fixedSize
                    // 收到内容自适应宽，外层 minWidth 132 托底（对齐 vault）。
                    .fixedSize(horizontal: true, vertical: false)
            case .field:
                trigger
                    .padding(.horizontal, DmSpace.s12)
                    .frame(height: DmControl.h32)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: DmRadius.r8).fill(Color.dmPanel2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DmRadius.r8)
                            .strokeBorder(Color.dmLine2, lineWidth: DmLine.base)
                    )
            case .modal:
                trigger
                    .padding(.horizontal, DmSpace.s12)
                    .frame(height: DmControl.h38)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: DmRadius.r8).fill(Color.dmPanel2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DmRadius.r8)
                            .strokeBorder(Color.dmLine2, lineWidth: DmLine.base)
                    )
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { open() }
        .background(DmScreenAnchorReader { triggerFrame = $0 })
    }

    private var trigger: some View {
        HStack(spacing: DmSpace.s6) {
            Text(display)
                .font(.system(size: DmText.t13))
                .foregroundColor(isHovered ? Color.dmInk : Color.dmInk2)
                .lineLimit(1)
            if style != .bare { Spacer(minLength: 0) }
            LucideIcon("chevrons-up-down", size: DmIcon.i12)
                .foregroundColor(isHovered ? Color.dmInk2 : Color.dmInk3)
        }
    }

    private func open() {
        dropdown.toggle(
            // 下限 132 与菜单卡同一值（DmDropdownOverlay.menuCard）—— 触发器
            // 盒的 minWidth 也是 132，三处一致菜单卡才与触发器严格同宽
            //（2026-10-10 用户反馈：卡比盒宽 18px 读作两个控件）。bare 触发器
            // 内容自适应可能更窄，由这个下限兜住。
            anchor: triggerFrame,
            minWidth: max(triggerFrame.width, 132),
            labels: items.map(\.label),
            selectedIndex: items.firstIndex(where: { $0.value == selection }),
            pick: { idx in
                if items.indices.contains(idx) {
                    selection = items[idx].value
                }
            }
        )
    }
}

/// 面板根部的下拉浮层同步层：开合随 `model.current` 走，菜单卡挂进独立浮窗
///（`DropdownWindowController`）。菜单不归面板装 —— 贴着面板边缘也完整可见
///（2026-11-20 与 NAS 助手右键菜单同一方案）。挂根部本身不占画面。
struct DmDropdownOverlay: View {
    @EnvironmentObject private var model: DropdownModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: model.current?.id) { _, id in
                if let id, let req = model.current {
                    DropdownWindowController.shared.show(model: model, request: req)
                } else {
                    DropdownWindowController.shared.close()
                }
            }
    }
}

/// 触发器屏幕坐标读取（AppKit 左下原点）：SwiftUI `.global` 在不同系统上
/// 口径不一（窗口相对 / 屏幕绝对都有人踩过），浮窗摆位要的是屏幕坐标，
/// 直接从 NSView 链路 `convertToScreen` 拿，不吃跨版本歧义。
struct DmScreenAnchorReader: NSViewRepresentable {
    var onFrame: (CGRect) -> Void

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onFrame = onFrame
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.onFrame = onFrame
    }

    final class AnchorView: NSView {
        var onFrame: ((CGRect) -> Void)?

        override func layout() {
            super.layout()
            guard let window, window.isVisible else { return }
            onFrame?(window.convertToScreen(convert(bounds, to: nil)))
        }
    }
}

/// 下拉菜单的独立浮窗（与 NAS 助手 `DmMenuWindowController` 同一方案）：
/// 无边框 nonactivating NSPanel、popUpMenu 层级、窗口级阴影。摆位贴触发器
/// 下缘、下方放不下朝上开、越出屏幕往里收。关闭三路：选项命中（model.dismiss
/// → 同步层收窗）、点外（监视器 → 直接收）、app 失活（通知 → 直接收）。
@MainActor
final class DropdownWindowController {
    static let shared = DropdownWindowController()

    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    func show(model: DropdownModel, request: DropdownModel.Request) {
        makePanelIfNeeded()
        guard let panel = self.panel else { return }
        let cardWidth = max(request.minWidth, 132)
        let rowHeight = DmControl.h28
        let cardHeight = CGFloat(request.labels.count) * rowHeight + DmSpace.s8

        let hosting = NSHostingView(rootView: menuContent(model, request))
        hosting.frame = NSRect(x: 0, y: 0, width: cardWidth, height: cardHeight)

        // 屏幕坐标（AppKit 左下原点）摆位：贴触发器下缘，下方放不下且上方
        // 更宽裕时朝上开（与旧容器内翻转同一判据），越出屏幕往里收。
        let a = request.anchor
        var x = a.minX
        var y = a.minY - DmSpace.s4 - cardHeight
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(a.origin) })
            ?? NSScreen.main {
            let vf = screen.visibleFrame
            let spaceBelow = a.minY - vf.minY - DmSpace.s8
            let spaceAbove = vf.maxY - a.maxY - DmSpace.s8
            if spaceBelow < cardHeight && spaceAbove > spaceBelow {
                y = a.maxY + DmSpace.s4
            }
            x = min(max(x, vf.minX + DmSpace.s8),
                    max(vf.minX + DmSpace.s8, vf.maxX - cardWidth - DmSpace.s8))
            y = min(max(y, vf.minY + DmSpace.s8),
                    max(vf.minY + DmSpace.s8, vf.maxY - cardHeight - DmSpace.s8))
        }
        panel.contentView = hosting
        panel.setFrame(NSRect(x: x, y: y, width: cardWidth, height: cardHeight),
                       display: true)
        panel.orderFront(nil)
        startWatching()
    }

    func close() {
        stopWatching()
        panel?.orderOut(nil)
    }

    private func menuContent(_ model: DropdownModel, _ req: DropdownModel.Request) -> some View {
        VStack(spacing: 0) {
            ForEach(req.labels.indices, id: \.self) { idx in
                DropdownRow(
                    label: req.labels[idx],
                    isSelected: req.selectedIndex == idx
                ) {
                    req.pick(idx)
                    model.dismiss()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: DmRadius.r10).fill(Color.dmPanel2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DmRadius.r10)
                .strokeBorder(Color.dmLine2, lineWidth: DmLine.hairline)
        )
        .dmShadowModal()
    }

    private func makePanelIfNeeded() {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        // 与面板宿窗（.popUpMenu）同层级：show 每次重新 orderFront，浮层压在宿窗之上。
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        // 卡面自带 modal 阴影在外浮窗里被边界裁掉，窗级阴影接手同一观感。
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.acceptsMouseMovedEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel = p
    }

    // MARK: 点外与失活

    private func startWatching() {
        stopWatching()
        // 点外收菜单。点在面板里放行（选项行要吃这一击）；其余本 app 窗口
        // 吞掉这一击（与旧遮罩「点哪儿都先收、不打到底下」同口径）；点在
        // 状态栏（菜单栏图标）放行，让那条链路照常走。
        if let token = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible,
                  !panel.frame.contains(NSEvent.mouseLocation) else { return event }
            MainActor.assumeIsolated { self.close() }
            return event.window?.level == .statusBar ? event : nil
        } {
            monitors.append(token)
        }
        if let token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible,
                  event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { self.close() }
            return nil
        } {
            monitors.append(token)
        }
        // app 失活（切走）就收 —— 面板浮窗不追窗走，留着反而错位。
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }

    private func stopWatching() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
    }
}

/// 下拉菜单里的选项行：勾勾槽固定宽对齐，悬停 accent-soft 底 + accent-2 字
/// （与选中四态同一配色约定）。
private struct DropdownRow: View {
    let label: String
    let isSelected: Bool
    let onPick: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DmSpace.s8) {
            Group {
                if isSelected {
                    LucideIcon("check", size: DmIcon.i12)
                        .foregroundColor(Color.dmAccent)
                } else {
                    Color.clear
                        .frame(width: DmIcon.i12, height: DmIcon.i12)
                }
            }
            Text(label)
                .font(.system(size: DmText.t13))
                .foregroundColor(isSelected ? Color.dmInk : (isHovered ? Color.dmAccent2 : Color.dmInk2))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DmSpace.s10)
        .frame(maxWidth: .infinity, minHeight: DmControl.h28)
        .background(
            isHovered ? Color.dmAccentSoft : Color.clear
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onPick() }
    }
}

/// 统一行情头部：标签 + 状态 → 大价格 → 涨跌 + 次要信息 + 行情时间
struct PriceHeader: View {
    let title: String
    let marketStatus: MarketStatus?      // nil = 不显示状态标签
    let price: String               // 格式化后的价格文本
    let changePct: Double           // 涨跌幅 %
    let secondary: String?          // 可选次要信息，如 "成交额 12.3 亿"
    /// 行情**自身**时间（f124）。区别于右上角的刷新倒计时 ——
    /// 那个说的是「下一次什么时候抓」，这个说的是「这份数是什么时候的」
    var quoteAt: Date? = nil

    var body: some View {
        VStack(spacing: DmSpace.s4) {
            // 标签行
            HStack(spacing: DmSpace.s6) {
                Text(title)
                    .font(.system(size: DmText.t13))
                    .foregroundColor(Color.dmInk2)
                if let status = marketStatus {
                    MarketStatusBadge(status: status)
                }
            }

            // 大价格
            Text(price)
                .font(.system(size: DmText.t34, weight: .bold, design: .rounded))
                .foregroundColor(Color.trend(changePct))

            // 涨跌幅 + 次要信息 + 行情时间
            HStack(spacing: DmSpace.s12) {
                Text(Format.pct(changePct))
                    .font(.system(size: DmText.t13, weight: .semibold))
                    .foregroundColor(Color.trend(changePct))
                if let sec = secondary {
                    Text(sec)
                        .font(.system(size: DmText.t12))
                        .foregroundColor(Color.dmInk2)
                }
                Spacer(minLength: DmSpace.s6)
                if let fresh = DataFreshness.display(quoteAt: quoteAt, status: marketStatus ?? .closed) {
                    Text(fresh.text)
                        .font(.system(size: DmText.t10))
                        .foregroundColor(fresh.isStale ? StatusDescriptor.delayed.color : Color.dmInk3)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 自绘模态弹窗（设计系统第八节「弹窗三段」）

/// 面板内自绘模态：遮罩黑 0.5 + 居中卡片，点遮罩关闭。
/// 取代系统 `.sheet` —— macOS 26 的 sheet 由系统玻璃外壳包一圈边（面板内实测
/// 遮罩外那圈 rgb(60~74)），与自绘卡片口径（panel 底 / line 描边 / r16 /
/// shadow-modal）是两种形态；且主面板是 400 宽的无边框 NSPanel，系统外壳的
/// 双层观感在它上面尤其突兀（2026-10-09 用户反馈「面板外侧又包了一圈」）。
struct DmModal<Modal: View>: ViewModifier {
    let isPresented: Bool
    let onDismiss: () -> Void
    @ViewBuilder let modal: () -> Modal

    func body(content: Content) -> some View {
        ZStack {
            content
            if isPresented {
                Rectangle()
                    .fill(Color.black.opacity(0.5))
                    .onTapGesture(perform: onDismiss)
                modal()
                    .padding(DmSpace.s16)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: DmMotion.fast), value: isPresented)
    }
}

extension View {
    /// 用法：`.dmModal(isPresented: onDismiss:) { 卡片内容 }`，挂在铺满窗口的
    /// 视图上（MainPanelView 根），保证遮罩盖住整个面板而不是某个区块。
    func dmModal<Modal: View>(
        isPresented: Bool,
        onDismiss: @escaping () -> Void,
        @ViewBuilder modal: @escaping () -> Modal
    ) -> some View {
        modifier(DmModal(isPresented: isPresented, onDismiss: onDismiss, modal: modal))
    }
}

/// 三段卡片：head（标题）/ body（可滚动内容）/ foot（按钮右对齐）。
/// 底 `panel`、描边 `line` 1px、圆角 r16、阴影 shadow-modal —— 与密码管理
/// `.modal` 同一套规格。宽度 368 = 主面板 400 − 两侧 16：规范里的 470 面向
/// 标准窗口，这里的宿主是菜单栏小面板，按宿主收敛（端差异，记入规范十三节）。
struct DmModalCard<Content: View, Foot: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let foot: () -> Foot

    var body: some View {
        VStack(spacing: 0) {
            // head：纵向 s16 / 横向 s20，下方 line 1px
            Text(title)
                .font(.system(size: DmText.t15, weight: .semibold))
                .foregroundColor(Color.dmInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, DmSpace.s16)
                .padding(.horizontal, DmSpace.s20)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.dmLine).frame(height: DmLine.base)
                }

            // body：s20（下方 s6），超高可滚动
            ScrollView {
                VStack(alignment: .leading, spacing: DmSpace.s12) {
                    content()
                }
                .padding(.top, DmSpace.s20)
                .padding(.bottom, DmSpace.s6)
                .padding(.horizontal, DmSpace.s20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // foot：上 s14 / 横向 s20 / 下 s16，上方 line 1px，按钮右对齐、间距 s8
            HStack(spacing: DmSpace.s8) {
                Spacer()
                foot()
            }
            .padding(.top, DmSpace.s14)
            .padding(.horizontal, DmSpace.s20)
            .padding(.bottom, DmSpace.s16)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.dmLine).frame(height: DmLine.base)
            }
        }
        .background(Color.dmPanel)
        .overlay(
            RoundedRectangle(cornerRadius: DmRadius.r16)
                .stroke(Color.dmLine, lineWidth: DmLine.base)
        )
        .clipShape(RoundedRectangle(cornerRadius: DmRadius.r16))
        .frame(width: 368)
        .fixedSize(horizontal: false, vertical: true)
        .dmShadowModal()
    }
}
