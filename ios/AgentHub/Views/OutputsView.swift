import SwiftUI

/// Outputs scoped to a project, with a "This session / All of <project>" toggle.
struct OutputsView: View {
    let session: Session
    @Environment(HubStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var scopeAll = false
    @State private var outputs: [Output] = []
    @State private var loading = true
    @State private var viewing: Output?

    private var visuals: [Output] { outputs.filter { $0.kind == "page" || $0.kind == "markdown" } }
    private var images: [Output] { outputs.filter { $0.kind == "image" } }
    private var changes: [Output] { outputs.filter { $0.kind == "changes" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Outputs").font(Theme.serif(.largeTitle))
                    Text(session.project).font(.subheadline).foregroundStyle(Theme.secondary)
                }
                scopePicker
                if loading && outputs.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                if !loading && outputs.isEmpty {
                    Text(scopeAll ? "Nothing produced in \(session.project) yet." : "Nothing produced in this session yet. Pages, images and code changes show up here as the agent makes them.")
                        .font(.subheadline).foregroundStyle(Theme.secondary)
                }
                ForEach(visuals) { o in pageRow(o) }
                if !images.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(images) { o in imageTile(o) }
                    }
                }
                ForEach(changes) { o in
                    OutputCard(output: o) { viewing = o }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .navigationDestination(item: $viewing) { o in OutputViewer(output: o) }
        .refreshable { await load() }
        .task(id: "\(scopeAll)-\(store.outputsRevision)") { await load() }
    }

    private var scopePicker: some View {
        HStack(spacing: 4) {
            scopeButton("This session", on: !scopeAll) { scopeAll = false }
            scopeButton("All of \(session.project)", on: scopeAll) { scopeAll = true }
        }
        .padding(4)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func scopeButton(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 36)
                .foregroundStyle(on ? Theme.text : Theme.secondary)
                .background { if on { RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.surface) } }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func pageRow(_ o: Output) -> some View {
        Button { viewing = o } label: {
            HStack(spacing: 14) {
                OutputThumb(output: o).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 6) {
                    Text(o.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(meta(o)).font(.footnote).foregroundStyle(Theme.secondary).lineLimit(1)
                    HStack(spacing: 6) {
                        ForEach(Array(max(1, o.versionCount - 4)...max(1, o.versionCount)), id: \.self) { n in
                            Text("v\(n)")
                                .font(.caption.weight(.semibold))
                                .frame(minWidth: 32, minHeight: 28)
                                .padding(.horizontal, 2)
                                .foregroundStyle(n == o.versionCount ? Theme.bg : Theme.secondary)
                                .background(Capsule().fill(n == o.versionCount ? Theme.text : Theme.sunken2))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    private func imageTile(_ o: Output) -> some View {
        Button { viewing = o } label: {
            VStack(alignment: .leading, spacing: 8) {
                OutputThumb(output: o).aspectRatio(o.source == "simulator" ? 0.6 : 1, contentMode: .fit)
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(o.source == "simulator" ? "After build · \(ISO.relative(o.updatedAt))" : "\(o.versionCount) version\(o.versionCount == 1 ? "" : "s") · \(ISO.short(o.updatedAt))")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            .padding(10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    private func meta(_ o: Output) -> String {
        if scopeAll { return "\(o.fileName) · \(o.versionCount) version\(o.versionCount == 1 ? "" : "s") · \(ISO.relative(o.updatedAt))" }
        return "v\(o.versionCount) · \(o.fileName) · \(ISO.relative(o.updatedAt))"
    }

    private func load() async {
        guard let api = store.api else { return }
        loading = true
        var q = ["project": store.relFolder(session.folder)]
        if !scopeAll { q["session"] = session.id }
        do { outputs = try await api.get("/outputs", query: q) } catch { store.lastError = error.localizedDescription }
        loading = false
        #if DEBUG
        if ProcessInfo.processInfo.environment["AGENTHUB_OPEN_VIEWER"] != nil, viewing == nil { viewing = outputs.first }
        #endif
    }
}
