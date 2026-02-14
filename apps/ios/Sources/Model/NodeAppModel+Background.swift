import CoreLocation
import Foundation
import OpenClawKit
import SwiftUI
import UIKit
import UserNotifications

extension NodeAppModel {
    private func resolvedLocationModeFromDefaults() -> OpenClawLocationMode {
        let raw = UserDefaults.standard.string(forKey: "location.enabledMode") ?? OpenClawLocationMode.off.rawValue
        return OpenClawLocationMode(rawValue: raw) ?? .off
    }

    private func isPreciseLocationEnabledFromDefaults() -> Bool {
        // Default-on: if the key doesn't exist yet, treat it as enabled.
        if UserDefaults.standard.object(forKey: "location.preciseEnabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "location.preciseEnabled")
    }

    // MARK: Push

    func setPushEnabled(_ enabled: Bool) async {
        UserDefaults.standard.set(enabled, forKey: "push.enabled")
        guard enabled else { return }

        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [
                .alert,
                .badge,
                .sound,
            ])
            if granted {
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        } catch {
            // Best-effort only.
        }
    }

    func onAPNSTokenUpdated() async {
        await self.syncAPNSTokenToGatewayIfNeeded()
    }

    func handleRemoteNotificationUserInfo(_ userInfo: [AnyHashable: Any]) async {
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

        await self.consumePendingExternalActions()
    }

    // Called from the node websocket connect path.
    func onNodeGatewayConnected() async {
        await self.syncAPNSTokenToGatewayIfNeeded()
        await self.consumePendingExternalActions()
    }

    private func syncAPNSTokenToGatewayIfNeeded() async {
        guard UserDefaults.standard.bool(forKey: "push.enabled") else { return }
        let token = (UserDefaults.standard.string(forKey: "push.apnsTokenHex") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        let updatedAtMs = UserDefaults.standard.integer(forKey: "push.apnsTokenUpdatedAtMs")

        struct Payload: Codable {
            var token: String
            var updatedAtMs: Int?
        }
        let payload = Payload(token: token, updatedAtMs: updatedAtMs > 0 ? updatedAtMs : nil)
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8)
        else { return }
        await self.gatewaySession.sendEvent(event: "push.apnsToken", payloadJSON: json)
    }

    // MARK: Background Presence + Location

    func shouldDisconnectOnBackground() -> Bool {
        if UserDefaults.standard.object(forKey: "gateway.disconnectOnBackground") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "gateway.disconnectOnBackground")
    }

    func shouldReportLocationInBackground() -> Bool {
        guard UserDefaults.standard.bool(forKey: "location.backgroundReporting.enabled") else { return false }
        return self.resolvedLocationModeFromDefaults() == .always
    }

    func startBackgroundLocationReporting() {
        self.stopBackgroundLocationReporting()
        let desired: OpenClawLocationAccuracy = self.isPreciseLocationEnabledFromDefaults() ? .precise : .balanced
        let stream = self.locationService.startLocationUpdates(
            desiredAccuracy: desired,
            significantChangesOnly: true)
        self.backgroundLocationTask = Task { [weak self] in
            guard let self else { return }
            for await loc in stream {
                if Task.isCancelled { return }
                let nowMs = Int(Date().timeIntervalSince1970 * 1000)
                if nowMs - self.lastBackgroundLocationSentAtMs < 20_000 { continue }
                self.lastBackgroundLocationSentAtMs = nowMs
                await self.sendNodeLocationEvent(location: loc, source: "background")
            }
        }
    }

    func stopBackgroundLocationReporting() {
        self.backgroundLocationTask?.cancel()
        self.backgroundLocationTask = nil
        self.locationService.stopLocationUpdates()
    }

    func sendNodeLifecycleEvent(state: String, reason: String?) async {
        struct Payload: Codable {
            var state: String
            var reason: String?
            var tsMs: Int
        }
        let payload = Payload(
            state: state,
            reason: reason,
            tsMs: Int(Date().timeIntervalSince1970 * 1000))
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8)
        else { return }
        await self.gatewaySession.sendEvent(event: "node.lifecycle", payloadJSON: json)
    }

    func sendNodeLocationEvent(location: CLLocation, source: String) async {
        struct Payload: Codable {
            var lat: Double
            var lon: Double
            var accuracyM: Double?
            var altitudeM: Double?
            var speedMps: Double?
            var courseDeg: Double?
            var tsMs: Int
            var source: String
        }
        let payload = Payload(
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            accuracyM: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
            altitudeM: location.verticalAccuracy >= 0 ? location.altitude : nil,
            speedMps: location.speed >= 0 ? location.speed : nil,
            courseDeg: location.course >= 0 ? location.course : nil,
            tsMs: Int(location.timestamp.timeIntervalSince1970 * 1000),
            source: source)
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8)
        else { return }
        await self.gatewaySession.sendEvent(event: "node.location", payloadJSON: json)
    }

    // MARK: External Actions (Push + Siri)

    func consumePendingExternalActions() async {
        if UserDefaults.standard.bool(forKey: "external.pending.startTalk") {
            UserDefaults.standard.set(false, forKey: "external.pending.startTalk")
            await MainActor.run { self.setTalkEnabled(true) }
        }

        let agentId = (UserDefaults.standard.string(forKey: "external.pending.agentId") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !agentId.isEmpty {
            UserDefaults.standard.removeObject(forKey: "external.pending.agentId")
            await MainActor.run { self.setSelectedAgentId(agentId) }
        }

        let message = (UserDefaults.standard.string(forKey: "external.pending.agentMessage") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty {
            UserDefaults.standard.removeObject(forKey: "external.pending.agentMessage")
            let link = AgentDeepLink(
                message: message,
                sessionKey: self.mainSessionKey,
                thinking: "low",
                deliver: false,
                to: nil,
                channel: nil,
                timeoutSeconds: nil,
                key: nil)
            if let data = try? JSONEncoder().encode(link),
               let json = String(data: data, encoding: .utf8)
            {
                await self.gatewaySession.sendEvent(event: "agent.request", payloadJSON: json)
            }
        }
    }
}
