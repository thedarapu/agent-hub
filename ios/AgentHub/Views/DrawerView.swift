import SwiftUI

struct DrawerView: View {
    @Environment(HubStore.self) private var store
    @State private var query = ""
    @State private var showFolders = false
    @State private var showMac = false

    private var filtered: (waiting: [Session], recent: [Session]) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let match: (Session) -> Bool = { s in
            q.isEmpty || s.name.lowercased().contains(q) || s.project.lowercased().contains(q) || s.agent.label.lowercased().contains(q)
        }
        return (store.waitingSessions.filter(match), store.recentSessions.filter(match))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                TextField("Search", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Theme.sunken, in: Capsule())

            VStack(alignment: .leading, spacing: 2) {
                drawerAction("square.and.pencil", "New session") {
                    store.selectedSessionId = nil
                    close()
                }
                drawerAction("folder", "Projects") { showFolders = true }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    let f = filtered
                    if !f.waiting.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Needs you").font(.footnote.weight(.semibold)).foregroundStyle(Theme.needsText)
                                .padding(.leading, 8).padding(.bottom, 4)
                            ForEach(f.waiting) { s in row(s, highlighted: true) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recent").font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondary)
                            .padding(.leading, 8).padding(.bottom, 4)
                        if f.recent.isEmpty {
                            Text(query.isEmpty ? "No sessions yet" : "No matches")
                                .font(.subheadline).foregroundStyle(Theme.secondary).padding(.leading, 8)
                        }
                        ForEach(f.recent) { s in row(s, highlighted: false) }
                    }
                }
            }
            .scrollIndicators(.hidden)

            macFooter
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bg)
        .sheet(isPresented: $showFolders) {
            FolderPickerSheet { rel in
                store.draftFolder = rel
                store.selectedSessionId = nil
                close()
            }
        }
        .sheet(isPresented: $showMac) { MacSheet() }
    }

    private func close() { withAnimation(.snappy) { store.drawerOpen = false } }

    private func drawerAction(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 22)
                Text(title).font(.body.weight(.medium))
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ s: Session, highlighted: Bool) -> some View {
        Button {
            store.selectedSessionId = s.id
            close()
        } label: {
            HStack(spacing: 12) {
                AgentDot(agent: s.agent, filled: s.status.filledDot)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if s.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Theme.secondary) }
                        Text(s.name).font(.subheadline.weight(highlighted ? .medium : .regular)).lineLimit(1)
                    }
                    Text(s.drawerSubtitle).font(.footnote).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 52)
            .background {
                if highlighted { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.needsBg) }
                else if store.selectedSessionId == s.id { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.sunken) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(highlighted ? "Needs your attention" : "")
    }

    private var macFooter: some View {
        Button { showMac = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer").font(.title3).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.mac?.hostname ?? store.pairing?.name ?? "Mac").font(.subheadline.weight(.medium))
                    Text(statusText).font(.footnote).foregroundStyle(statusColor)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 52)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusText: String {
        switch store.connection {
        case .connected: store.mac?.keepAwake == true ? "Connected · awake" : "Connected"
        case .connecting: "Connecting…"
        case .offline(let why): why
        case .unpaired: "Not paired"
        }
    }

    private var statusColor: Color {
        if case .connected = store.connection { return Theme.success }
        if case .offline = store.connection { return Theme.destructive }
        return Theme.secondary
    }
}
