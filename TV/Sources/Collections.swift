import Foundation

/// A single server-backed saved-title collection; no parallel watchlist flags to drift apart.
enum TitleCollection {
    static func saved(client: JellyfinClient, userId: String) async throws -> [Item] {
        var items: [Item] = []
        var offset = 0
        while true {
            let page: ItemsResult = try await client.get("/Items", [
                "userId": userId, "Filters": "IsFavorite", "Recursive": "true",
                "IncludeItemTypes": "Movie,Series,Episode", "Fields": "Genres,Overview",
                "SortBy": "DateCreated,SortName", "SortOrder": "Descending",
                "StartIndex": String(offset), "Limit": "100", "EnableTotalRecordCount": "true",
            ])
            let batch = page.items ?? []
            let known = Set(items.map(\.id))
            items += batch.filter { $0.isOnDemand && !known.contains($0.id) }
            offset += batch.count
            if batch.isEmpty { break }
            if let total = page.totalRecordCount, offset >= total { break }
            if page.totalRecordCount == nil && batch.count < 100 { break }
        }
        return items
    }

    /// Recent on-demand history and saved titles supply seeds. Similar-title results vote for
    /// candidates, so overlap between several interests ranks above a single seed's match.
    static func recommendations(saved: [Item], client: JellyfinClient, userId: String) async throws -> [Item] {
        async let history: ItemsResult = client.get("/Items", [
            "userId": userId, "Filters": "IsPlayed", "Recursive": "true",
            "IncludeItemTypes": "Movie,Episode", "SortBy": "DatePlayed", "SortOrder": "Descending",
            "Limit": "30", "Fields": "Genres,Overview",
        ])
        async let resume: ItemsResult = client.get("/UserItems/Resume", [
            "userId": userId, "Limit": "30", "MediaTypes": "Video",
        ])
        let (played, inProgress) = try await (history, resume)
        let watched = ((played.items ?? []) + (inProgress.items ?? []))
            .filter(\.isOnDemand)
            .sorted { (parseDate($0.userData?.lastPlayedDate) ?? .distantPast) > (parseDate($1.userData?.lastPlayedDate) ?? .distantPast) }
        let seeds = recommendationSeeds(saved: saved, watched: watched)
        guard !seeds.isEmpty else { return [] }
        var candidates: [Item] = []
        // Bounded requests keep this inexpensive on a TV and on small self-hosted servers.
        for seed in seeds {
            try Task.checkCancellation()
            let result: ItemsResult = try await client.get("/Items/\(seed)/Similar", [
                "userId": userId, "Limit": "16", "Fields": "Genres,Overview",
            ])
            candidates += result.items ?? []
        }
        return rankRecommendations(candidates, excluding: saved + watched)
    }

    static func recommendationSeeds(saved: [Item], watched: [Item]) -> [String] {
        var seen = Set<String>()
        // Interleave both signals so a large saved collection cannot crowd out viewing history.
        let a = saved.filter(\.isOnDemand)
        let b = watched.filter(\.isOnDemand)
        var result: [String] = []
        for index in 0..<max(a.count, b.count) {
            for list in [a, b] where index < list.count {
                let item = list[index]
                let id = item.isEpisode ? (item.seriesId ?? item.id) : item.id
                if seen.insert(id).inserted { result.append(id) }
            }
            if result.count >= 8 { break }
        }
        return Array(result.prefix(8))
    }

    static func rankRecommendations(_ candidates: [Item], excluding items: [Item]) -> [Item] {
        let excluded = Set(items.flatMap { [$0.id, $0.seriesId].compactMap { $0 } })
        var scores: [String: Int] = [:]
        var titles: [String: Item] = [:]
        for item in candidates where (item.type == "Movie" || item.isSeries) && !excluded.contains(item.id) && item.userData?.played != true {
            scores[item.id, default: 0] += 1
            titles[item.id] = item
        }
        return Array(titles.values.sorted {
            let a = scores[$0.id, default: 0], b = scores[$1.id, default: 0]
            return a != b ? a > b : $0.id < $1.id
        }.prefix(30))
    }
}
