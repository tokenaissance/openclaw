import Foundation
import OSLog
import SwiftUI
import UIKit
import UserNotifications

/// Handles APNs token registration and push tap routing for the SwiftUI app.
///
/// Note: This requires the Xcode "Push Notifications" capability + a provisioning profile
/// with the correct entitlements to actually receive APNs pushes.
final class OpenClawAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private let logger = Logger(subsystem: "ai.openclaw", category: "push")
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data)
    {
        let tokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(tokenHex, forKey: "push.apnsTokenHex")
        UserDefaults.standard.set(Int(Date().timeIntervalSince1970 * 1000), forKey: "push.apnsTokenUpdatedAtMs")
        self.logger.info("APNs token registered len=\(tokenHex.count, privacy: .public)")
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error)
    {
        self.logger.error("APNs token registration failed: \(error.localizedDescription, privacy: .public)")
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions
    {
        // Prefer showing a banner even in foreground so inbound "agent wants to talk" is visible.
        return [.banner, .sound, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async
    {
        let userInfo = response.notification.request.content.userInfo
        // Store a minimal pending action payload in defaults so the app can consume it when active.
        if let v = userInfo["openclaw_startTalk"] as? Bool, v {
            UserDefaults.standard.set(true, forKey: "external.pending.startTalk")
        }
        if let agentId = userInfo["openclaw_agentId"] as? String {
            let trimmed = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                UserDefaults.standard.set(trimmed, forKey: "external.pending.agentId")
            }
        }
        if let message = userInfo["openclaw_message"] as? String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                UserDefaults.standard.set(trimmed, forKey: "external.pending.agentMessage")
            }
        }
    }
}
