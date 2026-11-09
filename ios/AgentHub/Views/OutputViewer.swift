import SwiftUI

/// Full-screen output viewer: Preview / Code, version strip, Compare, and feedback to the agent.
struct OutputViewer: View {
    let output: Output
    @Environment(HubStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [OutputVersion] = []
    @State private var selected: OutputVersion?
    @State private var showCode = false
    @State private var comparing = false
    @State private var code = ""
    @State private var feedback = ""

    private var sid: String { store.filesSession(for: output) }
    private var origin: Session? { store.session(output.originSession) ?? store.session(sid) }

    var body: some View {
        VStack(spacing: 0) {
            if output.kind == "changes" {
                DiffView(text: code)
            } else {
                if output.kind != "image" {
                    Picker("Mode", selection: $showCode) {
                        Text("Preview").tag(false)
                        Text("Code").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
                content
                versionStrip
            }
            if let s = origin {
                Composer(placeholder: "Ask \(s.agent.label) to change this", text: $feedback, sendLabel: "Send feedback") { t in
                    sendFeedback(t, to: s)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .background(Theme.bg)
        .navigationTitle(output.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(output.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(Theme.secondary)
                }
            }
        }
        .task { await loadVersions() }
        .task(id: "\(selected?.id ?? "")-\(showCode)") { await loadCodeIfNeeded() }
    }

    private var subtitle: String {
        if output.kind == "changes" { return "+\(output.additions ?? 0) −\(output.deletions ?? 0) · \(output.files?.count ?? 0) files" }
        guard let v = selected else { return output.fileName }
        let mine = v.sessionId == store.selectedSessionId ? " · this session" : ""
        return "v\(v.n) of \(versions.count)\(mine)"
    }

    @ViewBuilder private var content: some View {
        if let v = selected {
            if comparing, let prev = previous(of: v) {
                VStack(spacing: 6) {
                    pane(prev, label: "v\(prev.n) · \(ISO.short(prev.createdAt))")
                    pane(v, label: "v\(v.n) · \(ISO.short(v.createdAt))")
                }
                .padding(.horizontal, 12)
            } else {
                pane(v, label: nil).padding(.horizontal, 12)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func pane(_ v: OutputVersion, label: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label { Text(label).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary) }
            Group {
                if showCode && output.kind != "image" {
                    ScrollView([.vertical, .horizontal]) {
                        Text(comparing && v.id != selected?.id ? "Compare shows previews; switch to Preview." : code)
                            .font(Theme.mono(.caption))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(Theme.code)
                } else if output.kind == "image" {
                    AuthImage(path: path(for: v)).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if output.kind == "markdown" {
                    MarkdownPreview(path: path(for: v))
                } else if let p = store.pairing {
                    WebPreview(path: path(for: v), pairing: p)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    private var versionStrip: some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(versions) { v in
                            let on = v.id == selected?.id
                            Button { selected = v } label: {
                                Text("v\(v.n) · \(v.id == versions.last?.id ? "now" : ISO.short(v.createdAt))")
                                    .font(.footnote.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 36)
                                    .foregroundStyle(on ? Theme.bg : Theme.secondary)
                                    .background(Capsule().fill(on ? Theme.text : Theme.sunken2))
                            }
                            .buttonStyle(.plain)
                            .id(v.id)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .onChange(of: versions.count) { _, _ in if let l = versions.last { proxy.scrollTo(l.id) } }
            }
            if versions.count > 1 {
                Button(comparing ? "Done" : "Compare") { comparing.toggle(); if comparing { showCode = false } }
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .overlay(Capsule().strokeBorder(Theme.hairline))
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func previous(of v: OutputVersion) -> OutputVersion? {
        versions.last { $0.n < v.n }
    }

    private func path(for v: OutputVersion) -> String {
        "/vfiles/\(sid)/\(v.id)/\(APIClient.encodePath(output.relpath))"
    }

    private func loadVersions() async {
        guard let api = store.api else { return }
        if output.kind == "changes" {
            if let d = try? await api.data("GET", "/outputs/\(output.id)/diff") { code = String(decoding: d, as: UTF8.self) }
            return
        }
        do {
            versions = try await api.get("/outputs/\(output.id)/versions")
            selected = versions.last
        } catch { store.lastError = error.localizedDescription }
    }

    private func loadCodeIfNeeded() async {
        guard showCode, let v = selected, let api = store.api else { return }
        if let d = try? await api.data("GET", path(for: v)) { code = String(decoding: d, as: UTF8.self) }
    }

    private func sendFeedback(_ text: String, to s: Session) {
        let ver = selected.map { " (v\($0.n))" } ?? ""
        let msg = "About `\(output.relpath)`\(ver): \(text)"
        store.sendPrompt(s.id, msg)
        store.selectedSessionId = s.id
        dismiss()
    }
}

struct MarkdownPreview: View {
    var path: String
    @Environment(HubStore.self) private var store
    @State private var text = ""
    var body: some View {
        ScrollView {
            Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .full))) ?? AttributedString(text))
                .font(Theme.serif(.body))
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.surface)
        .task(id: path) {
            if let d = try? await store.api?.data("GET", path) { text = String(decoding: d, as: UTF8.self) }
        }
    }
}

struct DiffView: View {
    var text: String
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : String(line))
                        .font(Theme.mono(.caption))
                        .foregroundStyle(color(line))
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(bg(line))
                }
            }
            .textSelection(.enabled)
        }
        .background(Theme.surface)
    }
    private func color(_ l: Substring) -> Color {
        if l.hasPrefix("@@") { return Theme.secondary }
        if l.hasPrefix("+") && !l.hasPrefix("+++") { return Theme.success }
        if l.hasPrefix("-") && !l.hasPrefix("---") { return Theme.destructive }
        return Theme.text
    }
    private func bg(_ l: Substring) -> Color {
        if l.hasPrefix("+") && !l.hasPrefix("+++") { return Theme.success.opacity(0.08) }
        if l.hasPrefix("-") && !l.hasPrefix("---") { return Theme.destructive.opacity(0.08) }
        return .clear
    }
}
