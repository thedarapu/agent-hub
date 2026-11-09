import SwiftUI
import WebKit

/// Proxies agenthub://hub/<path> to the daemon over HTTP with the bearer token,
/// so pages and their relative CSS/JS/images load without exposing the token in URLs.
final class HubSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "agenthub"
    let pairing: Pairing
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private let lock = NSLock()

    init(pairing: Pairing) { self.pairing = pairing }

    static func url(_ path: String) -> URL { URL(string: "\(scheme)://hub\(path)")! }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let u = urlSchemeTask.request.url, var comps = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return }
        comps.scheme = "http"
        comps.host = pairing.host
        comps.port = pairing.port
        guard let target = comps.url else { return }
        var req = URLRequest(url: target)
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        let key = ObjectIdentifier(urlSchemeTask)
        let task = URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lock.lock()
                let live = self.tasks.removeValue(forKey: key) != nil
                self.lock.unlock()
                guard live else { return }
                if let err { urlSchemeTask.didFailWithError(err); return }
                let http = resp as? HTTPURLResponse
                let headers = (http?.allHeaderFields as? [String: String]) ?? [:]
                let r = HTTPURLResponse(url: u, statusCode: http?.statusCode ?? 200, httpVersion: "HTTP/1.1", headerFields: headers)!
                urlSchemeTask.didReceive(r)
                urlSchemeTask.didReceive(data ?? Data())
                urlSchemeTask.didFinish()
            }
        }
        lock.lock(); tasks[key] = task; lock.unlock()
        task.resume()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        lock.lock()
        let t = tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))
        lock.unlock()
        t?.cancel()
    }
}

struct WebPreview: UIViewRepresentable {
    var path: String
    var pairing: Pairing

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(HubSchemeHandler(pairing: pairing), forURLScheme: HubSchemeHandler.scheme)
        config.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: .zero, configuration: config)
        // Pages assume a browser's white canvas; don't let the app's dark theme show through.
        wv.isOpaque = true
        wv.backgroundColor = .white
        wv.scrollView.backgroundColor = .white
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.load(URLRequest(url: HubSchemeHandler.url(path)))
        context.coordinator.loaded = path
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        if context.coordinator.loaded != path {
            context.coordinator.loaded = path
            wv.load(URLRequest(url: HubSchemeHandler.url(path)))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var loaded = "" }
}

/// Image loaded through the authenticated API.
struct AuthImage: View {
    var path: String
    @Environment(HubStore.self) private var store
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failed {
                Image(systemName: "photo").foregroundStyle(Theme.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: path) {
            guard let api = store.api else { return }
            do {
                let data = try await api.data("GET", path)
                image = await Task.detached { UIImage(data: data)?.preparingForDisplay() }.value
                failed = image == nil
            } catch { failed = true }
        }
    }
}

/// Small visual for an output: image tile, abstract page, or diff glyph.
struct OutputThumb: View {
    var output: Output
    @Environment(HubStore.self) private var store

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.sunken)
            switch output.kind {
            case "image":
                AuthImage(path: "/files/\(store.filesSession(for: output))/\(APIClient.encodePath(output.relpath))")
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            case "changes":
                VStack(alignment: .leading, spacing: 3) {
                    Capsule().fill(Theme.success.opacity(0.5)).frame(width: 30, height: 5)
                    Capsule().fill(Theme.success.opacity(0.5)).frame(width: 22, height: 5)
                    Capsule().fill(Theme.destructive.opacity(0.45)).frame(width: 26, height: 5)
                }
            default:
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.token(0xD9C9B8, 0x4A4036)).frame(height: 18)
                    Capsule().fill(Color.token(0xD6D1C6, 0x3F3C37)).frame(width: 24, height: 5)
                    Capsule().fill(Color.token(0xD6D1C6, 0x3F3C37)).frame(width: 32, height: 5)
                }
                .padding(8)
            }
        }
        .accessibilityHidden(true)
    }
}

extension HubStore {
    /// /files and /vfiles need a session in the output's folder; prefer the origin, else any live one.
    func filesSession(for o: Output) -> String {
        if sessions.contains(where: { $0.id == o.originSession }) { return o.originSession }
        return sessions.first { $0.folder == o.folder }?.id ?? o.originSession
    }
}
