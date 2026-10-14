import AppKit
import UserNotifications

@MainActor
final class TaskNotificationService: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((UUID, UUID) -> Void)?
    private var delivered: Set<String> = []
    private var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    override init() {
        super.init()
        if available { UNUserNotificationCenter.current().delegate = self }
    }

    func requestPermission() async throws -> Bool {
        guard available else { throw NativeAgentError.unsupported("Notifications require running the app bundle, not the command-line test executable.") }
        let center = UNUserNotificationCenter.current(); center.delegate = self
        return try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func post(id: String, title: String, conversationID: UUID, taskID: UUID, enabled: Bool, viewingActivity: Bool) async {
        guard available, enabled, !viewingActivity, delivered.insert(id).inserted else { return }
        if delivered.count > 512 { delivered = [id] }
        let center = UNUserNotificationCenter.current(); center.delegate = self
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = "Open NativeAgent to review the task."
        content.userInfo = ["conversation": conversationID.uuidString, "task": taskID.uuidString]
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let values = response.notification.request.content.userInfo
        if let chat = (values["conversation"] as? String).flatMap(UUID.init(uuidString:)), let task = (values["task"] as? String).flatMap(UUID.init(uuidString:)) {
            Task { @MainActor [weak self] in NSApp.activate(ignoringOtherApps: true); self?.onOpen?(chat, task) }
        }
        completionHandler()
    }
}
