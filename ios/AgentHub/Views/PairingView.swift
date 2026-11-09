import SwiftUI
import AVFoundation

/// First run: scan the QR from the Mac menu-bar app (or enter details by hand).
struct PairingView: View {
    @Environment(HubStore.self) private var store
    @State private var scanning = false
    @State private var host = ""
    @State private var port = "7420"
    @State private var token = ""
    @State private var error: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Pair with your Mac").font(Theme.serif(.largeTitle))
                    Text("Open agent-hub in the Mac menu bar, choose “Pair iPhone”, and scan the code. Both devices need Tailscale.")
                        .foregroundStyle(Theme.secondary)
                    Button { scanning = true } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle())

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Or enter manually").font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondary)
                        field("Tailscale IP or name", text: $host)
                        field("Port", text: $port).keyboardType(.numberPad)
                        field("Token", text: $token)
                        Button {
                            Task { await connect(Pairing(host: host, port: Int(port) ?? 7420, token: token, name: nil)) }
                        } label: {
                            Text(testing ? "Connecting…" : "Connect").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .disabled(host.isEmpty || token.isEmpty || testing)
                    }
                    if let error { Text(error).foregroundStyle(Theme.destructive).font(.subheadline) }
                }
                .padding(24)
            }
            .background(Theme.bg)
            .sheet(isPresented: $scanning) {
                QRScanner { code in
                    scanning = false
                    guard let data = code.data(using: .utf8), let p = try? JSONDecoder().decode(Pairing.self, from: data) else {
                        error = "That QR code isn't an agent-hub pairing code."
                        return
                    }
                    Task { await connect(p) }
                }
                .ignoresSafeArea()
            }
        }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline))
    }

    private func connect(_ p: Pairing) async {
        testing = true
        defer { testing = false }
        do {
            let _: MacStatus = try await APIClient(pairing: p).get("/mac")
            error = nil
            store.pair(p)
        } catch {
            self.error = "Couldn't reach \(p.host):\(p.port) — \(error.localizedDescription). Is Tailscale on for both devices?"
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onCode = onCode
        return vc
    }
    func updateUIViewController(_ vc: ScannerVC, context: Context) {}

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                let l = UILabel()
                l.text = "Camera unavailable"
                l.textColor = .white
                l.frame = view.bounds
                l.textAlignment = .center
                view.addSubview(l)
                return
            }
            session.addInput(input)
            let out = AVCaptureMetadataOutput()
            session.addOutput(out)
            out.setMetadataObjectsDelegate(self, queue: .main)
            out.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objs: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let s = (objs.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            done = true
            onCode?(s)
        }
    }
}
