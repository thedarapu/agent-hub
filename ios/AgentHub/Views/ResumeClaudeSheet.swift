import SwiftUI

/// Claude Code sessions started on the Mac outside agent-hub, for one folder.
/// Picking one continues it here (or a copy, if a terminal still has it open).
struct ResumeClaudeSheet: View {
    var folder: String
    @Environment(HubStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var items: [ClaudeHistorySession]?
    @State private var error: String?
    @State private var resuming: String?

    var body: some View {
        NavigationStack {
            List {
                if items == nil && error == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                }
                if let error {
                    Text(error).foregroundStyle(Theme.destructive)
                }
                if let items, items.isEmpty {
                    Text("No Claude Code sessions in \(project) yet. Sessions you start with `claude` in a terminal on the Mac appear here.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                }
                if let items, !items.isEmpty {
                    Section {
                        ForEach(items) { h in row(h) }
                    } footer: {
                        Text("Sessions marked “Open on Mac” are still running in a terminal. Continuing one here starts a copy, so the terminal's conversation isn't changed.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .refreshable { await load() }
            .navigationTitle("Resume in \(project)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationCornerRadius(28)
        .task { await load() }
    }

    private var project: String { (folder as NSString).lastPathComponent }

    private func row(_ h: ClaudeHistorySession) -> some View {
        Button {
            Task {
                resuming = h.id
                if await store.resumeClaude(h, folder: folder) != nil { dismiss() }
                resuming = nil
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(h.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                    if let last = h.lastPrompt {
                        Text("Last: \(last)")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        Text(ISO.relative(h.lastActivityAt))
                        Text("·")
                        Text(h.promptCount == 1 ? "1 prompt" : "\(h.promptCount) prompts")
                        if h.hubSessionId != nil {
                            Text("·")
                            Text("In agent-hub").foregroundStyle(Theme.success)
                        } else if h.openInTerminal {
                            Text("·")
                            Text("Open on Mac").foregroundStyle(Theme.needsText)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
                if resuming == h.id { ProgressView() }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(resuming != nil)
        .accessibilityHint(h.hubSessionId != nil ? "Opens it" : h.openInTerminal ? "Continues a copy here" : "Continues it here")
    }

    private func load() async {
        error = nil
        do { items = try await store.claudeHistory(folder: folder) }
        catch { self.error = error.localizedDescription }
    }
}
