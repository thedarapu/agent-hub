import SwiftUI

/// Rename / session menu: editable name, read-only folder + agent, Pin, Stop, Delete.
struct SessionMenuSheet: View {
    let sessionId: String
    @Environment(HubStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmDelete = false

    private var session: Session? { store.session(sessionId) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Session name", text: $name)
                            .font(Theme.serif(.title3))
                            .submitLabel(.done)
                            .onSubmit(save)
                        Button("Save", action: save)
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == session?.name)
                    }
                } header: {
                    Text("Session name")
                } footer: {
                    Text("Named from your first message. Rename anytime.")
                }
                if let s = session {
                    Section {
                        LabeledContent("Folder", value: displayFolder(s.folder))
                        LabeledContent("Agent") {
                            HStack(spacing: 6) {
                                AgentDot(agent: s.agent, filled: s.status.filledDot)
                                Text(([s.agent.label] + (s.flags.isEmpty ? [] : [s.flagsString])).joined(separator: " · "))
                                    .lineLimit(2)
                            }
                        }
                        LabeledContent("Status", value: s.status.rawValue + (s.statusDetail.map { " — \($0)" } ?? ""))
                        if s.isTerminal {
                            LabeledContent("At the Mac") {
                                Text("tmux attach -t \(s.id)").font(Theme.mono(.footnote)).textSelection(.enabled)
                            }
                        } else if let a = s.agentSessionId {
                            LabeledContent("At the Mac") {
                                Text("claude --resume \(a)").font(Theme.mono(.caption2)).textSelection(.enabled)
                            }
                        }
                    }
                    Section {
                        Button(s.pinned ? "Unpin" : "Pin", systemImage: s.pinned ? "pin.slash" : "pin") {
                            Task { await store.patch(sessionId, pinned: !s.pinned) }
                        }
                        if s.status.isLive {
                            Button("Stop agent", systemImage: "stop.circle") {
                                Task { await store.stop(sessionId); dismiss() }
                            }
                        }
                        Button("Delete session", systemImage: "trash", role: .destructive) { confirmDelete = true }
                            .foregroundStyle(Theme.destructive)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Delete this session?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete session", role: .destructive) {
                    Task { await store.delete(sessionId); dismiss() }
                }
            } message: {
                Text("Stops the agent and removes the transcript. Files and outputs in the project stay.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(28)
        .onAppear { name = session?.name ?? "" }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        Task { await store.patch(sessionId, name: n) }
    }

    private func displayFolder(_ abs: String) -> String {
        let home = abs.range(of: #"^/Users/[^/]+"#, options: .regularExpression)
        return home.map { "~" + abs[$0.upperBound...] } ?? abs
    }
}
