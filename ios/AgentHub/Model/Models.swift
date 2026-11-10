import Foundation

enum AgentKind: String, Codable, CaseIterable, Identifiable {
    case claude, codex, amp, shell, ssh
    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .amp: "Amp"
        case .shell: "Shell"
        case .ssh: "SSH"
        }
    }
    var shortLabel: String { self == .claude ? "Claude" : label }
    var subtitle: String {
        switch self {
        case .claude: "Chat transcript, tool summaries, inline approvals"
        case .codex: "Live terminal"
        case .amp: "Live terminal"
        case .shell: "Login shell in the project folder"
        case .ssh: "Remote shell"
        }
    }
    var isStructured: Bool { self == .claude }
}

enum SessionStatus: String, Codable {
    case starting, running, waiting, idle, done, error, stopped

    var isLive: Bool { [.starting, .running, .waiting, .idle].contains(self) }
    /// Filled dot = running; ring = idle/done.
    var filledDot: Bool { [.starting, .running, .waiting].contains(self) }
}

struct Session: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var folder: String
    var agent: AgentKind
    var mode: String
    var flags: [String]
    var sshHost: String?
    var agentSessionId: String?
    var resumedFrom: String?
    var status: SessionStatus
    var statusDetail: String?
    /// Claude in a terminal: the selection menu it is showing (status waiting).
    var prompt: TerminalPrompt?
    /// Claude in a terminal: messages waiting for Claude to finish its turn.
    var queued: [QueuedPrompt]?
    /// Claude in a terminal: messages in Claude's own queue (typed while it works).
    var claudeQueue: [String]?
    var pinned: Bool
    var createdAt: String
    var updatedAt: String
    var lastActivityAt: String

    var project: String { (folder as NSString).lastPathComponent }
    var isTerminal: Bool { mode == "terminal" }
    /// Claude running as its terminal UI (`hub claude`); the daemon also keeps a chat transcript.
    var isClaudeTerminal: Bool { isTerminal && agent == .claude }
    var flagsString: String { flags.map(shellQuote).joined(separator: " ") }

    /// "binge · Claude · running" / "binge · wants to run tests"
    var drawerSubtitle: String {
        if status == .waiting, let d = statusDetail, !d.isEmpty {
            return "\(project) · \(d.prefix(1).lowercased() + d.dropFirst())"
        }
        if agent == .ssh { return "SSH · \(status.rawValue)" }
        return "\(project) · \(agent.shortLabel) · \(status.rawValue)"
    }
}

struct QueuedPrompt: Codable, Hashable, Identifiable {
    var id: String
    var text: String
}

struct TerminalPrompt: Codable, Hashable {
    struct Option: Codable, Hashable { var key: String; var label: String }
    var question: String
    var context: String
    var options: [Option]
}

func shellQuote(_ s: String) -> String {
    if !s.isEmpty, s.range(of: #"^[A-Za-z0-9_\-+=.,/:@%^]+$"#, options: .regularExpression) != nil { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Arbitrary JSON (tool inputs).
enum JSONValue: Codable, Hashable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }
    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

struct TranscriptEvent: Codable, Identifiable, Hashable {
    var seq: Int
    var ts: String
    var kind: String
    var text: String?
    var toolUseId: String?
    var tool: String?
    var summary: String?
    var input: JSONValue?
    var isError: Bool?
    var requestId: String?
    var decision: String?
    var outputId: String?
    var output: Output?
    var durationMs: Double?
    var costUsd: Double?
    var id: Int { seq }
}

struct Output: Codable, Identifiable, Hashable {
    var id: String
    var folder: String
    var sessionId: String
    var kind: String // page | image | markdown | changes
    var relpath: String
    var source: String
    var title: String?
    var latestSessionId: String?
    var files: [String]?
    var additions: Int?
    var deletions: Int?
    var createdAt: String
    var updatedAt: String
    var versionCount: Int

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        return (relpath as NSString).lastPathComponent
    }
    var fileName: String { (relpath as NSString).lastPathComponent }
    var kindLabel: String {
        switch kind {
        case "page": "Page"
        case "image": source == "simulator" ? "Simulator" : "Image"
        case "markdown": "Markdown"
        default: "Changes"
        }
    }
    var originSession: String { latestSessionId ?? sessionId }
}

struct OutputVersion: Codable, Identifiable, Hashable {
    var id: String
    var outputId: String
    var n: Int
    var sessionId: String
    var createdAt: String
    var sha1: String
    var size: Int
    var storedPath: String
}

struct AgentInfo: Codable, Hashable {
    var name: String
    var path: String?
    var version: String?
}

struct MacStatus: Codable, Hashable {
    var hostname: String
    var awake: Bool
    var keepAwake: Bool
    var tailscaleIp: String?
    var tailscaleOnly: Bool
    var listening: [String]
    var port: Int
    var baseFolder: String
    var sshHosts: [String]
    var agents: [AgentInfo]
    var clients: Int?
}

struct Approval: Codable, Identifiable, Hashable {
    var requestId: String
    var sessionId: String
    var tool: String
    var summary: String
    var input: JSONValue?
    var id: String { requestId }
}

/// A Claude Code session started outside agent-hub (e.g. `claude` in a terminal).
struct ClaudeHistorySession: Codable, Identifiable, Hashable {
    var id: String
    var folder: String
    var title: String
    var lastPrompt: String?
    var promptCount: Int
    var lastActivityAt: String
    var openInTerminal: Bool
    var hubSessionId: String?
}

struct FolderInfo: Codable, Identifiable, Hashable {
    var name: String
    var path: String
    var isGit: Bool
    var branch: String?
    var language: String?
    var hasChildren: Bool
    var modifiedAt: String
    var sessionCount: Int
    var id: String { path }

    var meta: String {
        var parts: [String] = []
        if let l = language { parts.append(l) }
        if let b = branch { parts.append(b) }
        if sessionCount > 0 { parts.append("\(sessionCount) session\(sessionCount == 1 ? "" : "s")") }
        return parts.isEmpty ? "Folder" : parts.joined(separator: " · ")
    }
}

struct FolderListing: Codable {
    var base: String
    var path: String
    var folders: [FolderInfo]
}

struct Preset: Codable, Identifiable, Hashable {
    var id: String
    var folder: String
    var agent: AgentKind
    var flags: [String]
    var label: String
}

struct ActivityEntry: Codable, Identifiable, Hashable {
    var id: Int
    var ts: String
    var origin: String
    var action: String
    var sessionId: String?
    var detail: String?
}

struct Pairing: Codable, Equatable {
    var host: String
    var port: Int
    var token: String
    var name: String?

    var baseURL: URL { URL(string: "http://\(host):\(port)")! }
}

enum ISO {
    static let parser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static func date(_ s: String) -> Date { parser.date(from: s) ?? .distantPast }
    static func relative(_ s: String) -> String {
        let d = date(s)
        let secs = Date().timeIntervalSince(d)
        if secs < 60 { return "now" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if secs < 86400 { return "\(Int(secs / 3600))h" }
        return short(s)
    }
    static func short(_ s: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date(s))
    }
}
