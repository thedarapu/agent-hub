import SwiftUI
import SwiftTerm
import UIKit

/// Codex / Amp / Shell / SSH: live terminal in the same chat frame.
struct TerminalSessionView: View {
    let sessionId: String
    @Environment(HubStore.self) private var store
    @State private var text = ""
    @State private var showMenu = false
    @State private var showOutputs = false

    private var session: Session? { store.session(sessionId) }

    var body: some View {
        VStack(spacing: 0) {
            SessionHeader(session: session, onMenu: { showMenu = true }, onOutputs: { showOutputs = true })
            TerminalPane(sessionId: sessionId)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Theme.terminalBg)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .overlay {
                    if let s = session, !s.status.isLive {
                        Text(s.status == .done ? "Process exited" : "Session \(s.status.rawValue)")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                            .frame(maxHeight: .infinity, alignment: .top)
                            .padding(.top, 14)
                    }
                }
            keyRow
            Composer(placeholder: "Send to \(session?.agent.label ?? "terminal")", text: $text) { t in
                store.sendPrompt(sessionId, t)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showMenu) { SessionMenuSheet(sessionId: sessionId) }
        .navigationDestination(isPresented: $showOutputs) {
            if let s = session { OutputsView(session: s) }
        }
    }

    private var keyRow: some View {
        let keys: [(String, String, [UInt8])] = [
            ("Enter", "Enter", [0x0d]),
            ("Esc", "Escape", [0x1b]),
            ("↑", "Up arrow", [0x1b, 0x5b, 0x41]),
            ("↓", "Down arrow", [0x1b, 0x5b, 0x42]),
            ("⌃C", "Control C", [0x03]),
            ("Tab", "Tab", [0x09]),
        ]
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(keys, id: \.0) { label, a11y, bytes in
                    Button {
                        store.terminalInput(sessionId, Data(bytes))
                    } label: {
                        Text(label)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .frame(minWidth: 44, minHeight: 40)
                            .background(Theme.sunken, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(a11y)
                }
            }
            .padding(.horizontal, 12)
        }
        .scrollIndicators(.hidden)
        .padding(.vertical, 8)
    }
}

struct TerminalPane: UIViewRepresentable {
    let sessionId: String
    @Environment(HubStore.self) private var store

    func makeCoordinator() -> Coordinator { Coordinator(sessionId: sessionId, store: store) }

    func makeUIView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: CGRect(x: 0, y: 0, width: 360, height: 400))
        tv.terminalDelegate = context.coordinator
        tv.nativeBackgroundColor = UIColor(hex: 0x1C1B19)
        tv.nativeForegroundColor = UIColor(hex: 0xE8E4DA)
        tv.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.inputAccessoryView = nil // the app has its own key row
        tv.optionAsMetaKey = true
        context.coordinator.view = tv
        store.terminalSinks[sessionId] = { [weak tv] data in
            tv?.feed(byteArray: ArraySlice([UInt8](data)))
        }
        // Subscribe once the view has a real size, so tmux paints at the right width.
        DispatchQueue.main.async { context.coordinator.subscribeIfNeeded() }
        return tv
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.store.terminalSinks[coordinator.sessionId] = nil
        coordinator.store.unsubscribe(coordinator.sessionId)
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        let sessionId: String
        let store: HubStore
        weak var view: TerminalView?
        private var subscribed = false
        private var resizeWork: DispatchWorkItem?

        init(sessionId: String, store: HubStore) {
            self.sessionId = sessionId
            self.store = store
        }

        func subscribeIfNeeded() {
            guard !subscribed, let tv = view else { return }
            subscribed = true
            let d = tv.terminalDimensions
            store.subscribe(sessionId, cols: d.cols, rows: d.rows)
        }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in
                // Debounce: rotation and keyboard animations fire many sizes.
                self.resizeWork?.cancel()
                let w = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    if self.subscribed { self.store.terminalResize(self.sessionId, cols: newCols, rows: newRows) }
                    else { self.subscribeIfNeeded() }
                }
                self.resizeWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
            }
        }

        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            Task { @MainActor in self.store.terminalInput(self.sessionId, bytes) }
        }

        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
