import SwiftUI

struct PlaylistsView: View {
    var body: some View { PlaylistPage(playlist: nil) }
}

struct PlaylistItemsView: View {
    let playlist: Item
    var body: some View { PlaylistPage(playlist: playlist) }
}

/// Browses server playlists and their on-demand video titles in the server's order.
private struct PlaylistPage: View {
    @EnvironmentObject private var session: Session
    let playlist: Item?
    @State private var items: [Item] = []
    @State private var offset = 0
    @State private var complete = false
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.px(24)) {
                PageTitle(text: playlist?.name ?? "Playlists")
                if playlist == nil {
                    ForEach(items) { item in
                        NavigationLink(value: Route.playlist(item)) {
                            Label(item.name ?? "Playlist", systemImage: "list.bullet.rectangle")
                                .font(Theme.font(Theme.lg, .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Theme.px(20))
                        }
                        .buttonStyle(RowStyle())
                        .pagePadding()
                    }
                } else {
                    PosterGrid(items: items)
                }
                if loading { ProgressView().pagePadding() }
                if let error {
                    Text(error).foregroundStyle(Theme.gray400).pagePadding()
                    Button("Try again") { Task { await more() } }
                        .buttonStyle(SecondaryPillStyle()).pagePadding()
                } else if !loading && complete && items.isEmpty {
                    Text(playlist == nil ? "No playlists on this server." : "No on-demand video titles in this playlist.")
                        .foregroundStyle(Theme.gray400).pagePadding().focusable()
                } else if !loading && !complete {
                    Button("Load more") { Task { await more() } }
                        .buttonStyle(SecondaryPillStyle()).pagePadding()
                }
            }
            .padding(.bottom, Theme.px(64))
        }
        .edgeToEdge()
        .task { if offset == 0 { await more() } }
    }

    @MainActor private func more() async {
        guard !loading, !complete, let client = session.client, let userId = session.userId else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let result: ItemsResult = try await client.get(
                playlist.map { "/Playlists/\($0.id)/Items" } ?? "/Items", [
                    "userId": userId, "StartIndex": String(offset), "Limit": "60",
                    "EnableTotalRecordCount": "true",
                    "Recursive": playlist == nil ? "true" : nil,
                    "IncludeItemTypes": playlist == nil ? "Playlist" : nil,
                ])
            try Task.checkCancellation()
            let batch = result.items ?? []
            let known = Set(items.map(\.id))
            items += batch.filter { !known.contains($0.id) && (playlist == nil ? $0.type == "Playlist" : $0.isOnDemand) }
            offset += batch.count
            complete = batch.isEmpty || offset >= (result.totalRecordCount ?? (batch.count < 60 ? offset : Int.max))
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
