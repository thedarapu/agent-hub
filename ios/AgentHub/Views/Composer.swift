import SwiftUI
import Speech
import AVFoundation

/// Composer: rounded field, attach menu, optional folder chip, dictation / send.
struct Composer<Accessory: View>: View {
    var placeholder: String
    @Binding var text: String
    var sendLabel: String = "Send"
    /// Allow sending with empty text (e.g. "Start" a shell).
    var allowEmpty = false
    var onSend: (String) -> Void
    @ViewBuilder var accessory: Accessory

    @FocusState private var focused: Bool
    @State private var dictation = Dictation()

    private var canSend: Bool { allowEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .font(.body)
                .focused($focused)
                .padding(.top, 6)
                .padding(.horizontal, 6)
                .accessibilityLabel(placeholder)
            HStack(spacing: 8) {
                accessory
                Spacer(minLength: 0)
                Button {
                    dictation.toggle { text = $0 }
                } label: {
                    Image(systemName: dictation.isRecording ? "waveform" : "mic")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(dictation.isRecording ? Theme.destructive : Theme.secondary)
                        .symbolEffect(.pulse, isActive: dictation.isRecording)
                }
                .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate")
                Button {
                    dictation.stop()
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSend(t)
                    text = ""
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(Theme.bg)
                        .background(Circle().fill(canSend ? Theme.text : Theme.secondary.opacity(0.4)))
                }
                .disabled(!canSend)
                .accessibilityLabel(sendLabel)
            }
        }
        .padding(8)
        .padding(.leading, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.05), radius: 10, y: 2)
    }
}

extension Composer where Accessory == EmptyView {
    init(placeholder: String, text: Binding<String>, sendLabel: String = "Send", allowEmpty: Bool = false, onSend: @escaping (String) -> Void) {
        self.init(placeholder: placeholder, text: text, sendLabel: sendLabel, allowEmpty: allowEmpty, onSend: onSend) { EmptyView() }
    }
}

struct FolderChip: View {
    var name: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 13))
                Text(name).font(.subheadline.weight(.medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Theme.sunken, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Folder: \(name)")
        .accessibilityHint("Choose a project folder")
    }
}

/// On-device speech recognition for the composer mic.
@Observable
@MainActor
final class Dictation {
    var isRecording = false
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private let recognizer = SFSpeechRecognizer()

    func toggle(onText: @escaping (String) -> Void) {
        if isRecording { stop(); return }
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else { return }
                AVAudioApplication.requestRecordPermission { ok in
                    Task { @MainActor in if ok { self.start(onText: onText) } }
                }
            }
        }
    }

    private func start(onText: @escaping (String) -> Void) {
        guard let recognizer, recognizer.isAvailable else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in req.append(buf) }
        engine.prepare()
        do { try engine.start() } catch { return }
        isRecording = true
        task = recognizer.recognitionTask(with: req) { result, error in
            Task { @MainActor in
                if let result { onText(result.bestTranscription.formattedString) }
                if error != nil || (result?.isFinal ?? false) { self.stop() }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
