import Foundation
import AppKit
import UserNotifications

/// 本地通知发送器
/// 优先使用 UserNotifications.framework；若 UN 通知无法显示（如 adhoc 签名开发阶段），
/// 自动回退到 osascript display notification 确保通知可见。
final class AlertNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = AlertNotifier()

    /// 系统通知权限被用户关掉了。预警只能靠系统通知送达，
    /// 关掉之后界面必须说出来 —— 否则用户以为规则坏了，实际一条都发不出去。
    @Published var authorizationDenied = false

    /// 通知点击回调：传递规则 ID
    var onNotificationTap: ((String) -> Void)?

    /// UN 通知是否可用（授权通过且能弹 banner）
    /// 首次发通知后通过 getDeliveredNotifications 验证
    private var unAvailable: Bool?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        refreshAuthorization()
    }

    /// 读当前授权状态。用户可能在系统设置里改过，回前台时再读一次。
    func refreshAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.authorizationDenied = (settings.authorizationStatus == .denied)
            }
        }
    }

    /// 请求通知授权（alert + sound）
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            self.refreshAuthorization()
            if granted {
                // 授权后发一条静默测试通知，检查是否真的能弹 banner
                self.checkUNAvailability()
            }
        }
    }

    /// 检查 UNUserNotificationCenter 是否真的能弹 banner
    /// 发一条测试通知，3 秒后检查 deliveredNotifications，有记录则说明可用
    private func checkUNAvailability() {
        let testContent = UNMutableNotificationContent()
        testContent.title = ""
        testContent.body = ""
        testContent.sound = nil
        let req = UNNotificationRequest(
            identifier: "un-availability-check",
            content: testContent,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        UNUserNotificationCenter.current().add(req) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
                    let found = notifications.contains { $0.request.identifier == "un-availability-check" }
                    self.unAvailable = found
                    if found {
                        // 清除测试通知
                        UNUserNotificationCenter.current().removeDeliveredNotifications(
                            withIdentifiers: ["un-availability-check"]
                        )
                    }
                }
            }
        }
    }

    /// 发送预警通知。标题与正文由 `AlertNotice` 成型（带天数、判定价、同时命中）
    func sendNotification(_ notice: AlertNotice) {
        let title = notice.title
        let body = notice.body

        // 先尝试 UNUserNotificationCenter
        if unAvailable != false {
            sendViaUN(notice: notice, title: title, body: body)
        }

        // 如果 UN 确认不可用，或作为双保险，同时用 osascript
        if unAvailable == false {
            sendViaOSA(title: title, body: body)
        }

        // 首次发送：UN 状态未知时双发（UN + osascript），确保用户一定能看到
        if unAvailable == nil {
            sendViaOSA(title: title, body: body)
        }
    }

    /// 通过 UNUserNotificationCenter 发送
    ///
    /// identifier 带**判定价日**：同一线同一判定价日只推一次，不同日期各自留痕。
    /// 直接用 `rule.id` 的后果是新通知顶掉旧的，通知中心倒推不出历史。
    private func sendViaUN(notice: AlertNotice, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // 点击回跳要的规则 ID 走 userInfo —— identifier 带了日期后缀，不能再当 ID 用
        content.userInfo = ["ruleId": notice.rule.id]

        let request = UNNotificationRequest(
            identifier: "\(notice.rule.id)-\(notice.pdate)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("UN 通知发送失败: \(error.localizedDescription)")
            }
        }
    }

    /// 通过 osascript 发送（fallback）
    private func sendViaOSA(title: String, body: String) {
        // 转义双引号
        let escTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(escBody)\" with title \"\(escTitle)\" sound name \"default\""
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // 始终显示通知，即使 App 在前台
        completionHandler([.banner, .sound])
    }

    /// 用户点击通知时调用：提取规则 ID，回调打开面板并切换到对应 Tab
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // identifier 是「rule.id-pdate」，规则 ID 从 userInfo 取（UUID 本身也含 "-"，不能拆字符串）
        let ruleId = response.notification.request.content.userInfo["ruleId"] as? String
            ?? response.notification.request.identifier
        onNotificationTap?(ruleId)
        completionHandler()
    }
}
