import SwiftUI
import AppKit

@main
struct InvestMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏 App：隐藏 Dock 图标
        NSApp.setActivationPolicy(.accessory)

        // 固定深色。设计令牌只有深色一套，跟着系统走会让浅色系统下的面板与原生控件
        // 落回系统灰，令牌失效 —— 与密码管理、视频下载同一策略。见 design/docs/design-system.md。
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // 请求通知授权
        AlertNotifier.shared.requestPermission()

        controller = MenuBarController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 清理
    }
}
