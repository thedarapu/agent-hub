import SwiftUI
import WebKit

/// claude.ai artifacts (canvases, pages) that Claude published in a session.
/// They are private to the account, so they load in a web view with a
/// persistent cookie store: sign in to claude.ai once and they render inline.
enum ClaudeWeb {
    /// Shared so every card and the full-screen viewer use the same sign-in.
    static let processPool = WKProcessPool()
    /// Safari's user agent: some sign-in flows refuse embedded web views.
    static let safariUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    static func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.processPool = processPool
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = safariUA
        wv.isOpaque = true
        wv.backgroundColor = .white
        return wv
    }

    static let artifactURL = try! NSRegularExpression(pattern: #"https://claude\.ai/(?:code/)?artifact/[A-Za-z0-9_-]+"#)

    static func firstArtifactURL(in text: String) -> String? {
        let r = NSRange(text.startIndex..., in: text)
        guard let m = artifactURL.firstMatch(in: text, range: r), let rr = Range(m.range, in: text) else { return nil }
        return String(text[rr])
    }
}

struct ClaudeWebView: UIViewRepresentable {
    var url: URL
    var interactive: Bool
    @Binding var reloadToken: Int
    /// Called after each load with whether claude.ai sent us to sign in.
    var onSignedOut: ((Bool) -> Void)? = nil

    func makeUIView(context: Context) -> WKWebView {
        let wv = ClaudeWeb.makeWebView()
        context.coordinator.onSignedOut = onSignedOut
        wv.navigationDelegate = context.coordinator
        wv.scrollView.isScrollEnabled = interactive
        wv.isUserInteractionEnabled = interactive
        wv.allowsBackForwardNavigationGestures = interactive
        wv.load(URLRequest(url: url))
        context.coordinator.token = reloadToken
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        if context.coordinator.token != reloadToken {
            context.coordinator.token = reloadToken
            wv.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var token = 0
        var onSignedOut: ((Bool) -> Void)?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            report(webView)
        }

        // claude.ai routes client-side, so also look again once the app has booted.
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self, weak webView] in
                if let webView { self?.report(webView) }
            }
        }

        private func report(_ wv: WKWebView) {
            guard let u = wv.url else { return }
            let signIn = u.host != "claude.ai" || u.path.hasPrefix("/login") || u.path.hasPrefix("/signin") || u.path.hasPrefix("/magic-link")
            onSignedOut?(signIn)
        }
    }
}

/// Inline card: live, non-interactive preview; tap for the full viewer.
struct CanvasCard: View {
    var url: String
    var title: String?
    @State private var open = false
    @State private var reload = 0
    @State private var signedOut = false

    var body: some View {
        Button { open = true } label: {
            VStack(alignment: .leading, spacing: 0) {
                if let u = URL(string: url) {
                    ClaudeWebView(url: u, interactive: false, reloadToken: $reload) { signedOut = $0 }
                        .frame(height: 260)
                        .allowsHitTesting(false)
                        .overlay {
                            if signedOut {
                                VStack(spacing: 8) {
                                    Image(systemName: "person.crop.circle.badge.questionmark").font(.title2)
                                    Text("Sign in to claude.ai to see canvases here")
                                        .font(.subheadline.weight(.medium))
                                        .multilineTextAlignment(.center)
                                    Text("Tap to open and sign in once").font(.footnote).foregroundStyle(Theme.secondary)
                                }
                                .padding(20)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Theme.sunken)
                            }
                        }
                }
                HStack(spacing: 10) {
                    Image(systemName: "square.on.square").font(.footnote)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title ?? "Canvas").font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("claude.ai artifact").font(.footnote).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.footnote).foregroundStyle(Theme.secondary)
                }
                .padding(12)
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title ?? "Canvas"), claude.ai artifact")
        .accessibilityHint("Opens the canvas")
        .fullScreenCover(isPresented: $open, onDismiss: { reload += 1 }) {
            if let u = URL(string: url) { CanvasViewer(url: u, title: title) }
        }
    }
}

/// Full-screen, interactive. Also where you sign in to claude.ai the first time.
struct CanvasViewer: View {
    var url: URL
    var title: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var reload = 0

    var body: some View {
        NavigationStack {
            ClaudeWebView(url: url, interactive: true, reloadToken: $reload)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title ?? "Canvas")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("Reload", systemImage: "arrow.clockwise") { reload += 1 }
                        Button("Open in Safari", systemImage: "safari") { openURL(url) }
                    }
                }
        }
    }
}

/// Inline preview of an output: a live page, the image, or rendered markdown.
struct OutputPreviewCard: View {
    var output: Output
    var action: () -> Void
    @Environment(HubStore.self) private var store

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                preview
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(output.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("\(output.fileName) · \(output.kindLabel)\(output.versionCount > 1 ? " · v\(output.versionCount)" : "")")
                            .font(.footnote).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Theme.secondary)
                }
                .padding(12)
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(output.displayTitle), \(output.kindLabel)")
        .accessibilityHint("Opens the output")
    }

    private var path: String {
        "/files/\(store.filesSession(for: output))/\(APIClient.encodePath(output.relpath))"
    }

    @ViewBuilder private var preview: some View {
        switch output.kind {
        case "image":
            AuthImage(path: path)
                .frame(maxWidth: .infinity, maxHeight: 280)
                .background(Theme.sunken)
        case "markdown":
            MarkdownPreview(path: path)
                .frame(height: 220)
                .allowsHitTesting(false)
        default:
            if let p = store.pairing {
                // Keyed by update time so a new version reloads.
                WebPreview(path: path + "?v=\(output.updatedAt)", pairing: p)
                    .frame(height: 260)
                    .allowsHitTesting(false)
            }
        }
    }
}
