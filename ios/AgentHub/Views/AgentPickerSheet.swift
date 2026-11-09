import SwiftUI

struct AgentPickerSheet: View {
    @Environment(HubStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var presets: [Preset] = []
    @State private var naming = false
    @State private var presetName = ""

    private let models: [(String, String)] = [("", "Default"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("fable", "Fable")]
    private let modes: [(String, String)] = [("", "Default"), ("plan", "Plan"), ("acceptEdits", "Accept edits"), ("auto", "Auto")]

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(AgentKind.allCases) { a in
                        agentRow(a)
                    }
                    if !folderPresets.isEmpty {
                        Text("Presets for \(store.draftProject)").font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondary)
                            .padding(.top, 12)
                        ForEach(folderPresets) { p in
                            Button {
                                store.applyPreset(p)
                            } label: {
                                HStack {
                                    AgentDot(agent: p.agent, filled: true)
                                    VStack(alignment: .leading) {
                                        Text(p.label).font(.subheadline.weight(.medium))
                                        Text("\(p.agent.rawValue) \(p.flags.map(shellQuote).joined(separator: " "))")
                                            .font(Theme.mono(.caption)).foregroundStyle(Theme.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(12)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Save preset") { naming = true }
                        .disabled(store.draftFolder.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Save preset", isPresented: $naming) {
                TextField("Name", text: $presetName)
                Button("Save") {
                    let name = presetName.isEmpty ? "\(store.draftProject): \(store.draftAgent.rawValue) \(store.draftFlags)" : presetName
                    Task {
                        await store.savePreset(label: name)
                        presets = await store.loadPresets()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(store.draftAgent.rawValue) \(store.draftFlags) in \(store.draftProject)")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(28)
        .task { presets = await store.loadPresets() }
    }

    private var folderPresets: [Preset] {
        guard let base = store.mac?.baseFolder else { return [] }
        let abs = store.draftFolder.isEmpty ? base : (base as NSString).appendingPathComponent(store.draftFolder)
        return presets.filter { $0.folder == abs }
    }

    @ViewBuilder private func agentRow(_ a: AgentKind) -> some View {
        @Bindable var store = store
        let selected = store.draftAgent == a
        VStack(alignment: .leading, spacing: 12) {
            Button {
                store.draftAgent = a
            } label: {
                HStack(spacing: 12) {
                    AgentDot(agent: a, filled: true, size: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.label).font(.body.weight(.semibold))
                        Text(a.subtitle).font(.footnote).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    if selected { Image(systemName: "checkmark").font(.body.weight(.semibold)) }
                    if !installed(a) { Text("Not found").font(.caption).foregroundStyle(Theme.destructive) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])

            if selected {
                if a == .claude {
                    pills("Model", models, selection: $store.claudeModel)
                    pills("Mode", modes, selection: $store.claudeMode)
                }
                if a == .ssh {
                    let hosts = store.mac?.sshHosts ?? ["homeserver"]
                    pills("Host", hosts.map { ($0, $0) }, selection: $store.draftSSHHost)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Extra flags, passed through as-is").font(.footnote).foregroundStyle(Theme.secondary)
                    TextField("e.g. --verbose", text: Binding(
                        get: { store.extraFlags[a.rawValue] ?? "" },
                        set: { store.extraFlags[a.rawValue] = $0 }
                    ))
                    .font(Theme.mono(.subheadline))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 12))
                    if !store.draftFlags.isEmpty {
                        Text("\(a.rawValue) \(store.draftFlags)").font(Theme.mono(.caption)).foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(selected ? Theme.text.opacity(0.6) : Theme.hairline))
    }

    private func installed(_ a: AgentKind) -> Bool {
        guard let agents = store.mac?.agents else { return true }
        let name = a == .shell ? "git" : (a == .ssh ? "git" : a.rawValue)
        return agents.first { $0.name == name }?.path != nil
    }

    private func pills(_ title: String, _ options: [(String, String)], selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote).foregroundStyle(Theme.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(options, id: \.0) { value, label in
                        let on = selection.wrappedValue == value
                        Button(label) { selection.wrappedValue = value }
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .foregroundStyle(on ? Theme.bg : Theme.text)
                            .background(Capsule().fill(on ? Theme.text : Theme.sunken2))
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}
