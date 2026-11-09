import SwiftUI

/// Breadcrumb from ~/workspace, search, recent projects, drill-in, new folder, "Use <folder>".
struct FolderPickerSheet: View {
    var onPick: (String) -> Void
    @Environment(HubStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var listing: FolderListing?
    @State private var query = ""
    @State private var error: String?
    @State private var newFolder = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                if path.isEmpty && query.isEmpty && !recents.isEmpty {
                    Section("Recent") {
                        ForEach(recents) { f in folderRow(f) }
                    }
                }
                Section(path.isEmpty ? "workspace" : (path as NSString).lastPathComponent) {
                    if listing == nil && error == nil { ProgressView() }
                    if let error { Text(error).foregroundStyle(Theme.destructive) }
                    ForEach(filtered) { f in folderRow(f) }
                    Button { newFolder = true } label: {
                        Label("New folder in \(path.isEmpty ? "workspace" : (path as NSString).lastPathComponent)", systemImage: "folder.badge.plus")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search folders")
            .safeAreaInset(edge: .top) { breadcrumb }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onPick(path)
                    dismiss()
                } label: {
                    Text("Use \(path.isEmpty ? "workspace" : (path as NSString).lastPathComponent)").frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButtonStyle())
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .background(Theme.bg)
            }
            .navigationTitle("Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .alert("New folder", isPresented: $newFolder) {
                TextField("Name", text: $newName).textInputAutocapitalization(.never)
                Button("Create") { Task { await create() } }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationCornerRadius(28)
        .task(id: path) { await load() }
    }

    private var breadcrumb: some View {
        let parts = path.split(separator: "/").map(String.init)
        return ScrollView(.horizontal) {
            HStack(spacing: 4) {
                Button("~/workspace") { path = "" }.fontWeight(parts.isEmpty ? .semibold : .regular)
                ForEach(Array(parts.enumerated()), id: \.offset) { i, p in
                    Text("/").foregroundStyle(Theme.secondary)
                    Button(p) { path = parts[0...i].joined(separator: "/") }
                        .fontWeight(i == parts.count - 1 ? .semibold : .regular)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 20)
            .frame(height: 36)
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg)
    }

    private var filtered: [FolderInfo] {
        let q = query.lowercased()
        return (listing?.folders ?? []).filter { q.isEmpty || $0.name.lowercased().contains(q) }
    }

    /// Projects that have sessions, most recent first.
    private var recents: [FolderInfo] {
        let base = store.mac?.baseFolder ?? ""
        var seen = Set<String>()
        var out: [FolderInfo] = []
        for s in store.sessions.sorted(by: { $0.lastActivityAt > $1.lastActivityAt }) where !seen.contains(s.folder) {
            seen.insert(s.folder)
            let rel = store.relFolder(s.folder)
            let count = store.sessions.filter { $0.folder == s.folder }.count
            let fromListing = listing?.folders.first { $0.path == rel }
            out.append(fromListing ?? FolderInfo(name: s.project, path: rel, isGit: false, branch: nil, language: nil,
                                                 hasChildren: false, modifiedAt: s.lastActivityAt, sessionCount: count))
            if out.count >= 4 { break }
        }
        _ = base
        return out
    }

    private func folderRow(_ f: FolderInfo) -> some View {
        HStack(spacing: 12) {
            Button {
                onPick(f.path)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: f.isGit ? "folder.fill" : "folder").foregroundStyle(Theme.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name).font(.body.weight(.medium)).foregroundStyle(Theme.text)
                        Text(f.meta).font(.footnote).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if f.hasChildren {
                Button { path = f.path; query = "" } label: {
                    Image(systemName: "chevron.right").frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .accessibilityLabel("Open \(f.name)")
            }
        }
        .frame(minHeight: 44)
    }

    private func load() async {
        guard let api = store.api else { return }
        error = nil
        do { listing = try await api.get("/folders", query: ["path": path]) }
        catch { self.error = error.localizedDescription }
    }

    private func create() async {
        guard let api = store.api, !newName.isEmpty else { return }
        struct Body: Encodable { var path: String }
        struct Resp: Decodable { var path: String }
        let rel = path.isEmpty ? newName : "\(path)/\(newName)"
        do {
            let r: Resp = try await api.send("POST", "/folders", body: Body(path: rel))
            newName = ""
            path = r.path
        } catch { self.error = error.localizedDescription }
    }
}
