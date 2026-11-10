import SwiftUI
import PhotosUI

/// Transcript items after grouping raw events for display.
enum TranscriptItem: Identifiable {
    case user(TranscriptEvent)
    case assistant(TranscriptEvent)
    case tools([TranscriptEvent])
    case output(TranscriptEvent)
    case approval(TranscriptEvent)
    case notice(TranscriptEvent)
    case thinking(TranscriptEvent)
    /// A claude.ai artifact Claude published (shown once, where it was last updated).
    case canvas(url: String, title: String?)

    var id: String {
        switch self {
        case .user(let e), .assistant(let e), .output(let e), .approval(let e), .notice(let e), .thinking(let e): "e\(e.seq)"
        case .tools(let es): "t\(es.first?.seq ?? 0)"
        case .canvas(let url, _): "c\(url)"
        }
    }

    /// Artifact links in a group of tool events: the `url` of a publish/open,
    /// or the link in a create's result. Reads and listings don't count.
    static func canvases(in tools: [TranscriptEvent], titles: inout [String: String]) -> [String] {
        var urls: [String] = []
        for e in tools where e.kind == "tool_use" && e.tool == "Artifact" {
            let action = e.input?["action"]?.stringValue ?? "publish"
            guard ["publish", "open"].contains(action), e.input?["asset"] == nil else { continue }
            var url = e.input?["url"]?.stringValue
            if url == nil, let r = tools.first(where: { $0.kind == "tool_result" && $0.toolUseId == e.toolUseId }),
               r.isError != true, let t = r.text {
                url = ClaudeWeb.firstArtifactURL(in: t)
            }
            guard let u = url else { continue }
            if let t = e.input?["title"]?.stringValue, !t.isEmpty { titles[u] = t }
            if !urls.contains(u) { urls.append(u) }
        }
        return urls
    }

    static func group(_ events: [TranscriptEvent]) -> [TranscriptItem] {
        var out: [TranscriptItem] = []
        var tools: [TranscriptEvent] = []
        var titles: [String: String] = [:]
        func flush() {
            defer { tools = [] }
            guard !tools.isEmpty else { return }
            defer {
                for u in canvases(in: tools, titles: &titles) {
                    out.removeAll { if case .canvas(u, _) = $0 { return true }; return false }
                    out.append(.canvas(url: u, title: titles[u]))
                }
            }
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
            case "tool_use", "tool_result": tools.append(e)
            case "thinking": flush(); out.append(.thinking(e))
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
    /// Set for Claude running in a terminal: switch to the live screen.
    var onShowTerminal: (() -> Void)? = nil
    @Environment(HubStore.self) private var store
    @State private var text = ""
    @State private var showMenu = false
    @State private var showOutputs = false
    @State private var viewing: Output?
    /// Bumped on send so the transcript jumps to the bottom.
    @State private var sentTick = 0
    @State private var attachments: [PendingImage] = []
    @State private var pickingPhotos = false
    @State private var takingPhoto = false

    private var session: Session? { store.session(sessionId) }
    private var events: [TranscriptEvent] { store.transcripts[sessionId] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            SessionHeader(session: session, onMenu: { showMenu = true }, onOutputs: { showOutputs = true },
                          switchView: onShowTerminal.map { ("terminal", "Show terminal", $0) })
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if events.isEmpty, session?.isClaudeTerminal == true {
                            Text("The conversation in the Mac terminal shows up here.")
                                .font(.subheadline).foregroundStyle(Theme.secondary)
                        }
                        ForEach(TranscriptItem.group(events)) { item in
                            row(item)
                        }
                        if let s = session, s.isClaudeTerminal, s.status == .waiting {
                            if let p = s.prompt {
                                TerminalPromptCard(prompt: p) { store.answerPrompt(sessionId, key: $0) }
                            } else if let show = onShowTerminal {
                                Button("Claude is waiting in the terminal", systemImage: "terminal", action: show)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Theme.needsText)
                            }
                        }
                        ForEach(Array((session?.claudeQueue ?? []).enumerated()), id: \.offset) { _, q in
                            QueuedBubble(text: q, note: "Queued in Claude", cancel: nil)
                        }
                        ForEach(session?.queued ?? []) { q in
                            QueuedBubble(text: q.text) { store.unqueue(sessionId, queuedId: q.id) }
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
                #if DEBUG
                .task(id: events.count) {
                    // Simulator checks: AGENTHUB_SCROLL_TO=canvas jumps to the last canvas card.
                    guard ProcessInfo.processInfo.environment["AGENTHUB_SCROLL_TO"] == "canvas" else { return }
                    try? await Task.sleep(for: .milliseconds(600))
                    if let c = TranscriptItem.group(events).last(where: { if case .canvas = $0 { return true }; return false }) {
                        proxy.scrollTo(c.id, anchor: .center)
                    }
                }
                #endif
                .onChange(of: queuedCount) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: sentTick) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: session?.status) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: session?.prompt) { _, p in if p != nil { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } }
                .onChange(of: store.streaming[sessionId]?.count ?? 0) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            composer
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await store.loadTranscript(sessionId)
            store.subscribe(sessionId, terminal: session?.isTerminal != true)
            #if DEBUG
            if ProcessInfo.processInfo.environment["AGENTHUB_OPEN_OUTPUTS"] != nil { showOutputs = true }
            #endif
        }
        // Switching to the terminal view may have subscribed already; keep that one.
        .onDisappear { store.unsubscribe(sessionId, onlyIfTerminal: session?.isTerminal == true ? false : nil) }
        .sheet(isPresented: $showMenu) { SessionMenuSheet(sessionId: sessionId) }
        .navigationDestination(isPresented: $showOutputs) {
            if let s = session { OutputsView(session: s) }
        }
        .navigationDestination(item: $viewing) { o in OutputViewer(output: o) }
        .modifier(AttachmentPickers(attachments: $attachments, pickingPhotos: $pickingPhotos, takingPhoto: $takingPhoto))
    }

    private var queuedCount: Int { (session?.queued?.count ?? 0) + (session?.claudeQueue?.count ?? 0) }

    private var composer: some View {
        let agent = session?.agent ?? .claude
        let busy = session?.status == .running || session?.status == .waiting
        return VStack(spacing: 0) {
        if !attachments.isEmpty { AttachmentStrip(images: $attachments) }
        Composer(placeholder: busy ? "Queue for after this turn…" : "Reply to \(agent.label)", text: $text, allowEmpty: !attachments.isEmpty) { t in
            let imgs = attachments.map(\.image)
            attachments = []
            if imgs.isEmpty { store.sendPrompt(sessionId, t) }
            else { Task { await store.sendPrompt(sessionId, t, images: imgs) } }
            sentTick += 1
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
                Button("Photo Library", systemImage: "photo.on.rectangle") { pickingPhotos = true }
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo", systemImage: "camera") { takingPhoto = true }
                }
                Divider()
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
    }

    @ViewBuilder private func row(_ item: TranscriptItem) -> some View {
        switch item {
        case .user(let e):
            let parts = PromptImages.split(e.text ?? "")
            VStack(alignment: .trailing, spacing: 8) {
                if !parts.paths.isEmpty { PromptImageRow(paths: parts.paths, session: session) }
                if !parts.text.isEmpty {
                    Text(parts.text)
                        .font(.body)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(Theme.sunken2, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 50)
        case .thinking(let e):
            ThinkingText(text: e.text ?? "")
        case .assistant(let e):
            AssistantText(text: e.text ?? "")
        case .tools(let es):
            ToolGroup(events: es)
        case .output(let e):
            if let o = e.output {
                if o.kind == "changes" { OutputCard(output: o) { viewing = o } }
                else { OutputPreviewCard(output: o) { viewing = o } }
            }
        case .canvas(let url, let title):
            CanvasCard(url: url, title: title)
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
    /// (symbol, accessibility label, action): chat ⇄ terminal for Claude in a terminal.
    var switchView: (String, String, () -> Void)? = nil
    @Environment(HubStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            IconButton(systemName: "line.3.horizontal", label: "Open sessions") {
                withAnimation(.snappy) { store.drawerOpen = true }
            }
            if switchView != nil { Color.clear.frame(width: 44, height: 44) } // keeps the title centred
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
            if let sw = switchView {
                IconButton(systemName: sw.0, label: sw.1, action: sw.2)
            }
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

/// A message held until Claude finishes its turn.
struct QueuedBubble: View {
    var text: String
    var note = "Queued"
    /// nil: can't be cancelled from the phone (it's in Claude's own queue).
    var cancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(text)
                .font(.body)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                .foregroundStyle(Theme.secondary)
            HStack(spacing: 10) {
                Label(note, systemImage: "clock").font(.caption)
                if let cancel { Button("Cancel", action: cancel).font(.caption.weight(.medium)) }
            }
            .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 50)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Queued: \(text)")
        .accessibilityAction(named: "Cancel") { cancel?() }
    }
}

/// Claude's thinking (the short status lines Claude Code shows), dimmed; tap to expand.
struct ThinkingText: View {
    var text: String
    @State private var expanded = false

    var body: some View {
        Button { withAnimation(.snappy) { expanded.toggle() } } label: {
            Text(text)
                .font(.subheadline)
                .italic()
                .foregroundStyle(Theme.secondary)
                .lineLimit(expanded ? nil : 3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Thinking: \(text)")
        .accessibilityHint(expanded ? "Collapse" : "Show all")
    }
}

/// A selection menu Claude is showing in its terminal UI (permission prompts and the like).
struct TerminalPromptCard: View {
    var prompt: TerminalPrompt
    var choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt.question).font(.subheadline.weight(.medium))
            if !prompt.context.isEmpty {
                Text(prompt.context)
                    .font(Theme.mono(.footnote))
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.code, in: RoundedRectangle(cornerRadius: 10))
                    .lineLimit(8)
                    .textSelection(.enabled)
            }
            VStack(spacing: 8) {
                ForEach(Array(prompt.options.enumerated()), id: \.element.key) { i, o in
                    Button { choose(o.key) } label: {
                        Text(o.label)
                            .font(.subheadline.weight(.medium))
                            .multilineTextAlignment(.leading)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(PillButtonStyle(kind: i == 0 ? .primary : .secondary))
                    .accessibilityLabel("Option \(o.key): \(o.label)")
                }
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.needsBorder))
        .accessibilityElement(children: .contain)
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
