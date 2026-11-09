import SwiftUI

@main
struct AgentHubApp: App {
    @State private var store = HubStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(Theme.text)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.foregrounded() }
                }
                .task { if store.pairing != nil { store.connect() } }
        }
    }
}

/// Drawer-based navigation (no tab bar), like the Claude iOS app.
struct RootView: View {
    @Environment(HubStore.self) private var store
    @GestureState private var dragX: CGFloat = 0

    private let drawerWidth: CGFloat = 318

    var body: some View {
        if store.pairing == nil {
            PairingView()
        } else {
            GeometryReader { geo in
                let width = min(drawerWidth, geo.size.width * 0.85)
                let open = store.drawerOpen
                let offset = max(0, min(width, (open ? width : 0) + dragX))
                ZStack(alignment: .leading) {
                    NavigationStack {
                        mainContent
                    }
                    .offset(x: offset)
                    .overlay {
                        if offset > 0 {
                            Theme.scrim.opacity(0.55 * offset / width)
                                .ignoresSafeArea()
                                .offset(x: offset)
                                .onTapGesture { withAnimation(.snappy) { store.drawerOpen = false } }
                                .accessibilityLabel("Close sessions")
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    DrawerView()
                        .frame(width: width)
                        .offset(x: offset - width)
                        .accessibilityHidden(!open)
                }
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .updating($dragX) { v, s, _ in
                            // Open from the left edge, close from anywhere.
                            if open || v.startLocation.x < 30 { s = v.translation.width }
                        }
                        .onEnded { v in
                            guard open || v.startLocation.x < 30 else { return }
                            withAnimation(.snappy) {
                                store.drawerOpen = (open ? width : 0) + v.predictedEndTranslation.width > width / 2
                            }
                        }
                )
            }
            .background(Theme.bg)
            .alert("Something went wrong", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.lastError ?? "")
            }
        }
    }

    @ViewBuilder private var mainContent: some View {
        if let s = store.session(store.selectedSessionId) {
            Group {
                if s.isTerminal { TerminalSessionView(sessionId: s.id) }
                else { SessionView(sessionId: s.id) }
            }
            .id(s.id)
        } else {
            HomeView()
        }
    }
}
