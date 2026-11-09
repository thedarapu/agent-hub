import SwiftUI

/// Mac status from the drawer footer: keep-awake, Tailscale-only, agents, activity log.
struct MacSheet: View {
    @Environment(HubStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var activity: [ActivityEntry] = []
    @State private var confirmUnpair = false

    var body: some View {
        NavigationStack {
            Form {
                if let m = store.mac {
                    Section {
                        LabeledContent("Status", value: store.connection == .connected ? "Connected" : "Offline")
                        LabeledContent("Address", value: "\(m.tailscaleIp ?? store.pairing?.host ?? "—"):\(m.port)")
                        Toggle("Keep Mac awake", isOn: Binding(get: { m.keepAwake }, set: { v in Task { await store.setMac(keepAwake: v) } }))
                        Toggle("Tailscale only", isOn: Binding(get: { m.tailscaleOnly }, set: { v in Task { await store.setMac(tailscaleOnly: v) } }))
                    } header: { Text(m.hostname) } footer: {
                        Text("Tailscale only: the daemon listens on the Tailscale address and localhost, never on Wi-Fi.")
                    }
                    Section("Agents on the Mac") {
                        ForEach(m.agents, id: \.name) { a in
                            LabeledContent(a.name, value: a.path == nil ? "not found" : (a.version ?? "installed"))
                        }
                    }
                } else {
                    Section { Text(store.connection == .connecting ? "Connecting…" : "Mac offline").foregroundStyle(Theme.secondary) }
                }
                Section("Activity log") {
                    if activity.isEmpty { Text("No activity yet").foregroundStyle(Theme.secondary) }
                    ForEach(activity) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(e.action).font(.subheadline.weight(.medium))
                                Spacer()
                                Text(ISO.relative(e.ts)).font(.caption).foregroundStyle(Theme.secondary)
                            }
                            if let d = e.detail, !d.isEmpty {
                                Text(d).font(.caption).foregroundStyle(Theme.secondary).lineLimit(2)
                            }
                            Text([e.origin, e.sessionId].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(Theme.secondary)
                        }
                    }
                }
                Section {
                    Button("Unpair this iPhone", role: .destructive) { confirmUnpair = true }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Unpair from this Mac?", isPresented: $confirmUnpair) {
                Button("Unpair", role: .destructive) { store.unpair(); dismiss() }
            }
            .task { activity = (try? await store.api?.get("/activity", query: ["limit": "100"])) ?? [] }
        }
        .presentationCornerRadius(28)
    }
}
