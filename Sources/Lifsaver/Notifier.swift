import Foundation
import UserNotifications

/// Thin wrapper over UNUserNotificationCenter that degrades to NSLog when the
/// process has no bundle identity (bare `swift build` binary) or when the
/// user has denied notification permission.
enum Notifier {
    /// Category stamped on proactive stall alerts so clicks on them (and only
    /// them) trigger the mount flow.
    static let stalledVolumeCategory = "com.lucuma13.lifsaver.stalled-volume"

    /// The center holds its delegate weakly; keep the only strong reference.
    @MainActor private static var clickDelegate: ClickDelegate?

    /// Routes notification activation: clicking a `stalledVolumeCategory`
    /// notification invokes `onStalledClick`. Must run before the first post;
    /// no-ops without a bundle identity (the center is unusable then anyway).
    @MainActor
    static func installClickHandler(onStalledClick: @escaping @MainActor () -> Void) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let delegate = ClickDelegate(onStalledClick: onStalledClick)
        clickDelegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
    }

    static func post(title: String, body: String, category: String? = nil) {
        // UNUserNotificationCenter aborts the process when there is no bundle
        // proxy — guard for development runs outside the .app.
        guard Bundle.main.bundleIdentifier != nil else {
            NSLog("lifsaver notification: %@ — %@", title, body)
            return
        }

        Task {
            let center = UNUserNotificationCenter.current()
            // Run the authorization flow only while undetermined; afterwards
            // the recorded settings answer without re-requesting per post.
            let granted: Bool
            switch await center.notificationSettings().authorizationStatus {
            case .notDetermined:
                granted = (try? await center.requestAuthorization(options: [.alert])) ?? false
            case .authorized, .provisional:
                granted = true
            default:
                granted = false
            }
            guard granted else {
                NSLog("lifsaver notification (permission denied): %@ — %@", title, body)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let category {
                content.categoryIdentifier = category
            }
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}

private final class ClickDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let onStalledClick: @MainActor () -> Void

    init(onStalledClick: @escaping @MainActor () -> Void) {
        self.onStalledClick = onStalledClick
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard
            response.notification.request.content.categoryIdentifier == Notifier.stalledVolumeCategory,
            response.actionIdentifier == UNNotificationDefaultActionIdentifier
        else { return }
        await onStalledClick()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // An accessory app can count as "frontmost", which would swallow the
        // banner by default — show it regardless.
        .banner
    }
}
