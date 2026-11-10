import SwiftUI
import PhotosUI
import UIKit

/// A photo picked or taken on the phone, waiting to be sent.
struct PendingImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

extension HubStore {
    /// Uploads the images into the project, then sends the prompt with their
    /// paths so the agent can open them (Claude reads image files directly).
    func sendPrompt(_ id: String, _ text: String, images: [UIImage]) async {
        guard let api, !images.isEmpty else { return sendPrompt(id, text) }
        struct Body: Encodable { var name: String; var data: String }
        struct Saved: Decodable { var path: String }
        var paths: [String] = []
        for img in images {
            guard let jpeg = img.scaledForUpload().jpegData(compressionQuality: 0.82) else { continue }
            do {
                let saved: Saved = try await api.send("POST", "/sessions/\(id)/uploads", body: Body(name: "photo.jpg", data: jpeg.base64EncodedString()))
                paths.append(saved.path)
            } catch {
                lastError = "Couldn't upload a photo: \(error.localizedDescription)"
                return
            }
        }
        let refs = paths.map { "[Image: \($0)]" }.joined(separator: "\n")
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sendPrompt(id, t.isEmpty ? refs : t + "\n\n" + refs)
    }
}

extension UIImage {
    /// Longest side at most 2048 px: plenty for the model, quick over Tailscale.
    func scaledForUpload(maxSide: CGFloat = 2048) -> UIImage {
        let w = size.width * scale, h = size.height * scale
        let k = min(1, maxSide / max(w, h))
        let target = CGSize(width: (w * k).rounded(), height: (h * k).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: target, format: fmt).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}

/// Image references in a sent prompt: "[Image: /abs/path]" lines.
enum PromptImages {
    static func split(_ text: String) -> (text: String, paths: [String]) {
        var paths: [String] = []
        var kept: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[Image: "), t.hasSuffix("]") {
                paths.append(String(t.dropFirst(8).dropLast()))
            } else {
                kept.append(line)
            }
        }
        return (kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), paths)
    }
}

/// Thumbnails above the composer, each removable.
struct AttachmentStrip: View {
    @Binding var images: [PendingImage]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(images) { p in
                    Image(uiImage: p.image)
                        .resizable().scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button { images.removeAll { $0.id == p.id } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 20))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                                    .frame(width: 44, height: 44, alignment: .topTrailing)
                            }
                            .offset(x: 8, y: -8)
                            .accessibilityLabel("Remove photo")
                        }
                        .accessibilityLabel("Attached photo")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
        .scrollIndicators(.hidden)
    }
}

/// System camera, for "Take photo".
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// Photos in a sent message, loaded from the project through the daemon.
struct PromptImageRow: View {
    var paths: [String]
    var session: Session?
    @Environment(HubStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            ForEach(paths, id: \.self) { p in
                if let s = session, p.hasPrefix(s.folder + "/") {
                    AuthImage(path: "/files/\(s.id)/\(APIClient.encodePath(String(p.dropFirst(s.folder.count + 1))))")
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityLabel("Attached photo")
                } else {
                    Label((p as NSString).lastPathComponent, systemImage: "photo")
                        .font(.footnote).foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}

/// Photo library and camera pickers that add to the pending attachments.
struct AttachmentPickers: ViewModifier {
    @Binding var attachments: [PendingImage]
    @Binding var pickingPhotos: Bool
    @Binding var takingPhoto: Bool
    @State private var items: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $pickingPhotos, selection: $items, maxSelectionCount: 6, matching: .images)
            .onChange(of: items) { _, picked in
                guard !picked.isEmpty else { return }
                items = []
                Task {
                    for item in picked {
                        if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                            attachments.append(PendingImage(image: img))
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $takingPhoto) {
                CameraPicker { attachments.append(PendingImage(image: $0)) }.ignoresSafeArea()
            }
    }
}
