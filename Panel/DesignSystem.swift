import SwiftUI
import AppKit

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

    /// 徽章的字色取各族的**亮档**（`-ink` / `accent-2`），因为它是压在自己那族的
    /// 深色底上（见下面的 `background`）；族基色只压中性底 —— 族色压本族 soft 底
    /// 到不了 4.5:1（red-500 压 red-950 只有 4.29:1，四个族都一样）。见设计系统第三节。
    var color: Color {
        switch tone {
        case .live: return .dmAccent2
        case .warn: return .dmWarnInk
        case .quiet: return .dmInk3
        }
    }

    var background: Color {
        switch tone {
        case .live: return .dmAccentSoft
        case .warn: return .dmWarnSoft
        case .quiet: return .dmPanel
        }
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
            .background(d.background)
            .foregroundColor(d.color)
            .cornerRadius(DmRadius.r6)
    }
}

// ============ 设计系统：分段控件 ============

/// 自定义分段控件：对齐 macOS Tahoe 系统设置样式
/// 选中态 = `dmAccentSoft` 深底 + `dmAccent2` 亮字（与密码管理、视频下载同一套表达）；
/// 未选中 = 透明 + 次要色文字
/// 解决 nonactivatingPanel 下系统分段控件选中态变灰的问题
struct SegmentedTabs<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    var label: (T) -> String
    var style: Style = .default

    enum Style {
        case `default`      // 主 Tab：通栏等宽
        case compact        // 表单内：跟随内容宽度
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { idx, item in
                let selected = item == selection
                let isLast = idx == items.count - 1
                Button {
                    selection = item
                } label: {
                    Text(label(item))
                        .font(.system(size: DmText.t12, weight: selected ? .medium : .regular))
                        .foregroundColor(selected ? Color.dmAccent2 : Color.dmInk2)
                        .lineLimit(1)
                        .padding(.horizontal, style == .default ? DmSpace.s16 : DmSpace.s12)
                        .padding(.vertical, DmSpace.s6)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: DmRadius.r6)
                                .fill(Color.dmAccentSoft)
                                .opacity(selected ? 1 : 0)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: DmRadius.r6)
                .fill(Color.dmPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DmRadius.r6)
                .stroke(Color.dmLine2, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DmRadius.r6))
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

    var body: some View {
        Button(action: action) {
            LucideIcon(iconName, size: DmIcon.i12)
                .foregroundColor(isHovered ? Color.dmInk : Color.dmInk2)
                .frame(width: DmControl.h28, height: DmControl.h28)
                .background(
                    RoundedRectangle(cornerRadius: DmRadius.r6)
                        .fill(isHovered ? Color.dmPanel3 : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// ============ 设计系统：品牌开关 ============

/// 金色开关：对齐 macOS 系统开关形态（胶囊轨道 + 滑块），开启态用品牌金 + 深色滑块
struct GoldToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.toggle() }) {
            RoundedRectangle(cornerRadius: DmRadius.r10, style: .continuous)
                .fill(configuration.isOn ? Color.dmAccentFill : Color.dmPanel3)
                .frame(width: 32, height: 19)
                .overlay(
                    GeometryReader { geo in
                        Circle()
                            .fill(configuration.isOn ? Color.dmOnAccent : Color.dmInk)
                            .frame(width: 13, height: 13)
                            .offset(
                                x: configuration.isOn ? geo.size.width - 15 : 2,
                                y: (geo.size.height - 13) / 2
                            )
                    }
                )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: DmMotion.fast), value: configuration.isOn)
    }
}

// ============ 设计系统：控件 ============

/// 主按钮：实心强调色档，取设计系统「表单规格」（高 38 / 横向内边距 16 / 圆角 8 / 字号 13）。
///
/// `--accent-fill` 管承载元素的实心块底；悬停提亮到 fill-2（`dmAccentFill2`）——
/// **invest 是唯一深字方案**：fill 与 accent 同 500 档、hover 反提 400 档，与白字方案
/// 「hover 加深」相反。禁用态退中性：panel3 底 + ink3 字，悬停不再变色。
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
            .foregroundColor(isEnabled ? Color.dmOnAccent : Color.dmInk3)
            .padding(.horizontal, DmSpace.s16)
            .frame(height: DmControl.h38)
            .background(
                RoundedRectangle(cornerRadius: DmRadius.r8)
                    .fill(fillColor)
            )
            .opacity(configuration.isPressed && isEnabled ? 0.85 : 1)
            .onHover { isHovered = $0 }
    }

    private var fillColor: Color {
        if !isEnabled { return .dmPanel3 }
        return isHovered ? .dmAccentFill2 : .dmAccentFill
    }
}

/// 次级按钮：panel2 底 + ink2 字，悬停提到 panel3 底 + ink 字
/// （与视频下载手写行的悬停态同一套表达：panel3 底 + ink 字）。
/// 尺寸与主按钮同取「表单规格」，只有配色不同 —— 弹窗里的「取消」用它。
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
                    .strokeBorder(isEnabled ? Color.dmLine : Color.dmLine2, lineWidth: 1)
            )
            .opacity(configuration.isPressed && isEnabled ? 0.85 : 1)
            .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        if !isEnabled { return .dmInk3 }
        return isHovered ? Color.dmInk : Color.dmInk2
    }
}

/// 小号按钮：取「紧凑规格」（高 28 / 横向内边距 10 / 圆角 6 / 字号 12）。
///
/// 面板内的小动作（「立即检查」「仍要添加」「选择…」）用它，取代系统
/// `.bordered` + `.controlSize(.small)` —— 系统那档的描边与文字都不受令牌管，
/// 深色下的边框是系统灰，与 `--line` 对不上。
struct CompactButtonStyle: ButtonStyle {
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
                    .fill(isEnabled && isHovered ? Color.dmPanel3 : Color.dmPanel2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DmRadius.r6)
                    .strokeBorder(isEnabled ? Color.dmLine : Color.dmLine2, lineWidth: 1)
            )
            .opacity(configuration.isPressed && isEnabled ? 0.85 : 1)
            .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        if isEnabled { return isHovered ? Color.dmInk : Color.dmInk2 }
        return .dmInk3
    }
}

// ============ 设计系统：表单组件 ============

/// 表单标签：12pt secondary + medium，与控件间距 6pt（设计系统第八节）。
/// 原先是 regular，与正文同重，标签与提示文字分不开。
struct FormLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: DmText.t12, weight: .medium))
            .foregroundColor(Color.dmInk2)
    }
}

/// 自定义输入框：可见边框 + 聚焦高亮，解决系统默认边框不可见问题。
///
/// 取设计系统**表单规格**（高 38 / 横向内边距 12 / 字号 13 / 圆角 8），与视频下载
/// 的 `formField()`、密码管理的 `.inp` 同档 —— 横向内边距比按钮小一档：按钮的标签
/// 居中、两边要留呼吸；输入框的文字起点就是内边距，再给 16 会让文字离边太远。
///
/// 底色 `dmPanel3`（高亮行档，本 app 的输入框嵌在 `panel-2` 卡片里，相邻一档才分得出），
/// 边框 `dmLine2` 1px 常态 / `dmAccentLine` 1px 聚焦（设计系统第八节）。
/// 原先常态 0.5px、聚焦 `dmAccent2` 1.5px，与视频下载、密码管理两个端都不同。
struct FormTextField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: DmText.t13))
            .focused($isFocused)
            .padding(.horizontal, DmSpace.s12)
            .background(Color.dmPanel3)
            .overlay(
                RoundedRectangle(cornerRadius: DmRadius.r8)
                    .strokeBorder(
                        isFocused ? Color.dmAccentLine : Color.dmLine2,
                        lineWidth: 1
                    )
            )
            .cornerRadius(DmRadius.r8)
            .frame(height: DmControl.h38)
            .frame(width: width)
    }
}

/// 表单区块：标签 + 内容垂直排列，标签到内容间距 8pt
struct FormSection<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DmSpace.s8) {
            FormLabel(text: label)
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
                .stroke(Color.dmLine2, lineWidth: 0.5)
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
        // 内容先收进 spacing:0 的 VStack：content 若是多个平铺子视图（ViewBuilder 的
        // TupleView），下面这组 modifier 会**逐个分发到每个子视图**上 —— 背景与描边
        // 各画一遍，一张卡片被打散成 N 个独立小卡片，行间还会多出隐式间距。
        VStack(spacing: 0) {
            content
        }
        .background(Color.dmPanel2)
        .cornerRadius(DmRadius.r12)
        .overlay(
            RoundedRectangle(cornerRadius: DmRadius.r12)
                .stroke(Color.dmLine2, lineWidth: 0.5)
        )
    }
}

/// 统一行情头部：标签 + 状态 → 大价格 → 涨跌 + 次要信息 + 行情时间
struct PriceHeader: View {
    let title: String
    let marketStatus: MarketStatus?      // nil = 不显示状态标签
    let price: String               // 格式化后的价格文本
    let changePct: Double           // 涨跌幅 %
    let secondary: String?          // 可选次要信息，如 "成交额 12.3亿"
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
