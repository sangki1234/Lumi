//
//  AppState.swift
//  LumiAgent
//
//  Shared application state observable object.
//  macOS-only methods live in AppState+macOS.swift.
//

import SwiftUI
import Combine
import Foundation
#if os(macOS)
import AppKit
import Carbon.HIToolbox
import ApplicationServices
#endif

// MARK: - Screen Control Tool Names
// Tool names that imply active desktop control.
private let screenControlToolNames: Set<String> = [
    "open_application", "click_mouse", "scroll_mouse",
    "type_text", "press_key"
]

#if os(iOS)
typealias IOSRemoteMacCommandExecutor = (
    _ commandType: String,
    _ parameters: [String: String],
    _ timeout: TimeInterval
) async throws -> IOSRemoteResponse
#endif

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    static weak var shared: AppState?

    // MARK: - Sidebar / Navigation
    @Published var selectedSidebarItem: SidebarItem = .agents
    @Published var selectedAgentId: UUID?
    @Published var agents: [Agent] = []
    @Published var showingNewAgent = false

    // MARK: - Persistent Default Agent
    @AppStorage("settings.defaultExteriorAgentId") private var defaultAgentIdString = ""

    var defaultExteriorAgentId: UUID? {
        get { UUID(uuidString: defaultAgentIdString) }
        set { defaultAgentIdString = newValue?.uuidString ?? "" }
    }

    func isDefaultAgent(_ id: UUID) -> Bool {
        defaultExteriorAgentId == id
    }

    func setDefaultAgent(_ id: UUID?) {
        defaultExteriorAgentId = id
    }

    // MARK: - Agent Space
    @Published var conversations: [Conversation] = [] {
        didSet { saveConversations() }
    }
    @Published var selectedConversationId: UUID?
    @AppStorage("settings.hotkeyConversationId") var hotkeyConversationIdString = ""

    // MARK: - Tool Call History
    @Published var toolCallHistory: [ToolCallRecord] = []
    @Published var selectedHistoryAgentId: UUID?

    // MARK: - Browser Workspace
    @Published var selectedBrowserConversationId: UUID?

    // MARK: - Automations
    @Published var automations: [AutomationRule] = [] {
        didSet { saveAutomations() }
    }
    @Published var selectedAutomationId: UUID?

    // MARK: - Settings Navigation
    @Published var selectedSettingsSection: String? = "apiKeys"
    @Published var selectedDeviceId: UUID?

    // MARK: - Health
    @Published var selectedHealthCategory: HealthCategory? = .activity
    @Published var lastSyncedAt: [String: Date] = [:]

    // MARK: - Screen Control State
    @Published var isAgentControllingScreen = false
    private var screenControlCount = 0
    var screenControlTasks: [Task<Void, Never>] = []
    private var responseTasksByConversation: [UUID: [UUID: Task<Void, Never>]] = [:]
    private var hotkeyRefreshObserver: NSObjectProtocol?
    @AppStorage("settings.enableGlobalHotkeys") var enableGlobalHotkeys = true

    // MARK: - Private Storage
    private let conversationsFileName = "conversations.json"
    private let automationsFileName   = "automations.json"
    private let browserWorkspaceConversationPrefix = "[Browser Workspace]"

    #if os(macOS)
    var automationEngine: AutomationEngine?
    let remoteServer = MacRemoteServer.shared
    private let usbObserver = USBDeviceObserver.shared
    @Published var isUSBDeviceConnected: Bool = false
    #elseif os(iOS)
    @Published private(set) var isRemoteMacConnected: Bool = false
    private var remoteMacCommandExecutor: IOSRemoteMacCommandExecutor?
    private var suppressLocalDataChangeNotifications = false
    #endif

    // MARK: - Init

    init() {
        Self.shared = self
        _ = DatabaseManager.shared
        
        loadAgents()
        loadConversations()
        loadAutomations()

        NotificationCenter.default.addObserver(
            forName: Notification.Name("lumi.dataRemoteUpdated"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.loadAgents()
                self?.loadConversations()
                self?.loadAutomations()
            }
        }
        
        #if os(macOS)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.setupGlobalHotkey()
            self.startAutomationEngine()
            
            self.usbObserver.onDeviceConnected = {
                print("[AppState] iPhone/iPad detected via USB. Ready for sync.")
                Task { @MainActor in
                    self.isUSBDeviceConnected = true
                }
            }
            self.usbObserver.onDeviceDisconnected = {
                print("[AppState] iPhone/iPad disconnected from USB.")
                Task { @MainActor in
                    self.isUSBDeviceConnected = false
                }
            }
            self.usbObserver.start()
            
            self.hotkeyRefreshObserver = NotificationCenter.default.addObserver(
                forName: .lumiGlobalHotkeysPreferenceChanged,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    AppState.shared?.refreshGlobalHotkeys()
                }
            }

        }
        #endif
    }

    #if os(iOS)
    func setRemoteMacBridge(
        isConnected: Bool,
        executor: IOSRemoteMacCommandExecutor?
    ) {
        isRemoteMacConnected = isConnected
        remoteMacCommandExecutor = executor
    }
    #endif

    // MARK: - Command Palette Message (Shared)

    func sendCommandPaletteMessage(text: String, agentId: UUID?) {
        let targetId = agentId ?? defaultExteriorAgentId ?? agents.first?.id
        guard let targetId, agents.contains(where: { $0.id == targetId }) else { return }

        let conv = createDM(agentId: targetId)
        sendMessage(text, in: conv.id, agentMode: true)

        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        #endif
    }

    // MARK: - Automation Management

    func createAutomation() {
        let rule = AutomationRule(agentId: agents.first?.id)
        automations.insert(rule, at: 0)
        selectedAutomationId = rule.id
    }

    func runAutomation(id: UUID) {
        guard let rule = automations.first(where: { $0.id == id }) else { return }
        #if os(macOS)
        automationEngine?.runManually(rule)
        #endif
    }

    func fireAutomation(_ rule: AutomationRule) {
        guard rule.isEnabled, let agentId = rule.agentId else { return }
        let prompt = rule.notes.isEmpty
            ? "Execute the automation titled: \"\(rule.title)\""
            : "Execute this automation task:\n\n\(rule.notes)"
        sendCommandPaletteMessage(text: prompt, agentId: agentId)
        if let idx = automations.firstIndex(where: { $0.id == rule.id }) {
            automations[idx].lastRunAt = Date()
        }
    }

    private func loadAutomations() {
        // Try migration from legacy UserDefaults if file doesn't exist
        do {
            let db = DatabaseManager.shared
            #if os(iOS)
            suppressLocalDataChangeNotifications = true
            defer { suppressLocalDataChangeNotifications = false }
            #endif
            
            let collection = try db.load(SyncCollection<AutomationRule>.self, from: automationsFileName, default: {
                // Migration: Check for old array format in file
                if let oldArray = try? db.load([AutomationRule].self, from: automationsFileName, default: []) {
                    return SyncCollection(items: oldArray)
                }
                // Migration: Check for legacy UserDefaults
                if let legacyData = UserDefaults.standard.data(forKey: "lumiagent.automations"),
                   let legacy = try? JSONDecoder().decode([AutomationRule].self, from: legacyData) {
                    return SyncCollection(items: legacy)
                }
                return SyncCollection(items: [])
            }())
            automations = collection.items
        } catch {
            print("Error loading automations: \(error)")
        }
    }

    private func saveAutomations() {
        let collection = SyncCollection(items: automations)
        try? DatabaseManager.shared.save(collection, to: automationsFileName)
        #if os(iOS)
        guard !suppressLocalDataChangeNotifications else { return }
        NotificationCenter.default.post(
            name: Notification.Name("lumi.localDataChanged"),
            object: automationsFileName
        )
        #endif
    }

    // MARK: - Tool Call History

    func recordToolCall(agentId: UUID, agentName: String, toolName: String,
                        arguments: [String: String], result: String) {
        let success = !result.hasPrefix("Error:") && !result.hasPrefix("Tool not found:")
        toolCallHistory.insert(
            ToolCallRecord(agentId: agentId, agentName: agentName, toolName: toolName,
                           arguments: arguments, result: result, success: success),
            at: 0
        )
    }

    // MARK: - Screen Control

    func stopAgentControl() {
        screenControlTasks.forEach { $0.cancel() }
        screenControlTasks.removeAll()
        screenControlCount = 0
        isAgentControllingScreen = false
    }

    func isConversationResponding(_ conversationId: UUID) -> Bool {
        if let tasks = responseTasksByConversation[conversationId], !tasks.isEmpty {
            return true
        }
        return conversations
            .first(where: { $0.id == conversationId })?
            .messages.contains(where: \.isStreaming) == true
    }

    func stopResponse(in conversationId: UUID) {
        if let tasks = responseTasksByConversation[conversationId] {
            tasks.values.forEach { $0.cancel() }
            responseTasksByConversation.removeValue(forKey: conversationId)
        }

        if let ci = conversations.firstIndex(where: { $0.id == conversationId }) {
            var changed = false
            for i in conversations[ci].messages.indices where conversations[ci].messages[i].isStreaming {
                conversations[ci].messages[i].isStreaming = false
                if conversations[ci].messages[i].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    conversations[ci].messages[i].content = "Stopped."
                }
                changed = true
            }
            if changed {
                conversations[ci].updatedAt = Date()
            }
        }
    }

    // MARK: - Agent Persistence

    private func loadAgents() {
        Task {
            let repo = AgentRepository()
            do {
                self.agents = try await repo.getAll()
            } catch {
                print("Error loading agents: \(error)")
            }
        }
    }

    func updateAgent(_ agent: Agent) {
        if let index = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[index] = agent
        }
        Task {
            let repo = AgentRepository()
            try? await repo.update(agent)
            #if os(iOS)
            NotificationCenter.default.post(
                name: Notification.Name("lumi.localDataChanged"),
                object: "agents.json"
            )
            #endif
        }
    }

    func deleteAgent(id: UUID) {
        agents.removeAll { $0.id == id }
        if selectedAgentId == id { selectedAgentId = nil }
        Task {
            let repo = AgentRepository()
            try? await repo.delete(id: id)
            #if os(iOS)
            NotificationCenter.default.post(
                name: Notification.Name("lumi.localDataChanged"),
                object: "agents.json"
            )
            #endif
        }
    }

    func applySelfUpdate(_ args: [String: String], agentId: UUID) -> String {
        guard let idx = agents.firstIndex(where: { $0.id == agentId }) else {
            return "Error: agent not found."
        }
        var updated = agents[idx]
        var changes: [String] = []

        if let name = args["name"], !name.isEmpty {
            updated.name = name
            changes.append("name → \"\(name)\"")
        }
        if let prompt = args["system_prompt"] {
            updated.configuration.systemPrompt = prompt.isEmpty ? nil : prompt
            changes.append("system prompt updated")
        }
        if let model = args["model"], !model.isEmpty {
            updated.configuration.model = model
            changes.append("model → \(model)")
        }
        if let tempStr = args["temperature"], let temp = Double(tempStr) {
            updated.configuration.temperature = max(0, min(2, temp))
            changes.append("temperature → \(temp)")
        }

        guard !changes.isEmpty else { return "No changes requested." }
        updated.updatedAt = Date()
        updateAgent(updated)
        return "Configuration updated: \(changes.joined(separator: ", "))."
    }

    // MARK: - Conversation Management

    private func loadConversations() {
        do {
            let db = DatabaseManager.shared
            #if os(iOS)
            suppressLocalDataChangeNotifications = true
            defer { suppressLocalDataChangeNotifications = false }
            #endif
            
            let collection = try db.load(SyncCollection<Conversation>.self, from: conversationsFileName, default: {
                // Migration: Check for old array format in file
                if let oldArray = try? db.load([Conversation].self, from: conversationsFileName, default: []) {
                    return SyncCollection(items: oldArray)
                }
                // Migration: Check for legacy UserDefaults
                if let legacyData = UserDefaults.standard.data(forKey: "lumiagent.conversations"),
                   let legacy = try? JSONDecoder().decode([Conversation].self, from: legacyData) {
                    return SyncCollection(items: legacy)
                }
                return SyncCollection(items: [])
            }())
            conversations = collection.items
        } catch {
            print("Error loading conversations: \(error)")
        }
    }

    private func saveConversations() {
        let collection = SyncCollection(items: conversations)
        try? DatabaseManager.shared.save(collection, to: conversationsFileName)
        #if os(iOS)
        guard !suppressLocalDataChangeNotifications else { return }
        NotificationCenter.default.post(
            name: Notification.Name("lumi.localDataChanged"),
            object: conversationsFileName
        )
        #endif
    }

    @discardableResult
    func createDM(agentId: UUID) -> Conversation {
        if let existing = conversations.first(where: { !$0.isGroup && $0.participantIds == [agentId] }) {
            selectedConversationId = existing.id
            selectedSidebarItem = .agentSpace
            return existing
        }
        let conv = Conversation(participantIds: [agentId])
        conversations.insert(conv, at: 0)
        saveConversations()
        selectedConversationId = conv.id
        selectedSidebarItem = .agentSpace
        return conv
    }

    @discardableResult
    func createGroup(agentIds: [UUID], title: String?) -> Conversation {
        let conv = Conversation(title: title, participantIds: agentIds)
        conversations.insert(conv, at: 0)
        saveConversations()
        selectedConversationId = conv.id
        selectedSidebarItem = .agentSpace
        return conv
    }

    func isBrowserWorkspaceConversation(_ conv: Conversation) -> Bool {
        (conv.title ?? "").hasPrefix(browserWorkspaceConversationPrefix)
    }

    func browserWorkspaceTitle(for conv: Conversation, agents: [Agent]? = nil) -> String {
        let raw = conv.title ?? ""
        let trimmed = raw.replacingOccurrences(of: browserWorkspaceConversationPrefix, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let sourceAgents = agents ?? self.agents
        if let firstId = conv.participantIds.first,
           let agent = sourceAgents.first(where: { $0.id == firstId }) {
            return agent.name
        }
        return "Browser Tab"
    }

    func browserWorkspaceConversations() -> [Conversation] {
        conversations
            .filter(isBrowserWorkspaceConversation)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    func createBrowserWorkspaceConversation(
        agentId: UUID,
        title: String? = nil,
        select: Bool = true,
        copyFrom sourceConversationId: UUID? = nil
    ) -> Conversation? {
        guard agents.contains(where: { $0.id == agentId }) else { return nil }
        let baseTitle = title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = (baseTitle?.isEmpty == false)
            ? baseTitle!
            : (agents.first(where: { $0.id == agentId })?.name ?? "Browser Tab")

        let copiedMessages: [SpaceMessage]
        if let sourceConversationId,
           let source = conversations.first(where: { $0.id == sourceConversationId }) {
            copiedMessages = source.messages
                .filter { !$0.isStreaming }
                .map { msg in
                    SpaceMessage(
                        role: msg.role,
                        content: msg.content,
                        agentId: msg.agentId,
                        timestamp: msg.timestamp,
                        isStreaming: false,
                        imageData: msg.imageData
                    )
                }
        } else {
            copiedMessages = []
        }

        let conv = Conversation(
            title: "\(browserWorkspaceConversationPrefix) \(effectiveTitle)",
            participantIds: [agentId],
            messages: copiedMessages
        )
        conversations.insert(conv, at: 0)
        saveConversations()
        if select {
            selectedBrowserConversationId = conv.id
            selectedSidebarItem = .browser
        }
        return conv
    }

    func deleteBrowserWorkspaceConversation(id: UUID) {
        stopResponse(in: id)
        conversations.removeAll { $0.id == id }
        if selectedBrowserConversationId == id {
            selectedBrowserConversationId = browserWorkspaceConversations().first?.id
        }
        saveConversations()
    }

    func deleteConversation(id: UUID) {
        stopResponse(in: id)
        conversations.removeAll { $0.id == id }
        if selectedConversationId == id { selectedConversationId = nil }
        saveConversations()
    }

    // MARK: - Messaging

    func sendMessage(_ text: String, in conversationId: UUID, agentMode: Bool = false, desktopControlEnabled: Bool = false) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationId }) else { return }

        let userMsg = SpaceMessage(role: .user, content: text)
        conversations[index].messages.append(userMsg)
        conversations[index].updatedAt = Date()

        let conv = conversations[index]
        let participants = agents.filter { conv.participantIds.contains($0.id) }

        let mentioned = participants.filter { text.contains("@\($0.name)") }
        let targets: [Agent] = mentioned.isEmpty ? participants : mentioned

        let runID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    var tasks = self.responseTasksByConversation[conversationId] ?? [:]
                    tasks.removeValue(forKey: runID)
                    if tasks.isEmpty {
                        self.responseTasksByConversation.removeValue(forKey: conversationId)
                    } else {
                        self.responseTasksByConversation[conversationId] = tasks
                    }
                }
            }
            for agent in targets {
                guard !Task.isCancelled else { break }
                let freshHistory = conversations
                    .first(where: { $0.id == conversationId })?
                    .messages.filter { !$0.isStreaming } ?? []
                await streamResponse(from: agent, in: conversationId,
                                     history: freshHistory, agentMode: agentMode,
                                     desktopControlEnabled: desktopControlEnabled)
            }
        }
        var tasks = responseTasksByConversation[conversationId] ?? [:]
        tasks[runID] = task
        responseTasksByConversation[conversationId] = tasks
        screenControlTasks.append(task)
    }

    func streamResponse(
        from agent: Agent,
        in conversationId: UUID,
        history: [SpaceMessage],
        agentMode: Bool = false,
        desktopControlEnabled: Bool = false,
        delegationDepth: Int = 0,
        toolNameAllowlist: Set<String>? = nil
    ) async {
        guard let index = conversations.firstIndex(where: { $0.id == conversationId }) else { return }

        var didRaiseScreenControl = false
        defer {
            if didRaiseScreenControl {
                screenControlCount = max(0, screenControlCount - 1)
                if screenControlCount == 0 {
                    isAgentControllingScreen = false
                    screenControlTasks.removeAll { $0.isCancelled }
                }
            }
        }

        let placeholderId = UUID()
        conversations[index].messages.append(SpaceMessage(
            id: placeholderId, role: .agent, content: "",
            agentId: agent.id, isStreaming: true
        ))

        let convParticipants = agents.filter { conversations[index].participantIds.contains($0.id) }
        let isGroup = convParticipants.count > 1
        let isBrowserWorkspaceSession = isBrowserWorkspaceConversation(conversations[index])
        var aiMessages: [AIMessage] = history.compactMap { msg in
            if msg.role == .user {
                return AIMessage(role: .user, content: msg.content, imageData: msg.imageData)
            } else if let senderId = msg.agentId {
                if senderId == agent.id {
                    return AIMessage(role: .assistant, content: msg.content)
                } else if isGroup {
                    let senderName = agents.first { $0.id == senderId }?.name ?? "Agent"
                    return AIMessage(role: .user, content: "[\(senderName)]: \(msg.content)")
                }
            }
            return nil
        }

        let repo = AIProviderRepository()
        var tools: [AITool]
        #if os(macOS)
        if agentMode {
            if desktopControlEnabled {
                tools = ToolRegistry.shared.getToolsForAI()
            } else {
                tools = ToolRegistry.shared.getToolsForAIWithoutDesktopControl()
            }
        } else {
            tools = ToolRegistry.shared.getToolsForAI(enabledNames: agent.configuration.enabledTools)
        }
        if !tools.contains(where: { $0.name == "update_self" }),
           let selfTool = ToolRegistry.shared.getTool(named: "update_self") {
            tools.append(selfTool.toAITool())
        }
        #else
        if isRemoteMacConnected {
            tools = iOSRemoteMacTools(enabledNames: agent.configuration.enabledTools)
        } else {
            tools = []
        }
        #endif
        if let allowlist = toolNameAllowlist {
            tools = tools.filter { allowlist.contains($0.name) }
        }
        if isBrowserWorkspaceSession {
            let browserPriority: [String: Int] = [
                "assign_browser_tile": 0,
                "navigate_browser_tile": 1,
                "get_browser_tile_state": 2,
                "read_browser_tile_page": 3,
                "browser_tile_click": 4,
                "browser_tile_type": 5,
                "browser_tile_press_key": 6,
                "capture_agent_screen": 7,
                "reload_browser_tile": 8,
                "browser_tile_back": 9,
                "browser_tile_forward": 10,
                "list_browser_tiles": 11,
                "release_browser_tile": 12
            ]
            tools = tools.sorted { lhs, rhs in
                let l = browserPriority[lhs.name] ?? 10_000
                let r = browserPriority[rhs.name] ?? 10_000
                if l != r { return l < r }
                return lhs.name < rhs.name
            }
        }

        let effectiveSystemPrompt: String? = {
            var parts: [String] = []
            #if os(iOS)
            if isRemoteMacConnected {
                parts.append("""
                Runtime context:
                • You are running in the iPhone app.
                • A remote Mac is currently connected and controllable through the provided tools.
                • Use only the tool list available in this request for Mac actions.
                """)
            } else {
                parts.append("""
                Runtime context:
                • You are running in the iPhone app.
                • No remote Mac is connected right now.
                • Do not claim desktop/macOS control and do not reference unavailable machines.
                """)
            }
            #else
            parts.append("Runtime context: You are running directly on the macOS host.")
            #endif
            if agentMode {
                let modeDescription = desktopControlEnabled
                    ? "You have FULL autonomous control of the user's Mac — file system, web, shell, apps, and screen."
                    : "You have access to file system, web, shell, AppleScript, and screenshots. Desktop control (mouse, keyboard, app launching) is DISABLED."

                parts.append("""
                You are in Agent Mode. \(modeDescription)

                ═══ AUTONOMOUS EXECUTION PROTOCOL (STRICT) ═══
                Goal: fully complete the user's request end-to-end without redundant follow-up questions.

                OPERATING LOOP:
                  1. Infer intent and the final deliverable.
                  2. Execute the next best tool call immediately.
                  3. Chain tool results into the next action.
                  4. Continue until completion, then send a concise final result.

                QUESTION POLICY:
                  • DO NOT ask for confirmation for routine, reversible actions needed to complete the request.
                  • DO NOT ask "what next?" after partial progress.
                  • Ask the user only when truly blocked by missing required information that cannot be inferred:
                    - Missing secret/credential that is required right now
                    - Ambiguous high-impact target (multiple risky interpretations)
                    - Irreversible/destructive action not explicitly requested
                  • If blocked, ask ONE concise question only.

                EXAMPLE — "search for X, then write a report on the Desktop":
                  Step 1 → call web_search("X")
                  Step 2 → call web_search again for more detail if needed
                  Step 3 → call write_file(path: "/Users/<user>/Desktop/report.txt", content: <full report>)
                  Step 4 → respond: "Done — report saved to your Desktop."

                EXAMPLE — "open a page in Browser Workspace":
                  Step 1 → call assign_browser_tile(agentId: "<your agent UUID>")
                  Step 2 → call navigate_browser_tile(agentId: "<your agent UUID>", url: "https://apple.com")
                  Step 3 → respond with result.

                FAILURE RECOVERY:
                  • If a step fails, try at least 2 different automated approaches before asking the user.
                  • Never hand the task back to the user for manual clicking/typing unless all automated paths fail.

                ═══ TOOL SELECTION GUIDE ═══

                FILE & DOCUMENT TOOLS:
                • Files on disk         → write_file, read_file, list_directory, create_directory, search_files, append_to_file
                • File metadata         → get_file_info (size, created/modified dates, type, permissions)
                • File safety           → move_to_trash (recoverable delete), delete_file (permanent), move_file, copy_file
                • PDF documents         → read_pdf (extracts page-by-page text via PDFKit)
                • Word documents        → read_word (supports .doc, .docx, .rtf, .odt via textutil)
                • PowerPoint files      → read_ppt (extracts slide-by-slide text from .pptx/.ppt)
                • Any document          → read_document (auto-detects format: PDF, Word, PPT, text, code, etc.)
                • Unknown/binary files  → read_document first (reports metadata for unreadable formats), then get_file_info
                • Disk space            → analyze_disk_space (volume usage + largest items in a directory)
                • Archives              → create_archive (zip files), extract_archive (zip/tar/gz/bz2/xz)
                • File search           → search_files (regex in directory), spotlight_search (system-wide Spotlight/mdfind)
                • File hashing          → hash_file (MD5, SHA-1, SHA-256, SHA-512 checksums)
                • Quick Look            → preview_file (visual preview of any file type)

                SYSTEM & AUTOMATION:
                • Shell / automation    → execute_command, run_applescript
                • Open apps / URLs      → open_application, open_url
                • System info           → get_system_info, get_current_datetime, list_processes, get_user_info
                • Battery               → get_battery_info (charge level, power source, time remaining)

                WINDOW MANAGEMENT:
                • List windows          → list_windows (all visible windows with positions/sizes)
                • Focus window          → focus_window (bring to front by app name + optional title)
                • Resize/move window    → resize_window (set position and/or size)
                • Close window          → close_window (close frontmost window of an app)
                • Running apps          → list_running_apps (GUI apps only), get_frontmost_app
                • Quit apps             → quit_application (graceful quit)
                • App menus             → list_menu_items (discover menu bar actions for automation)

                RESEARCH & NETWORK:
                • Research / web data   → web_search, fetch_url, http_request
                • Wi-Fi info            → get_wifi_info (SSID, signal, channel)
                • Network details       → get_network_interfaces (IPs, external IP, DNS)
                • Connectivity check    → ping_host (latency test)

                BROWSER WORKSPACE (NATIVE EMBEDDED BROWSER):
                • Assign tile            → assign_browser_tile
                • Open/navigate URL      → navigate_browser_tile
                • Read current page      → read_browser_tile_page, get_browser_tile_state
                • Virtual mouse + input  → browser_tile_click, browser_tile_type, browser_tile_press_key
                • Visual verification    → capture_agent_screen
                • History & refresh      → browser_tile_back, browser_tile_forward, reload_browser_tile
                • Tile management        → list_browser_tiles, release_browser_tile

                SCREEN & UI CONTROL:
                • Screen interaction    → get_screen_info, click_mouse, type_text, press_key, take_screenshot, scroll_mouse, move_mouse
                • iWork documents       → iwork_get_document_info, iwork_write_text, iwork_replace_text, iwork_insert_after_anchor

                APPEARANCE:
                • Dark/Light mode       → get_appearance, set_dark_mode
                • Brightness            → get_brightness, set_brightness
                • Wallpaper             → set_wallpaper (change desktop background)

                MEDIA & DEVICES:
                • Volume / audio        → get_volume, set_volume, set_mute, list_audio_devices, set_audio_output
                • Media playback        → media_control (play, pause, next, previous, stop)
                • Bluetooth             → bluetooth_list_devices, bluetooth_connect, bluetooth_scan

                NOTIFICATIONS & TIMERS:
                • Notifications         → send_notification (macOS banner notification)
                • Timers                → set_timer (delayed notification, runs in background)

                SPEECH:
                • Text-to-speech        → speak_text (read text aloud), list_voices (available voices)

                CALENDAR & REMINDERS:
                • Calendar events       → get_calendar_events (upcoming events), create_calendar_event
                • Reminders             → get_reminders, create_reminder

                IMAGES:
                • Image info            → get_image_info (dimensions, format, DPI, color space)
                • Resize images         → resize_image (change dimensions via sips)
                • Convert images        → convert_image (png/jpeg/tiff/bmp/gif/pdf)

                DATA & CODE:
                • Code execution        → run_python, run_node, calculate
                • Text processing       → search_in_file, replace_in_file, count_lines
                • Data encoding         → parse_json, encode_base64, decode_base64
                • Clipboard             → read_clipboard, write_clipboard

                MEMORY:
                • Memory across turns   → memory_save, memory_read, memory_list, memory_delete

                GIT:
                • Git operations        → git_status, git_log, git_diff, git_commit, git_branch, git_clone

                ═══ WHEN SOMETHING ISN'T FOUND ═══
                When a file, application, process, or resource isn't found on the first attempt, DO NOT give up immediately.
                Instead, explore further:
                  1. FILE NOT FOUND: Try search_files with broader patterns. Check common locations (~, ~/Desktop, ~/Documents,
                     ~/Downloads, /Applications). Try list_directory on parent paths. Use execute_command("find / -name '...' -maxdepth 5 2>/dev/null") as a last resort.
                  2. APP NOT FOUND: Try open_application with variations of the name. Use list_directory("/Applications") or
                     execute_command("mdfind 'kMDItemContentType == com.apple.application-bundle' -name '<name>'") to search.
                  3. PROCESS/SERVICE NOT RUNNING: Check with list_processes. Try execute_command("pgrep -l <name>") or
                     execute_command("lsof -i :<port>") for network services.
                  4. DOCUMENT UNREADABLE: If read_document returns metadata-only for a binary format, try:
                     a) get_file_info for full metadata (dates, size, permissions)
                     b) execute_command("file '<path>'") to identify the actual file type
                     c) Suggest the user open it in its native app, or try converting with textutil/sips
                  5. GENERAL RULE: Make at least 2-3 exploratory calls before reporting "not found" to the user.

                ═══ SCREEN CONTROL ═══
                • Screen origin is top-left (0,0). Coordinates are logical pixels (1:1 with screenshot).
                • When you receive a screenshot, look at the image carefully and read the EXACT pixel
                  position of the element — do NOT approximate or guess. State the pixel coords before clicking.

                PRIORITY ORDER for UI interaction:
                  1. run_applescript — interact by element name, no coordinates needed (most reliable)
                  2. JavaScript via AppleScript — for EXTERNAL web browsers only (never misses, not affected by zoom)
                  3. click_mouse — pixel click, last resort only

                AppleScript — native app UI:
                    tell application "AppName" to activate
                    delay 0.8
                    tell application "System Events"
                        tell process "AppName"
                            click button "Button Name" of window 1
                            set value of text field 1 of window 1 to "text"
                            key code 36  -- Return
                        end tell
                    end tell

                JavaScript via AppleScript — external web browsers (ALWAYS prefer this over click_mouse in external browsers):
                    -- Click a tab / link by text or selector:
                    tell application "Google Chrome"
                        tell active tab of front window
                            execute javascript "document.querySelector('a[href*=\\"/images\\"]').click()"
                        end tell
                    end tell
                    -- Or navigate directly (most reliable):
                    tell application "Google Chrome"
                        set URL of active tab of front window to "https://www.bing.com/images/search?q=cats"
                    end tell
                    -- Safari equivalent: execute javascript / set URL of current tab of front window

                ═══ WHEN AN ACTION FAILS ═══
                If a click or action doesn't produce the expected result:
                  1. NEVER repeat the identical click at "slightly adjusted" coordinates — that rarely works.
                  2. NEVER tell the user to click manually — try a different method instead.
                  3. For Browser Workspace tasks → use browser_tile_click / browser_tile_type / browser_tile_press_key and verify with read_browser_tile_page.
                  4. For external browser clicks that failed → switch to JavaScript or navigate by URL directly.
                  5. For native app clicks that failed → switch to System Events AppleScript by element name.
                  6. If still failing after 2 attempts → take_screenshot, re-read the full UI, pick a completely
                     different approach (e.g. keyboard shortcut, menu item, URL navigation).
                  7. Only after exhausting ALL automated approaches may you report that the action failed.

                ═══ SCREENSHOT POLICY ═══
                • Do NOT take screenshots by default after every step.
                • Only use take_screenshot when visual verification is required or when recovery/debugging needs fresh UI context.
                • If run_applescript/open_url already completes the task deterministically, finish without extra screenshot checks.

                ═══ ABSOLUTE RULES ═══
                1. NEVER tell the user to "manually" do anything — not clicking, typing, or any interaction.
                2. NEVER stop after one tool call and ask what to do next — keep executing until the full task is done.
                3. NEVER leave a task half-finished. If a step fails, try an alternative approach.
                4. Desktop path: use execute_command("echo $HOME") to get the user's home, then write to $HOME/Desktop/.
                """)

                if isBrowserWorkspaceSession {
                    parts.append("""
                    ⚠️ BROWSER WORKSPACE MODE (STRICT PRIORITY) ⚠️
                    You are currently operating inside a Browser Workspace tab.
                    Your browser surface is the embedded tile, not external Safari/Chrome windows.
                    Your `agentId` for browser tile tools is: \(agent.id.uuidString)

                    REQUIRED BROWSER TOOL PRIORITY:
                    1. assign_browser_tile(agentId: "\(agent.id.uuidString)") if no tile exists
                    2. navigate_browser_tile(agentId: "\(agent.id.uuidString)", url: "<target page>")
                    3. browser_tile_click / browser_tile_type / browser_tile_press_key for in-page interaction
                    4. read_browser_tile_page / get_browser_tile_state / capture_agent_screen for verification
                    5. reload_browser_tile / browser_tile_back / browser_tile_forward for navigation control

                    INTERACTION POLICY:
                    • For buttons, links, boards, canvases, and editors inside the tile, use browser_tile_click first.
                    • For forms/chat/editors, use browser_tile_type and browser_tile_press_key instead of asking the user to type.
                    • Do not rely only on URL jumps when a task requires real in-page interactions.

                    PAGE CHOICE POLICY:
                    • You MAY and SHOULD choose which pages/URLs to open to complete the task.
                    • Do not wait for the user to specify every URL when the intent is clear.
                    • Pick direct destination pages over homepages/search pages when possible.
                    • NEVER ask the user to type a URL or press the Go button — call `navigate_browser_tile` yourself.

                    OUTSIDE-BROWSER TOOLS:
                    • Keep all tools available, but in Browser Workspace avoid `open_application("Safari")`,
                      `open_url`, and `read_browser_page` unless the user explicitly requests controlling an external browser app.
                    • Default behavior must stay inside the Browser Workspace tile.
                    """)
                }

                if desktopControlEnabled {
                    parts.append("""
                    ⚡ DESKTOP MODE PROTOCOL (MOUSE + KEYBOARD ENABLED) ⚡
                    Desktop Control is ON. You may use:
                    • Mouse tools: move_mouse, click_mouse, scroll_mouse
                    • Keyboard tools: type_text, press_key
                    • App launch: open_application

                    DESKTOP EXECUTION ORDER:
                    1. Prefer deterministic control first: run_applescript, focus_window, list_windows, keyboard shortcuts.
                    2. Use mouse coordinates only when element-based automation is unavailable.
                    3. After each major UI action, verify state and continue immediately.
                    4. Keep driving the workflow end-to-end; do not pause to ask what to do next.
                    """)
                } else {
                    parts.append("""
                    ⚠️ DESKTOP CONTROL RESTRICTION ⚠️
                    The following tools are NOT available:
                    • click_mouse, scroll_mouse, move_mouse — no mouse control
                    • type_text, press_key — no keyboard input
                    • open_application — cannot launch apps

                    AVAILABLE ALTERNATIVES:
                    • take_screenshot — view the screen
                    • run_applescript — execute AppleScript for automation
                    • execute_command — run shell commands
                    • write_file, read_file — file operations
                    • read_pdf, read_word, read_ppt, read_document — document reading
                    • get_file_info — file metadata (size, dates, type, permissions)
                    • analyze_disk_space — disk usage analysis
                    • web_search, fetch_url — web access
                    • All memory, git, data, bluetooth, volume, and media tools remain available.

                    Use AppleScript (run_applescript) with System Events for sophisticated automation instead of mouse/keyboard clicks.

                    WHEN SOMETHING ISN'T FOUND — same rules apply: explore further with search_files,
                    list_directory, get_file_info, and execute_command before reporting "not found".
                    Make at least 2-3 exploratory calls before giving up.
                    """)
                }
            }
            if isGroup {
                let others = convParticipants.filter { $0.id != agent.id }
                if !others.isEmpty {
                    let peerList = others.map { other -> String in
                        let role = other.configuration.systemPrompt
                            .flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
                            ?? "General assistant"
                        return "• \(other.name): \(role)"
                    }.joined(separator: "\n")
                    parts.append("""
                    You are \(agent.name). You are in a multi-agent group conversation. There is no leader — all agents are equal peers.

                    ═══ PARTICIPANTS ═══
                    \(peerList)
                    • You: \(agent.name)

                    Other agents' messages appear prefixed with [AgentName]: in the conversation.

                    ═══ HOW TO COLLABORATE ═══
                    Agents take turns — one completes their work fully, then hands off.
                    • READ FIRST: Before acting, read all previous messages to understand what has already been done.
                      Never duplicate or redo work a peer has already completed.
                    • ACT, DON'T OVERLAP: Do your part of the task using tools, then hand off cleanly.
                      Don't start something another agent is already doing or has just finished.
                    • HAND OFF with @AgentName: <clear instruction of what's left> — they will pick up exactly where you stopped.
                      Hand off to ONE agent at a time. Avoid mentioning multiple agents in one message unless
                      they truly need to act at the same time (which is rare).
                    • CONTINUE FREELY: After receiving a handoff, act on it. Then hand back or forward as needed.
                      The conversation can go back-and-forth as many times as the task requires.
                    • USE TOOLS at any point: search, write files, run code, control the screen, etc.
                    • FINISH: When everything is truly done, end your message with [eof].

                    ═══ SILENCE PROTOCOL ═══
                    • Not your turn, or nothing meaningful to add → respond with exactly: [eof] (hidden from user).
                    • Spoke your piece and want to hand off → say what you need, then end with [eof].
                    • Near exchange limit (20) → just finish the task yourself instead of delegating further.
                    """)
                }
            }
            if let base = agent.configuration.systemPrompt, !base.isEmpty { parts.append(base) }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }()

        func updatePlaceholder(_ text: String) {
            if let ci = conversations.firstIndex(where: { $0.id == conversationId }),
               let mi = conversations[ci].messages.firstIndex(where: { $0.id == placeholderId }) {
                guard conversations[ci].messages[mi].isStreaming else { return }
                conversations[ci].messages[mi].content = text
            }
            #if os(macOS)
            DispatchQueue.main.async {
                AgentReplyBubbleController.shared.updateText(text)
            }
            #endif
        }

        do {
            if tools.isEmpty {
                let stream = try await repo.sendMessageStream(
                    provider: agent.configuration.provider,
                    model: agent.configuration.model,
                    messages: aiMessages,
                    systemPrompt: effectiveSystemPrompt,
                    temperature: agent.configuration.temperature,
                    maxTokens: agent.configuration.maxTokens
                )
                var accumulated = ""
                for try await chunk in stream {
                    if let content = chunk.content, !content.isEmpty {
                        accumulated += content
                        updatePlaceholder(accumulated)
                    }
                }
            } else {
                var iteration = 0
                let maxIterations = agentMode ? 30 : 10
                var finalContent = ""
                while iteration < maxIterations {
                    iteration += 1

                    if Task.isCancelled {
                        updatePlaceholder(finalContent.isEmpty ? "Stopped." : finalContent)
                        break
                    }

                    let response = try await repo.sendMessage(
                        provider: agent.configuration.provider,
                        model: agent.configuration.model,
                        messages: aiMessages,
                        systemPrompt: effectiveSystemPrompt,
                        tools: tools,
                        temperature: agent.configuration.temperature,
                        maxTokens: agent.configuration.maxTokens
                    )

                    aiMessages.append(AIMessage(
                        role: .assistant,
                        content: response.content ?? "",
                        toolCalls: response.toolCalls
                    ))

                    if let content = response.content, !content.isEmpty {
                        finalContent += (finalContent.isEmpty ? "" : "\n\n") + content
                        updatePlaceholder(finalContent)
                    }

                    guard let toolCalls = response.toolCalls, !toolCalls.isEmpty else { break }

                    let names = toolCalls.map { $0.name }.joined(separator: ", ")
                    finalContent += (finalContent.isEmpty ? "" : "\n\n") + "Running: \(names)…"
                    updatePlaceholder(finalContent)

                    var touchedScreen = false

                    for toolCall in toolCalls {
                        if Task.isCancelled { break }

                        let result: String
                        #if os(macOS)
                        DispatchQueue.main.async {
                            AgentReplyBubbleController.shared.addToolCall(toolCall.name, args: toolCall.arguments)
                        }
                        #endif

                        #if os(macOS)
                        if toolCall.name == "update_self" {
                            result = applySelfUpdate(toolCall.arguments, agentId: agent.id)
                        } else if let tool = ToolRegistry.shared.getTool(named: toolCall.name) {
                            do { result = try await tool.handler(toolCall.arguments) }
                            catch { result = "Error: \(error.localizedDescription)" }
                        } else {
                            result = "Tool not found: \(toolCall.name)"
                        }
                        #else
                        do {
                            result = try await executeIOSRemoteMacTool(
                                named: toolCall.name,
                                arguments: toolCall.arguments
                            )
                        } catch {
                            result = "Error: \(error.localizedDescription)"
                        }
                        #endif
                        recordToolCall(agentId: agent.id, agentName: agent.name,
                                       toolName: toolCall.name, arguments: toolCall.arguments,
                                       result: result)
                        aiMessages.append(AIMessage(role: .tool, content: result, toolCallId: toolCall.id))

                        if screenControlToolNames.contains(toolCall.name) {
                            touchedScreen = true
                            if agentMode && !didRaiseScreenControl {
                                didRaiseScreenControl = true
                                screenControlCount += 1
                                isAgentControllingScreen = true
                            }
                        }
                    }

                    #if os(macOS)
                    if agentMode && touchedScreen && !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 900_000_000)

                        finalContent += (finalContent.isEmpty ? "" : "\n\n") + "📸 Capturing screen…"
                        updatePlaceholder(finalContent)

                        let (screen, displayID) = await MainActor.run { () -> (CGRect, UInt32) in
                            let frame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
                            let id = (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                                .map { UInt32($0.uint32Value) } ?? CGMainDisplayID()
                            return (frame, id)
                        }
                        let screenW = Int(screen.width), screenH = Int(screen.height)
                        let jpeg = await Task.detached(priority: .userInitiated) {
                            captureScreenAsJPEG(maxWidth: 1440, displayID: displayID)
                        }.value
                        if let data = jpeg {
                            aiMessages.append(AIMessage(
                                role: .user,
                                content: "Here is the current screen state after your last actions. " +
                                         "Resolution: \(screenW)×\(screenH) logical px — coordinates are 1:1, " +
                                         "top-left origin (0,0). Use pixel positions from this image directly " +
                                         "with click_mouse — no scaling needed. " +
                                         "Identify every visible UI element and decide what to do next. " +
                                         "Tip: run_applescript can interact with UI elements by name " +
                                         "(click buttons, fill fields, choose menu items) without needing " +
                                         "pixel coordinates — prefer it when the app supports it.",
                                imageData: data
                            ))
                        }
                    }
                    #endif
                }
                if finalContent.isEmpty { updatePlaceholder("(no response)") }
            }
        } catch is CancellationError {
            if let ci = conversations.firstIndex(where: { $0.id == conversationId }),
               let mi = conversations[ci].messages.firstIndex(where: { $0.id == placeholderId }),
               conversations[ci].messages[mi].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                conversations[ci].messages[mi].content = "Stopped."
            }
        } catch {
            updatePlaceholder("Error: \(error.localizedDescription)")
        }

        // Mark streaming done
        if let ci = conversations.firstIndex(where: { $0.id == conversationId }),
           let mi = conversations[ci].messages.firstIndex(where: { $0.id == placeholderId }) {
            conversations[ci].messages[mi].isStreaming = false
        }
        if let ci = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[ci].updatedAt = Date()
        }

        // Strip [eof] silence markers from group chats
        if isGroup,
           let ci = conversations.firstIndex(where: { $0.id == conversationId }),
           let mi = conversations[ci].messages.firstIndex(where: { $0.id == placeholderId }) {
            let raw = conversations[ci].messages[mi].content
            let cleaned = raw
                .replacingOccurrences(of: "[eof]", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                conversations[ci].messages.remove(at: mi)
                return
            } else if cleaned != raw {
                conversations[ci].messages[mi].content = cleaned
            }
        }

        // Agent-to-agent delegation
        if isGroup && delegationDepth < 20 && !Task.isCancelled,
           let ci = conversations.firstIndex(where: { $0.id == conversationId }),
           let mi = conversations[ci].messages.firstIndex(where: { $0.id == placeholderId }) {
            let agentResponse = conversations[ci].messages[mi].content
            let delegatedAgents = convParticipants.filter { other in
                other.id != agent.id &&
                agentResponse.range(of: "@\(other.name)", options: .caseInsensitive) != nil
            }
            if !delegatedAgents.isEmpty {
                for target in delegatedAgents {
                    guard !Task.isCancelled else { break }
                    let freshHistory = conversations
                        .first(where: { $0.id == conversationId })?
                        .messages.filter { !$0.isStreaming } ?? []
                    await streamResponse(
                        from: target,
                        in: conversationId,
                        history: freshHistory,
                        agentMode: agentMode,
                        delegationDepth: delegationDepth + 1
                    )
                }
            }
        }
    }

    #if os(iOS)
    private func iOSRemoteMacTools(enabledNames: [String]) -> [AITool] {
        let all: [AITool] = [
            AITool(
                name: "execute_command",
                description: "Execute a shell command on the connected Mac and return output.",
                parameters: AIToolParameters(
                    properties: [
                        "command": AIToolProperty(type: "string", description: "Shell command to run on the Mac"),
                        "working_directory": AIToolProperty(type: "string", description: "Optional working directory on the Mac")
                    ],
                    required: ["command"]
                )
            ),
            AITool(
                name: "run_applescript",
                description: "Run AppleScript on the connected Mac.",
                parameters: AIToolParameters(
                    properties: ["script": AIToolProperty(type: "string", description: "AppleScript source")],
                    required: ["script"]
                )
            ),
            AITool(
                name: "get_system_info",
                description: "Get system information from the connected Mac.",
                parameters: AIToolParameters(properties: [:], required: [])
            ),
            AITool(
                name: "open_application",
                description: "Open an app on the connected Mac.",
                parameters: AIToolParameters(
                    properties: ["name": AIToolProperty(type: "string", description: "Application name")],
                    required: ["name"]
                )
            ),
            AITool(
                name: "open_url",
                description: "Open a URL on the connected Mac.",
                parameters: AIToolParameters(
                    properties: ["url": AIToolProperty(type: "string", description: "URL to open")],
                    required: ["url"]
                )
            ),
            AITool(
                name: "list_running_apps",
                description: "List running GUI apps on the connected Mac.",
                parameters: AIToolParameters(properties: [:], required: [])
            ),
            AITool(
                name: "quit_application",
                description: "Quit an app on the connected Mac.",
                parameters: AIToolParameters(
                    properties: ["name": AIToolProperty(type: "string", description: "Application name")],
                    required: ["name"]
                )
            ),
            AITool(
                name: "get_volume",
                description: "Get current volume on the connected Mac.",
                parameters: AIToolParameters(properties: [:], required: [])
            ),
            AITool(
                name: "set_volume",
                description: "Set output volume (0-100) on the connected Mac.",
                parameters: AIToolParameters(
                    properties: ["level": AIToolProperty(type: "string", description: "Volume 0-100")],
                    required: ["level"]
                )
            ),
            AITool(
                name: "set_mute",
                description: "Mute or unmute output on the connected Mac.",
                parameters: AIToolParameters(
                    properties: ["muted": AIToolProperty(type: "string", description: "true or false", enumValues: ["true", "false"])],
                    required: ["muted"]
                )
            ),
            AITool(
                name: "media_control",
                description: "Control media playback on the connected Mac.",
                parameters: AIToolParameters(
                    properties: ["action": AIToolProperty(type: "string", description: "Media action", enumValues: ["play", "pause", "toggle", "next", "previous", "stop"])],
                    required: ["action"]
                )
            ),
            AITool(
                name: "get_screen_info",
                description: "Get screen size information from the connected Mac.",
                parameters: AIToolParameters(properties: [:], required: [])
            ),
            AITool(
                name: "click_mouse",
                description: "Click the mouse on the connected Mac at x/y coordinates.",
                parameters: AIToolParameters(
                    properties: [
                        "x": AIToolProperty(type: "string", description: "X coordinate"),
                        "y": AIToolProperty(type: "string", description: "Y coordinate"),
                        "button": AIToolProperty(type: "string", description: "left or right", enumValues: ["left", "right"])
                    ],
                    required: ["x", "y"]
                )
            ),
            AITool(
                name: "type_text",
                description: "Type text into the focused app on the connected Mac.",
                parameters: AIToolParameters(
                    properties: ["text": AIToolProperty(type: "string", description: "Text to type")],
                    required: ["text"]
                )
            ),
            AITool(
                name: "press_key",
                description: "Press a key on the connected Mac with optional modifiers.",
                parameters: AIToolParameters(
                    properties: [
                        "key": AIToolProperty(type: "string", description: "Key name"),
                        "modifiers": AIToolProperty(type: "string", description: "Optional comma-separated modifiers")
                    ],
                    required: ["key"]
                )
            ),
            AITool(
                name: "send_notification",
                description: "Show a system notification on the connected Mac.",
                parameters: AIToolParameters(
                    properties: [
                        "title": AIToolProperty(type: "string", description: "Notification title"),
                        "message": AIToolProperty(type: "string", description: "Notification body")
                    ],
                    required: ["message"]
                )
            )
        ]

        if enabledNames.isEmpty {
            return all
        }
        return all.filter { enabledNames.contains($0.name) }
    }

    private func executeIOSRemoteMacTool(
        named toolName: String,
        arguments: [String: String]
    ) async throws -> String {
        guard isRemoteMacConnected, let executor = remoteMacCommandExecutor else {
            throw NSError(domain: "RemoteMac", code: 1, userInfo: [NSLocalizedDescriptionKey: "No remote Mac connected"])
        }

        let commandType: String
        var parameters = arguments
        var timeout: TimeInterval = 20

        switch toolName {
        case "execute_command":
            commandType = "run_shell_command"
            timeout = 45
            let command = arguments["command"] ?? ""
            let workingDirectory = arguments["working_directory"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !workingDirectory.isEmpty {
                parameters = [
                    "command": "cd \(shellQuote(workingDirectory)) && \(command)"
                ]
            } else {
                parameters = ["command": command]
            }
        case "run_applescript":
            commandType = "run_applescript"
            timeout = 45
            parameters = ["script": arguments["script"] ?? ""]
        case "get_system_info":
            commandType = "get_system_info"
            parameters = [:]
        case "open_application":
            commandType = "open_application"
            parameters = ["name": arguments["name"] ?? ""]
        case "open_url":
            commandType = "launch_url"
            parameters = ["url": arguments["url"] ?? ""]
        case "list_running_apps":
            commandType = "list_running_apps"
            parameters = [:]
        case "quit_application":
            commandType = "quit_application"
            parameters = ["name": arguments["name"] ?? ""]
        case "get_volume":
            commandType = "get_volume"
            parameters = [:]
        case "set_volume":
            commandType = "set_volume"
            parameters = ["level": arguments["level"] ?? "50"]
        case "set_mute":
            commandType = "set_mute"
            parameters = ["muted": arguments["muted"] ?? "false"]
        case "media_control":
            let action = (arguments["action"] ?? "toggle").lowercased()
            switch action {
            case "play": commandType = "media_play"
            case "pause": commandType = "media_pause"
            case "next": commandType = "media_next"
            case "previous": commandType = "media_previous"
            case "stop": commandType = "media_stop"
            default: commandType = "media_toggle"
            }
            parameters = [:]
        case "get_screen_info":
            commandType = "get_screen_info"
            parameters = [:]
        case "click_mouse":
            commandType = "click_mouse"
            parameters = [
                "x": arguments["x"] ?? "0",
                "y": arguments["y"] ?? "0",
                "button": arguments["button"] ?? "left"
            ]
        case "type_text":
            commandType = "type_text"
            parameters = ["text": arguments["text"] ?? ""]
        case "press_key":
            commandType = "press_key"
            parameters = [
                "key": arguments["key"] ?? "return",
                "modifiers": arguments["modifiers"] ?? ""
            ]
        case "send_notification":
            commandType = "send_notification"
            parameters = [
                "title": arguments["title"] ?? "LumiAgent",
                "message": arguments["message"] ?? ""
            ]
        default:
            throw NSError(domain: "RemoteMac", code: 2, userInfo: [NSLocalizedDescriptionKey: "Tool not available on iPhone: \(toolName)"])
        }

        let response = try await executor(commandType, parameters, timeout)
        if response.success {
            return response.result.isEmpty ? "OK" : response.result
        }
        throw NSError(
            domain: "RemoteMac",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: response.error ?? "Remote command failed"]
        )
    }

    private func shellQuote(_ input: String) -> String {
        "'" + input.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    #endif
}

// MARK: - Sidebar Item

enum SidebarItem: String, CaseIterable, Identifiable {
    case agents      = "Agents"
    case agentSpace  = "Agent Space"
    case hotkeySpace = "Hotkey Space"
    case browser     = "Browser Workspace"
    case health      = "Health"
    case history     = "History"
    case automation  = "Automations"
    case devices     = "Paired Devices"
    case settings    = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .agents:      return "cpu"
        case .agentSpace:  return "bubble.left.and.bubble.right.fill"
        case .hotkeySpace: return "keyboard"
        case .browser:     return "globe"
        case .health:      return "heart.fill"
        case .history:     return "clock.arrow.circlepath"
        case .automation:  return "bolt.horizontal"
        case .devices:     return "iphone"
        case .settings:    return "gear"
        }
    }
}
