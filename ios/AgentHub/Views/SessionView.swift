import SwiftUI

/// Transcript items after grouping raw events for display.
enum TranscriptItem: Identifiable {
    case user(TranscriptEvent)
    case assistant(TranscriptEvent)
    case tools([TranscriptEvent])
    case output(TranscriptEvent)
    case approval(TranscriptEvent)
    case notice(TranscriptEvent)

    var id: String {
        switch self {
        case .user(let e), .assistant(let e), .output(let e), .approval(let e), .notice(let e): "e\(e.seq)"
        case .tools(let es): "t\(es.first?.seq ?? 0)"
        }
    }

    static func group(_ events: [TranscriptEvent]) -> [TranscriptItem] {
        var out: [TranscriptItem] = []
        var tools: [TranscriptEvent] = []
        func flush() {
            defer { tools = [] }
            guard !tools.isEmpty else { return }
            // A result whose tool_use sat before an approval card: attach it to that earlier group.
            let onlyResults = !tools.contains { $0.kind == "tool_use" || $0.kind == "thinking" }
            if onlyResults {
                if let i = out.lastIndex(where: { if case .tools = $0 { return true }; return false }),
                   case .tools(let prev) = out[i] { out[i] = .tools(prev + tools) }
                return
            }
            out.append(.tools(tools))
        }
        for e in events {
            switch e.kind {
            case "tool_use", "tool_result", "thinking": tools.append(e)
            case "user": flush(); out.append(.user(e))
            case "assistant": flush(); out.append(.assistant(e))
            case "output": flush(); out.append(.output(e))
            case "approval": flush(); out.append(.approval(e))
            case "result":
                flush()
                if e.isError == true { out.append(.notice(e)) }
            case "system": flush(); out.append(.notice(e))
            default: break
            }
        }
        flush()
        return out
    }
}

/// "Read 2 files, edited 2 files"
func toolSummary(_ events: [TranscriptEvent]) -> String {
    var counts: [(String, String, Int)] = [] // (key, noun, n)
    func bump(_ key: String, _ noun: String) {
        if let i = counts.firstIndex(where: { $0.0 == key }) { counts[i].2 += 1 } else { counts.append((key, noun, 1)) }
    }
    for e in events where e.kind == "tool_use" {
        switch e.tool ?? "" {
        case "Read": bump("Read", "file")
        case "Write", "Edit", "MultiEdit", "NotebookEdit": bump("edited", "file")
        case "Bash": bump("ran", "command")
        case "Grep", "Glob": bump("searched", "time")
        case "WebFetch", "WebSearch": bump("browsed", "page")
        case "Task", "Agent": bump("ran", "agent")
        case "TodoWrite": bump("updated", "todo list")
        default: bump("used", "tool")
        }
    }
    if counts.isEmpty { return events.contains { $0.kind == "thinking" } ? "Thought" : "Working" }
    let parts = counts.map { key, noun, n in "\(key.lowercased()) \(n) \(noun)\(n == 1 ? "" : (noun.hasSuffix("s") ? "es" : "s"))" }
    let s = parts.joined(separator: ", ")
    return s.prefix(1).uppercased() + s.dropFirst()
}

struct SessionView: View {
    let sessionId: String
    @Environment(HubStore.self) private var store
    @State private var text = ""
    @State private var showMenu = false
    @State private var showOutputs = false
    @State private var viewing: Output?

    private var session: Session? { store.session(sessionId) }
    private var events: [TranscriptEvent] { store.transcripts[sessionId] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            SessionHeader(session: session, onMenu: { showMenu = true }, onOutputs: { showOutputs = true })
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(TranscriptItem.group(events)) { item in
                            row(item)
                        }
                        if let s = store.streaming[sessionId], !s.isEmpty {
                            AssistantText(text: s).opacity(0.85)
                        } else if session?.status == .running {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Working…").font(.subheadline).foregroundStyle(Theme.secondary)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .onChange(of: events.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: store.streaming[sessionId]?.count ?? 0) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            composer
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await store.loadTranscript(sessionId)
            store.subscribe(sessionId)
            #if DEBUG
            if ProcessInfo.processInfo.environment["AGENTHUB_OPEN_OUTPUTS"] != nil { showOutputs = true }
            #endif
        }
        .onDisappear { store.unsubscribe(sessionId) }
        .sheet(isPresented: $showMenu) { SessionMenuSheet(sessionId: sessionId) }
        .navigationDestination(isPresented: $showOutputs) {
            if let s = session { OutputsView(session: s) }
        }
        .navigationDestination(item: $viewing) { o in OutputViewer(output: o) }
    }

    private var composer: some View {
        let agent = session?.agent ?? .claude
        return Composer(placeholder: "Reply to \(agent.label)", text: $text) { t in
            store.sendPrompt(sessionId, t)
        } accessory: {
            if session?.status == .running || session?.status == .waiting {
                Button { store.interrupt(sessionId) } label: {
                    Image(systemName: "stop.fill").font(.system(size: 13))
                        .frame(width: 36, height: 36)
                        .background(Theme.sunken, in: Circle())
                }
                .accessibilityLabel("Interrupt")
            }
            Menu {
                Button("Screenshot Simulator", systemImage: "iphone") { Task { await store.screenshot(sessionId) } }
                Button("Screenshot Mac", systemImage: "laptopcomputer") { Task { await store.screenshot(sessionId, target: "mac") } }
                Button("Outputs", systemImage: "square.grid.2x2") { showOutputs = true }
            } label: {
                Image(systemName: "plus").font(.system(size: 16, weight: .medium))
                    .frame(width: 36, height: 36).background(Theme.sunken, in: Circle())
            }
            .accessibilityLabel("Attach")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder private func row(_ item: TranscriptItem) -> some View {
        switch item {
        case .user(let e):
            Text(e.text ?? "")
                .font(.body)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Theme.sunken2, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 50)
                .textSelection(.enabled)
        case .assistant(let e):
            AssistantText(text: e.text ?? "")
        case .tools(let es):
            ToolGroup(events: es)
        case .output(let e):
            if let o = e.output {
                OutputCard(output: o) { viewing = o }
            }
        case .approval(let e):
            ApprovalCard(event: e, agent: session?.agent ?? .claude) { decision in
                if let id = e.requestId { store.respond(id, decision) }
            }
        case .notice(let e):
            Label(e.text ?? "Error", systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(Theme.destructive)
                .textSelection(.enabled)
        }
    }
}

struct SessionHeader: View {
    var session: Session?
    var onMenu: () -> Void
    var onOutputs: () -> Void
    @Environment(HubStore.self) private var store

    var body: some View {
        HStack {
            IconButton(systemName: "line.3.horizontal", label: "Open sessions") {
                withAnimation(.snappy) { store.drawerOpen = true }
            }
            Spacer()
            Button(action: onMenu) {
                VStack(spacing: 1) {
                    Text(session?.name ?? "").font(.body.weight(.semibold)).lineLimit(1)
                    if let s = session {
                        HStack(spacing: 6) {
                            AgentDot(agent: s.agent, filled: s.status.filledDot, size: 7)
                            Text("\(s.project) · \(s.agent.label)\(s.status == .running || s.status == .waiting ? "" : " · \(s.status.rawValue)")")
                                .font(.caption).foregroundStyle(s.status == .waiting ? Theme.needsText : Theme.secondary)
                        }
                    }
                }
                .frame(maxWidth: 240)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Session options")
            Spacer()
            IconButton(systemName: "square.grid.2x2", label: "Outputs", action: onOutputs)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

struct AssistantText: View {
    var text: String
    var body: some View {
        Text(markdown)
            .font(Theme.serif(.body))
            .lineSpacing(4)
            .foregroundStyle(Theme.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var markdown: AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

struct ToolGroup: View {
    var events: [TranscriptEvent]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: hasError ? "exclamationmark.circle" : "wrench.and.screwdriver")
                        .font(.footnote)
                    Text(toolSummary(events)).font(.subheadline)
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(hasError ? Theme.destructive : Theme.secondary)
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Collapse tool details" : "Show tool details")
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(events.filter { $0.kind == "tool_use" }) { e in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(e.summary ?? e.tool ?? "").font(.footnote.weight(.medium))
                            if let r = events.first(where: { $0.kind == "tool_result" && $0.toolUseId == e.toolUseId }),
                               let t = r.text, !t.isEmpty {
                                Text(t.prefix(800))
                                    .font(Theme.mono(.caption2))
                                    .foregroundStyle(r.isError == true ? Theme.destructive : Theme.secondary)
                                    .lineLimit(10)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Theme.code, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
    }

    private var hasError: Bool { events.contains { $0.kind == "tool_result" && $0.isError == true } }
}

struct ApprovalCard: View {
    var event: TranscriptEvent
    var agent: AgentKind
    var respond: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail)
                .font(Theme.mono(.footnote))
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.code, in: RoundedRectangle(cornerRadius: 10))
                .lineLimit(8)
                .textSelection(.enabled)
            if let d = event.decision {
                Label(decisionText(d), systemImage: d == "deny" ? "xmark.circle" : (d == "expired" ? "clock" : "checkmark.circle"))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(d == "deny" ? Theme.destructive : Theme.secondary)
            } else {
                HStack(spacing: 8) {
                    Button { respond("allow") } label: { Text("Allow").frame(maxWidth: .infinity) }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                    Button { respond("always") } label: { Text("Always allow").frame(maxWidth: .infinity) }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                    Button { respond("deny") } label: { Text("Deny") }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(event.decision == nil ? Theme.needsBorder : Theme.hairline))
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch event.tool {
        case "Bash": "\(agent.shortLabel) wants to run"
        case "Write": "\(agent.shortLabel) wants to write"
        case "Edit", "MultiEdit", "NotebookEdit": "\(agent.shortLabel) wants to edit"
        case "WebFetch": "\(agent.shortLabel) wants to fetch"
        default: "\(agent.shortLabel) wants to use \(event.tool ?? "a tool")"
        }
    }

    private var detail: String {
        if event.tool == "Bash", let c = event.input?["command"]?.stringValue { return c }
        if let p = event.input?["file_path"]?.stringValue { return (p as NSString).lastPathComponent }
        if let u = event.input?["url"]?.stringValue { return u }
        return event.summary ?? ""
    }

    private func decisionText(_ d: String) -> String {
        switch d {
        case "allow": "Allowed"
        case "always": "Always allowed for this project"
        case "deny": "Denied"
        default: "Expired"
        }
    }
}

struct OutputCard: View {
    var output: Output
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                OutputThumb(output: output).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(output.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(output.kind == "changes"
                         ? "+\(output.additions ?? 0) −\(output.deletions ?? 0)"
                         : "\(output.fileName) · \(output.kindLabel)\(output.versionCount > 1 ? " · v\(output.versionCount)" : "")")
                        .font(.footnote).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.secondary)
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
