import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

// Thin client of agent-hubd over localhost. The daemon runs without this app.

struct DaemonConfig: Decodable {
    var port: Int
    var token: String
}

struct BarSession: Decodable, Identifiable {
    var id: String
    var name: String
    var folder: String
    var agent: String
    var status: String
    var statusDetail: String?
    var project: String { (folder as NSString).lastPathComponent }
}

struct BarMac: Decodable {
    var hostname: String
    var keepAwake: Bool
    var tailscaleIp: String?
    var tailscaleOnly: Bool
    var listening: [String]
    var port: Int
    var clients: Int?
}

struct BarActivity: Decodable, Identifiable {
    var id: Int
    var ts: String
    var origin: String
    var action: String
    var sessionId: String?
    var detail: String?
}

struct Pairing: Decodable {
    var host: String?
    var port: Int
    var token: String
    var name: String?
}

@Observable
@MainActor
final class BarModel {
    var mac: BarMac?
    var sessions: [BarSession] = []
    var activity: [BarActivity] = []
    var running = false
    var error: String?

    private var timer: Timer?

    static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/agent-hub/config.json")

    var config: DaemonConfig? {
        guard let d = try? Data(contentsOf: Self.configURL) else { return nil }
        return try? JSONDecoder().decode(DaemonConfig.self, from: d)
    }

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard let cfg = config else { throw NSError(domain: "agent-hub", code: 1, userInfo: [NSLocalizedDescriptionKey: "Daemon not configured yet"]) }
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(cfg.port)\(path)")!)
        r.httpMethod = method
        r.timeoutInterval = 4
        r.setValue("Bearer \(cfg.token)", forHTTPHeaderField: "Authorization")
        if let body {
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (d, resp) = try await URLSession.shared.data(for: r)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw NSError(domain: "agent-hub", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: String(decoding: d, as: UTF8.self)])
        }
        return d
    }

    func refresh() async {
        do {
            mac = try JSONDecoder().decode(BarMac.self, from: try await request("GET", "/mac"))
            sessions = try JSONDecoder().decode([BarSession].self, from: try await request("GET", "/sessions"))
            running = true
            error = nil
        } catch {
            running = false
            self.error = "Daemon not running"
        }
    }

    func loadActivity() async {
        activity = (try? JSONDecoder().decode([BarActivity].self, from: try await request("GET", "/activity?limit=300"))) ?? []
    }

    func set(_ key: String, _ value: Bool) async {
        _ = try? await request("PATCH", "/mac", body: [key: value])
        await refresh()
    }

    func pairing() async -> Pairing? {
        try? JSONDecoder().decode(Pairing.self, from: try await request("GET", "/pairing"))
    }

    var needsYou: Int { sessions.filter { $0.status == "waiting" }.count }
}

@main
struct AgentHubBarApp: App {
    @State private var model = BarModel()

    var body: some Scene {
        MenuBarExtra {
            BarMenu().environment(model)
        } label: {
            Image(systemName: model.needsYou > 0 ? "exclamationmark.bubble.fill" : (model.running ? "bubble.left.and.text.bubble.right" : "bubble.left.and.exclamationmark.bubble.right"))
        }
        .menuBarExtraStyle(.window)

        Window("Pair iPhone", id: "pair") { PairWindow().environment(model) }
            .windowResizability(.contentSize)
        Window("Activity log", id: "activity") { ActivityWindow().environment(model) }
    }
}

struct BarMenu: View {
    @Environment(BarModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("agent-hub").font(.headline)
                    if let m = model.mac {
                        HStack(spacing: 6) {
                            Circle().fill(.green).frame(width: 7, height: 7)
                            Text("Running").foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        Text(m.tailscaleIp.map { "\($0):\(m.port) · Tailscale" } ?? "Tailscale not detected · localhost only")
                            .font(.caption).foregroundStyle(m.tailscaleIp == nil ? .orange : .secondary)
                    } else {
                        Text(model.error ?? "Connecting…").font(.caption).foregroundStyle(.red)
                    }
                }
                Spacer()
            }
            if let m = model.mac {
                Toggle("Keep Mac awake", isOn: Binding(get: { m.keepAwake }, set: { v in Task { await model.set("keepAwake", v) } }))
                Toggle("Tailscale only", isOn: Binding(get: { m.tailscaleOnly }, set: { v in Task { await model.set("tailscaleOnly", v) } }))
                Divider()
                Text("Sessions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if model.sessions.isEmpty { Text("None").foregroundStyle(.secondary).font(.callout) }
                ForEach(model.sessions.prefix(10)) { s in
                    HStack(spacing: 8) {
                        Circle().fill(color(s.agent)).frame(width: 7, height: 7)
                        Text(s.project).lineLimit(1)
                        Text(agentLabel(s.agent)).foregroundStyle(.secondary)
                        Spacer()
                        Text(s.status == "waiting" ? "needs you" : s.status)
                            .foregroundStyle(s.status == "waiting" ? .orange : .secondary)
                    }
                    .font(.callout)
                    .help(s.name)
                }
                Divider()
                Button("Pair iPhone…") { openWindow(id: "pair"); NSApp.activate() }
                Button("Activity log") { openWindow(id: "activity"); NSApp.activate() }
            }
            Button("Open settings file") { NSWorkspace.shared.activateFileViewerSelecting([BarModel.configURL]) }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .padding(14)
        .frame(width: 300)
    }

    private func color(_ a: String) -> Color {
        switch a {
        case "claude": Color(red: 0.79, green: 0.39, blue: 0.26)
        case "codex": Color(red: 0.18, green: 0.44, blue: 0.86)
        case "amp": Color(red: 0.48, green: 0.36, blue: 0.84)
        default: .gray
        }
    }
    private func agentLabel(_ a: String) -> String {
        ["claude": "Claude", "codex": "Codex", "amp": "Amp", "shell": "Shell", "ssh": "SSH"][a] ?? a
    }
}

struct PairWindow: View {
    @Environment(BarModel.self) private var model
    @State private var image: NSImage?
    @State private var info: Pairing?

    var body: some View {
        VStack(spacing: 14) {
            Text("Scan with agent-hub on your iPhone").font(.headline)
            if let image {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 260, height: 260)
            } else {
                ProgressView().frame(width: 260, height: 260)
            }
            if let info {
                if info.host == nil {
                    Text("Tailscale isn't running on this Mac. Install and sign in to Tailscale, then reopen this window.")
                        .foregroundStyle(.orange).multilineTextAlignment(.center)
                } else {
                    Text("\(info.host!):\(info.port)").font(.system(.body, design: .monospaced))
                }
            }
            Text("The code contains the access token. Don't share it.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 340)
        .task {
            guard let p = await model.pairing() else { return }
            info = p
            let payload: [String: Any] = ["host": p.host ?? "", "port": p.port, "token": p.token, "name": p.name ?? ""]
            if let data = try? JSONSerialization.data(withJSONObject: payload) { image = qr(data) }
        }
    }

    private func qr(_ data: Data) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = data
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

struct ActivityWindow: View {
    @Environment(BarModel.self) private var model
    var body: some View {
        Table(model.activity) {
            TableColumn("Time") { e in Text(e.ts.replacingOccurrences(of: "T", with: " ").prefix(19)) }.width(150)
            TableColumn("From", value: \.origin).width(60)
            TableColumn("Action", value: \.action).width(140)
            TableColumn("Session") { e in Text(e.sessionId ?? "") }.width(70)
            TableColumn("Detail") { e in Text(e.detail ?? "").lineLimit(1) }
        }
        .frame(minWidth: 700, minHeight: 400)
        .task { await model.loadActivity() }
    }
}
