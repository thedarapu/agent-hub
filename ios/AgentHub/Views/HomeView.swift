import SwiftUI

/// Home / new session: agent picker on top, serif greeting, quick actions, composer.
struct HomeView: View {
    @Environment(HubStore.self) private var store
    @State private var text = ""
    @State private var showAgents = false
    @State private var showFolders = false
    @State private var creating = false

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            header
            Spacer()
            VStack(alignment: .leading, spacing: 28) {
                Text(greeting)
                    .font(Theme.serif(.largeTitle))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 4) {
                    if let last = store.lastSession(inFolder: store.draftFolder) {
                        quick("arrow.counterclockwise", "Continue last session") { store.selectedSessionId = last.id }
                    }
                    if store.draftAgent.isStructured || store.draftAgent == .codex || store.draftAgent == .amp {
                        quick("arrow.triangle.branch", "Review uncommitted changes") {
                            start("Review the uncommitted changes in this repo (git status / git diff). Summarize what changed and flag anything risky.")
                        }
                        quick("play", "Build and run in Simulator") {
                            start("Build the app and run it in the iOS Simulator (boot one if needed, install and launch the app). Tell me if anything fails.")
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            Spacer()
            Composer(
                placeholder: store.draftAgent.isStructured || store.draftAgent == .codex || store.draftAgent == .amp
                    ? "Message \(store.draftAgent.label)" : "Command to run (optional)",
                text: $text,
                sendLabel: "Start session",
                allowEmpty: !store.draftAgent.isStructured && !creating,
                onSend: { start($0) }
            ) {
                Menu {
                    Button("Choose folder…", systemImage: "folder") { showFolders = true }
                    Button("Agent and flags…", systemImage: "slider.horizontal.3") { showAgents = true }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 36, height: 36)
                        .background(Theme.sunken, in: Circle())
                }
                .accessibilityLabel("Attach")
                FolderChip(name: store.draftProject) { showFolders = true }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showAgents) { AgentPickerSheet() }
        .sheet(isPresented: $showFolders) {
            FolderPickerSheet { store.draftFolder = $0 }
        }
    }

    private var greeting: String {
        store.draftFolder.isEmpty ? "What are we building today?" : "What are we building in \(store.draftProject) today?"
    }

    private var header: some View {
        HStack {
            IconButton(systemName: "line.3.horizontal", label: "Open sessions") {
                withAnimation(.snappy) { store.drawerOpen = true }
            }
            Spacer()
            Button { showAgents = true } label: {
                HStack(spacing: 8) {
                    AgentDot(agent: store.draftAgent, filled: true, size: 9)
                    Text(store.draftAgent.label).font(.body.weight(.semibold))
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.secondary)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(Theme.sunken, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Agent: \(store.draftAgent.label)")
            .accessibilityHint("Choose agent and flags")
            Spacer()
            IconButton(systemName: "square.and.pencil", label: "New session") { text = "" }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }

    private func quick(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(Theme.secondary).frame(width: 20)
                Text(title).font(.body)
                Spacer()
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func start(_ prompt: String) {
        guard !creating else { return }
        if store.draftFolder.isEmpty && store.draftAgent != .ssh {
            showFolders = true
            text = prompt
            return
        }
        creating = true
        Task {
            await store.createSession(prompt: prompt)
            creating = false
        }
    }
}
