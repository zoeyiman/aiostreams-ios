import SwiftUI

/// Preserve server collection containers: a BoxSet is a browse destination, not a playable title.
enum CatalogueCollections {
    static func load(client: JellyfinClient, userId: String) async throws -> [Item] {
        let views: ItemsResult = try await client.get("/UserViews", ["userId": userId])
        var result = (views.items ?? []).filter(isBrowsable)
        var seen = Set(result.map(\.id))
        var offset = 0
        while true {
            let page: ItemsResult = try await client.get("/Items", [
                "userId": userId, "Recursive": "true", "IncludeItemTypes": "BoxSet",
                "StartIndex": String(offset), "Limit": "100", "SortBy": "SortName",
                "EnableTotalRecordCount": "true", "Fields": "Overview",
            ])
            let items = page.items ?? []
            var added = 0
            for item in items where item.isFolder && seen.insert(item.id).inserted {
                result.append(item)
                added += 1
            }
            offset += items.count
            if items.isEmpty || added == 0 { break }
            if let total = page.totalRecordCount, offset >= total { break }
            if page.totalRecordCount == nil && items.count < 100 { break }
        }
        return result
    }
}

struct CollectionShelf: View {
    var grid = false
    @EnvironmentObject private var session: Session
    @State private var collections: [Item] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(16)) {
            if !collections.isEmpty {
                Text("Your collections").font(Theme.font(Theme.xl, .semibold)).pagePadding()
                if grid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.px(250)), spacing: Theme.carouselGap)], spacing: Theme.carouselGap) {
                        ForEach(collections) { collection in collectionLink(collection) }
                    }
                    .pagePadding().padding(.vertical, Theme.px(16))
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: Theme.carouselGap) {
                            ForEach(collections) { collection in
                                collectionLink(collection).frame(width: Theme.px(280))
                            }
                        }
                        .pagePadding().padding(.vertical, Theme.px(16))
                    }
                    .edgeToEdge()
                }
            }
            if let error {
                Text("Collections: \(error)").foregroundStyle(Theme.gray400).pagePadding()
                Button("Retry collections") { Task { await load() } }
                    .buttonStyle(SecondaryPillStyle()).pagePadding()
            }
        }
        .focusSection()
        .task { await load() }
        .refreshOnReturn { await load() }
    }

    private func collectionLink(_ collection: Item) -> some View {
        NavigationLink(value: Route.library(collection)) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: session.client?.backdrop(collection, height: 480)
                            ?? session.client?.poster(collection, height: 480))
                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                Text(collection.name ?? "Collection")
                    .font(Theme.font(Theme.lg, .semibold)).lineLimit(2)
                    .padding(Theme.px(20))
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        }
        .buttonStyle(CardStyle())
    }

    @MainActor private func load() async {
        guard let client = session.client, let userId = session.userId else { return }
        error = nil
        do {
            let found = try await CatalogueCollections.load(client: client, userId: userId)
            try Task.checkCancellation()
            collections = found
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }
}
