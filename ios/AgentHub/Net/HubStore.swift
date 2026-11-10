import Foundation
import Observation
import SwiftUI

enum ConnectionState: Equatable {
    case unpaired, connecting, connected, offline(String)
}

/// Single source of truth for daemon state. Owns the WebSocket.
@Observable
@MainActor
final class HubStore {
    var pairing: Pairing?
    var connection: ConnectionState = .unpaired
    var sessions: [Session] = []
    var mac: MacStatus?
    var approvals: [String: Approval] = [:]
    var transcripts: [String: [TranscriptEvent]] = [:]
    var streaming: [String: String] = [:]
    /// Bumped whenever an output is added; outputs screens reload on change.
    var outputsRevision = 0
    var lastError: String?

    // Navigation
    var selectedSessionId: String?
    var drawerOpen = false

    // New-session draft (home screen)
    var draftAgent: AgentKind = AgentKind(rawValue: UserDefaults.standard.string(forKey: "draftAgent") ?? "") ?? .claude {
        didSet { UserDefaults.standard.set(draftAgent.rawValue, forKey: "draftAgent") }
    }
    var draftFolder: String = UserDefaults.standard.string(forKey: "draftFolder") ?? "" {
        didSet { UserDefaults.standard.set(draftFolder, forKey: "draftFolder") }
    }
    /// Option pills (Claude) + pass-through extra flags per agent.
    var claudeModel: String = UserDefaults.standard.string(forKey: "claudeModel") ?? "" {
        didSet { UserDefaults.standard.set(claudeModel, forKey: "claudeModel") }
    }
    var claudeMode: String = UserDefaults.standard.string(forKey: "claudeMode") ?? "" {
        didSet { UserDefaults.standard.set(claudeMode, forKey: "claudeMode") }
    }
    var extraFlags: [String: String] = (UserDefaults.standard.dictionary(forKey: "extraFlags") as? [String: String]) ?? [:] {
        didSet { UserDefaults.standard.set(extraFlags, forKey: "extraFlags") }
    }
    var draftFlags: String {
        var parts: [String] = []
        if draftAgent == .claude {
            if !claudeModel.isEmpty { parts.append("--model \(claudeModel)") }
            if !claudeMode.isEmpty { parts.append("--permission-mode \(claudeMode)") }
        }
        let extra = (extraFlags[draftAgent.rawValue] ?? "").trimmingCharacters(in: .whitespaces)
        if !extra.isEmpty { parts.append(extra) }
        return parts.joined(separator: " ")
    }
    var draftSSHHost: String = UserDefaults.standard.string(forKey: "draftSSHHost") ?? "homeserver" {
        didSet { UserDefaults.standard.set(draftSSHHost, forKey: "draftSSHHost") }
    }

    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var backoff: Double = 1
    @ObservationIgnored private var reconnectWork: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var subscriptions: [String: (cols: Int, rows: Int, terminal: Bool)] = [:]
    @ObservationIgnored var terminalSinks: [String: (Data) -> Void] = [:]

    var api: APIClient? { pairing.map(APIClient.init) }

    init() {
        #if DEBUG
        // Simulator/dev: SIMCTL_CHILD_AGENTHUB_PAIRING='{"host":…,"port":…,"token":…}'
        if let json = ProcessInfo.processInfo.environment["AGENTHUB_PAIRING"],
           let p = try? JSONDecoder().decode(Pairing.self, from: Data(json.utf8)) {
            Keychain.save(p)
        }
        selectedSessionId = ProcessInfo.processInfo.environment["AGENTHUB_OPEN_SESSION"]
        drawerOpen = ProcessInfo.processInfo.environment["AGENTHUB_OPEN_DRAWER"] != nil
        #endif
        if let p = Keychain.load() {
            pairing = p
            connection = .connecting
        }
    }

    // MARK: Pairing

    func pair(_ p: Pairing) {
        Keychain.save(p)
        pairing = p
        connect()
    }

    func unpair() {
        disconnect()
        Keychain.clear()
        pairing = nil
        sessions = []
        mac = nil
        connection = .unpaired
    }

    // MARK: Connection

    func connect() {
        guard let api else { connection = .unpaired; return }
        reconnectWork?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        generation += 1
        let gen = generation
        connection = .connecting
        var req = api.request("GET", "/ws")
        req.url = URL(string: api.url("/ws").absoluteString.replacingOccurrences(of: "http://", with: "ws://"))
        req.timeoutInterval = 15
        let t = URLSession.shared.webSocketTask(with: req)
        t.maximumMessageSize = 8 * 1024 * 1024
        task = t
        t.resume()
        Task { await receiveLoop(t, gen: gen) }
    }

    func disconnect() {
        reconnectWork?.cancel()
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// Called on foreground: free provisioning gives no background guarantees, so resync.
    func foregrounded() {
        guard pairing != nil else { return }
        if connection != .connected { backoff = 1; connect() }
        else { send(["type": "ping"]) }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask, gen: Int) async {
        while gen == generation {
            do {
                let msg = try await t.receive()
                let data: Data
                switch msg {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: continue
                }
                handle(data)
            } catch {
                guard gen == generation else { return }
                connection = .offline(friendly(error))
                scheduleReconnect()
                return
            }
        }
    }

    private func friendly(_ e: Error) -> String {
        let ns = e as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet:
                return "Mac offline"
            default: break
            }
        }
        if ns.localizedDescription.contains("401") || ns.localizedDescription.lowercased().contains("bad response") {
            return "Not authorized — re-pair"
        }
        return "Mac offline"
    }

    private func scheduleReconnect() {
        reconnectWork?.cancel()
        let delay = backoff
        backoff = min(backoff * 2, 30)
        reconnectWork = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    func send(_ obj: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        task.send(.string(s)) { _ in }
    }

    // MARK: Incoming

    private struct Envelope: Decodable { var type: String; var sessionId: String? }
    private struct Hello: Decodable { var sessions: [Session]; var mac: MacStatus; var approvals: [Approval] }
    private struct SessionMsg: Decodable { var session: Session }
    private struct MacMsg: Decodable { var mac: MacStatus }
    private struct EventMsg: Decodable { var sessionId: String; var event: TranscriptEvent }
    private struct DeltaMsg: Decodable { var sessionId: String; var text: String }
    private struct TermMsg: Decodable { var sessionId: String; var data: String }
    private struct ApprovalMsg: Decodable { var requestId: String; var sessionId: String; var tool: String; var summary: String; var input: JSONValue? }
    private struct ResolvedMsg: Decodable { var requestId: String }
    private struct ErrorMsg: Decodable { var message: String }

    private func handle(_ data: Data) {
        let dec = JSONDecoder()
        guard let env = try? dec.decode(Envelope.self, from: data) else { return }
        switch env.type {
        case "hello":
            guard let h = try? dec.decode(Hello.self, from: data) else { return }
            connection = .connected
            backoff = 1
            sessions = sortSessions(h.sessions)
            mac = h.mac
            approvals = Dictionary(uniqueKeysWithValues: h.approvals.map { ($0.requestId, $0) })
            // Resubscribe and catch up on anything missed while away.
            for (id, sub) in subscriptions { subscribe(id, cols: sub.cols, rows: sub.rows, terminal: sub.terminal) }
            for id in transcripts.keys { Task { await loadTranscript(id) } }
            #if DEBUG
            if let a = ProcessInfo.processInfo.environment["AGENTHUB_AUTOSTART"], let kind = AgentKind(rawValue: a), selectedSessionId == nil {
                draftAgent = kind
                draftFolder = ProcessInfo.processInfo.environment["AGENTHUB_FOLDER"] ?? draftFolder
                Task { await createSession(prompt: nil) }
            }
            #endif
        case "session.updated":
            guard let m = try? dec.decode(SessionMsg.self, from: data) else { return }
            if let i = sessions.firstIndex(where: { $0.id == m.session.id }) { sessions[i] = m.session }
            else { sessions.append(m.session) }
            sessions = sortSessions(sessions)
        case "session.deleted":
            sessions.removeAll { $0.id == env.sessionId }
            if selectedSessionId == env.sessionId { selectedSessionId = nil }
        case "mac.updated":
            if let m = try? dec.decode(MacMsg.self, from: data) { mac = m.mac }
        case "transcript.event":
            guard let m = try? dec.decode(EventMsg.self, from: data) else { return }
            upsert(m.event, in: m.sessionId)
            if m.event.kind == "assistant" || m.event.kind == "result" { streaming[m.sessionId] = nil }
        case "transcript.delta":
            guard let m = try? dec.decode(DeltaMsg.self, from: data) else { return }
            streaming[m.sessionId, default: ""] += m.text
        case "terminal.data":
            guard let m = try? dec.decode(TermMsg.self, from: data), let bytes = Data(base64Encoded: m.data) else { return }
            terminalSinks[m.sessionId]?(bytes)
        case "approval.request":
            guard let m = try? dec.decode(ApprovalMsg.self, from: data) else { return }
            approvals[m.requestId] = Approval(requestId: m.requestId, sessionId: m.sessionId, tool: m.tool, summary: m.summary, input: m.input)
        case "approval.resolved":
            if let m = try? dec.decode(ResolvedMsg.self, from: data) { approvals[m.requestId] = nil }
        case "output.added":
            outputsRevision += 1
        case "error":
            if let m = try? dec.decode(ErrorMsg.self, from: data) { lastError = m.message }
        default:
            break
        }
    }

    private func upsert(_ e: TranscriptEvent, in sessionId: String) {
        var list = transcripts[sessionId] ?? []
        if let i = list.lastIndex(where: { $0.seq == e.seq }) { list[i] = e }
        else if let last = list.last, last.seq > e.seq {
            list.append(e)
            list.sort { $0.seq < $1.seq }
        } else { list.append(e) }
        transcripts[sessionId] = list
    }

    private func sortSessions(_ list: [Session]) -> [Session] {
        list.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            let aw = a.status == .waiting, bw = b.status == .waiting
            if aw != bw { return aw }
            return a.lastActivityAt > b.lastActivityAt
        }
    }

    // MARK: Session actions

    func session(_ id: String?) -> Session? { sessions.first { $0.id == id } }

    func loadTranscript(_ id: String) async {
        guard let api else { return }
        let after = transcripts[id]?.last?.seq ?? 0
        do {
            let events: [TranscriptEvent] = try await api.get("/sessions/\(id)/transcript", query: ["after": String(after)])
            if transcripts[id] == nil { transcripts[id] = [] }
            for e in events { upsert(e, in: id) }
        } catch { lastError = error.localizedDescription }
    }

    /// `terminal: false` follows only the transcript of a terminal session (no screen stream, no resize).
    func subscribe(_ id: String, cols: Int = 0, rows: Int = 0, terminal: Bool = true) {
        subscriptions[id] = (cols, rows, terminal)
        var m: [String: Any] = ["type": "subscribe", "sessionId": id]
        if cols > 0 { m["cols"] = cols; m["rows"] = rows }
        if !terminal { m["terminal"] = false }
        send(m)
    }

    /// `onlyIfTerminal`: skip unless the current subscription is of that kind (terminal vs. chat-only).
    func unsubscribe(_ id: String, onlyIfTerminal: Bool? = nil) {
        if let want = onlyIfTerminal, subscriptions[id]?.terminal != want { return }
        subscriptions[id] = nil
        send(["type": "unsubscribe", "sessionId": id])
    }

    func sendPrompt(_ id: String, _ text: String) {
        send(["type": "prompt.send", "sessionId": id, "text": text])
    }

    func terminalInput(_ id: String, _ bytes: Data) {
        send(["type": "terminal.input", "sessionId": id, "data": bytes.base64EncodedString()])
    }

    func terminalResize(_ id: String, cols: Int, rows: Int) {
        subscriptions[id] = (cols, rows, true)
        send(["type": "terminal.resize", "sessionId": id, "cols": cols, "rows": rows])
    }

    func respond(_ requestId: String, _ decision: String) {
        approvals[requestId] = nil
        send(["type": "approval.respond", "requestId": requestId, "decision": decision])
    }

    func unqueue(_ id: String, queuedId: String) { send(["type": "prompt.unqueue", "sessionId": id, "queuedId": queuedId]) }

    /// Pick an option of the menu a terminal Claude session is showing.
    func answerPrompt(_ id: String, key: String) { send(["type": "prompt.answer", "sessionId": id, "key": key]) }

    func interrupt(_ id: String) { send(["type": "session.interrupt", "sessionId": id]) }

    struct CreateBody: Encodable {
        var folder: String
        var agent: AgentKind
        var flags: String
        var sshHost: String?
        var firstPrompt: String?
        var cols: Int?
        var rows: Int?
    }

    /// Screen size of the main content, set by the root view; used to size new terminals.
    @ObservationIgnored var contentSize: CGSize = .zero

    /// Estimate the terminal grid the session screen will show, so the agent's
    /// first screen is drawn at the phone's width (TUIs don't reflow old output).
    func estimatedTerminalSize() -> (cols: Int, rows: Int)? {
        guard contentSize.width > 0 else { return nil }
        let font = UIFont.monospacedSystemFont(ofSize: TerminalMetrics.fontSize, weight: .regular)
        let cw = ("W" as NSString).size(withAttributes: [.font: font]).width
        let width = contentSize.width - TerminalMetrics.horizontalInset
        let height = contentSize.height - TerminalMetrics.verticalChrome
        guard cw > 0, width > 0, height > 0 else { return nil }
        return (max(20, Int(width / cw)), max(8, Int(height / font.lineHeight)))
    }

    @discardableResult
    func createSession(prompt: String?) async -> Session? {
        guard let api else { return nil }
        let body = CreateBody(folder: draftFolder, agent: draftAgent, flags: draftFlags,
                              sshHost: draftAgent == .ssh ? draftSSHHost : nil,
                              firstPrompt: (prompt?.isEmpty ?? true) ? nil : prompt,
                              cols: draftAgent.isStructured ? nil : estimatedTerminalSize()?.cols,
                              rows: draftAgent.isStructured ? nil : estimatedTerminalSize()?.rows)
        do {
            let s: Session = try await api.send("POST", "/sessions", body: body)
            if !sessions.contains(where: { $0.id == s.id }) { sessions.insert(s, at: 0) }
            selectedSessionId = s.id
            return s
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: Resume Claude sessions started in a terminal

    func claudeHistory(folder rel: String) async throws -> [ClaudeHistorySession] {
        guard let api else { return [] }
        return try await api.get("/claude-sessions", query: ["project": rel])
    }

    @discardableResult
    func resumeClaude(_ h: ClaudeHistorySession, folder rel: String) async -> Session? {
        if let existing = h.hubSessionId, session(existing) != nil {
            selectedSessionId = existing
            return session(existing)
        }
        guard let api else { return nil }
        struct Body: Encodable { var folder: String; var claudeSessionId: String }
        do {
            let s: Session = try await api.send("POST", "/claude-sessions", body: Body(folder: rel, claudeSessionId: h.id))
            if !sessions.contains(where: { $0.id == s.id }) { sessions.insert(s, at: 0) }
            selectedSessionId = s.id
            return s
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func patch(_ id: String, name: String? = nil, pinned: Bool? = nil) async {
        struct Body: Encodable { var name: String?; var pinned: Bool? }
        do {
            let s: Session = try await api!.send("PATCH", "/sessions/\(id)", body: Body(name: name, pinned: pinned))
            if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i] = s }
            sessions = sortSessions(sessions)
        } catch { lastError = error.localizedDescription }
    }

    func stop(_ id: String) async {
        do { try await api?.sendIgnoring("POST", "/sessions/\(id)/stop") } catch { lastError = error.localizedDescription }
    }

    func delete(_ id: String) async {
        do {
            try await api?.sendIgnoring("DELETE", "/sessions/\(id)")
            sessions.removeAll { $0.id == id }
            transcripts[id] = nil
            if selectedSessionId == id { selectedSessionId = nil }
        } catch { lastError = error.localizedDescription }
    }

    func screenshot(_ id: String, target: String = "simulator") async {
        struct Body: Encodable { var target: String }
        do { try await api?.sendIgnoring("POST", "/sessions/\(id)/screenshot", body: Body(target: target)) }
        catch { lastError = error.localizedDescription }
    }

    func setMac(keepAwake: Bool? = nil, tailscaleOnly: Bool? = nil) async {
        struct Body: Encodable { var keepAwake: Bool?; var tailscaleOnly: Bool? }
        do { mac = try await api?.send("PATCH", "/mac", body: Body(keepAwake: keepAwake, tailscaleOnly: tailscaleOnly)) }
        catch { lastError = error.localizedDescription }
    }

    // MARK: Presets

    func loadPresets() async -> [Preset] {
        (try? await api?.get("/presets")) ?? []
    }

    func savePreset(label: String) async {
        guard let api, let base = mac?.baseFolder else { return }
        struct P: Encodable { var id: String; var folder: String; var agent: AgentKind; var flags: String; var label: String }
        let folder = draftFolder.isEmpty ? base : (base as NSString).appendingPathComponent(draftFolder)
        var body = await loadPresets().map {
            P(id: $0.id, folder: $0.folder, agent: $0.agent, flags: $0.flags.map(shellQuote).joined(separator: " "), label: $0.label)
        }
        body.append(P(id: UUID().uuidString, folder: folder, agent: draftAgent, flags: draftFlags, label: label))
        do { try await api.sendIgnoring("PUT", "/presets", body: body) } catch { lastError = error.localizedDescription }
    }

    func applyPreset(_ p: Preset) {
        draftAgent = p.agent
        if p.agent == .claude { claudeModel = ""; claudeMode = "" }
        extraFlags[p.agent.rawValue] = p.flags.map(shellQuote).joined(separator: " ")
    }

    // MARK: Derived

    var waitingSessions: [Session] { sessions.filter { $0.status == .waiting } }
    var recentSessions: [Session] { sessions.filter { $0.status != .waiting } }

    var draftProject: String {
        draftFolder.isEmpty ? "your workspace" : (draftFolder as NSString).lastPathComponent
    }

    func lastSession(inFolder rel: String) -> Session? {
        guard let base = mac?.baseFolder else { return nil }
        let abs = rel.isEmpty ? base : (base as NSString).appendingPathComponent(rel)
        return sessions.filter { $0.folder == abs }.max { $0.lastActivityAt < $1.lastActivityAt }
    }

    /// Relative-to-base path for a session folder (for outputs queries).
    func relFolder(_ abs: String) -> String {
        guard let base = mac?.baseFolder, abs.hasPrefix(base) else { return abs }
        return String(abs.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
