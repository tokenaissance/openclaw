import AppIntents
import Foundation

private enum ExternalActionKeys {
    static let startTalk = "external.pending.startTalk"
    static let agentId = "external.pending.agentId"
    static let agentMessage = "external.pending.agentMessage"
}

struct OpenClawStartTalkIntent: AppIntent {
    static var title: LocalizedStringResource { "Start Talk" }
    static var description: IntentDescription { IntentDescription("Open OpenClaw and arm Talk Mode.") }
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: ExternalActionKeys.startTalk)
        return .result()
    }
}

struct OpenClawWakeAgentIntent: AppIntent {
    static var title: LocalizedStringResource { "Wake Agent" }
    static var description: IntentDescription { IntentDescription("Open OpenClaw and select an agent.") }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Agent Id")
    var agentId: String?

    func perform() async throws -> some IntentResult {
        let trimmed = (self.agentId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            UserDefaults.standard.set(trimmed, forKey: ExternalActionKeys.agentId)
        }
        return .result()
    }
}

struct OpenClawSendMessageIntent: AppIntent {
    static var title: LocalizedStringResource { "Send Message" }
    static var description: IntentDescription {
        IntentDescription("Open OpenClaw and send a message to the gateway agent.")
    }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Message")
    var message: String

    func perform() async throws -> some IntentResult {
        let trimmed = self.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            UserDefaults.standard.set(trimmed, forKey: ExternalActionKeys.agentMessage)
        }
        return .result()
    }
}

struct OpenClawAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .blue }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenClawStartTalkIntent(),
            phrases: [
                "Start talk in \(.applicationName)",
                "\(.applicationName) start talk",
            ],
            shortTitle: "Start Talk",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: OpenClawWakeAgentIntent(),
            phrases: [
                "Wake agent in \(.applicationName)",
                "\(.applicationName) wake agent",
            ],
            shortTitle: "Wake Agent",
            systemImageName: "bolt.fill"
        )
        AppShortcut(
            intent: OpenClawSendMessageIntent(),
            phrases: [
                "Send message in \(.applicationName)",
                "\(.applicationName) send message",
            ],
            shortTitle: "Send Message",
            systemImageName: "paperplane.fill"
        )
    }
}
