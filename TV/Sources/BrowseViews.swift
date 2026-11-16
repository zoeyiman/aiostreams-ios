import SwiftUI

/// Where a tapped item leads: a title's page, a library's grid, or a person's titles.
enum Route: Hashable {
    case item(Item)
    case library(Item)
    case person(Person)
    case playlist(Item)
}

extension View {
    func routes() -> some View {
        navigationDestination(for: Route.self) { route in
            Group {
                switch route {
                case .item(let item): DetailView(item: item)
                case .library(let view): LibraryView(view: view)
                case .person(let person): PersonView(person: person)
                case .playlist(let playlist): PlaylistView(playlist: playlist)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

/// What a library holds by its type; one without a type holds both.
func libraryTypes(_ view: Item) -> String {
    switch view.collectionType {
    case "movies": return "Movie"
    case "tvshows": return "Series"
    case "boxsets": return "BoxSet"
    default: return "Movie,Series"
    }
}

/// Live TV, music and the like aren't played here.
func isBrowsable(_ view: Item) -> Bool {
    !["livetv", "music", "musicvideos", "books", "photos", "playlists"].contains(view.collectionType ?? "")
}

/// The genre a library opens with: None where offered, which a catalog that needs a genre reads
/// as all of it, else the first when it needs one (the web app's `defaultGenre`).
func openingGenre(_ client: JellyfinClient, userId: String, view: Item) async -> String? {
    guard view.aiostreams?.genreRequired == true else { return nil }
    let genres: ItemsResult? = try? await client.get("/Genres", ["userId": userId, "ParentId": view.id])
    let list = genres?.items ?? []
    return (list.first { $0.name == "None" } ?? list.first)?.id
}

/// Beside the docked rail a page starts flush against it, with 40 px on the far side.
let pageMargin = Theme.px(40)

/// Room beside the rail for a focused card's ring, drawn just outside the card.
let pageInset = Theme.px(8)

extension View {
    /// A page's edges: 8 px off the rail, which a focused card's ring needs, and 40 px on the far side.
    func pagePadding() -> some View { padding(.leading, pageInset).padding(.trailing, pageMargin) }

    /// The web app draws a TV's pages edge to edge. A scroll view otherwise insets its content
    /// by tvOS's TV-safe margins, even inside a screen that ignores them.
    func edgeToEdge() -> some View {
        scrollClipDisabled().ignoresSafeArea()
    }
}

/// A page's heading, as the web app's are.
struct PageTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.font(Theme.xl3, .bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .pagePadding()
            .padding(.top, Theme.px(40))
    }
}

// MARK: - Home

struct HomeRow: Identifiable {
    let id: String
    let title: String
    let items: [Item]
    var library: Item?
    /// Stills rather than posters: what's under way.
    var wide = false
    var collection = false
}

struct ItemRow: View {
    let row: HomeRow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(12)) {
            Group {
                if row.collection, let library = row.library {
                    NavigationLink(value: Route.library(library)) {
                        HStack(spacing: Theme.px(8)) {
                            Text(row.title).font(Theme.font(Theme.xl, .semibold))
                            Text(L("Collections")).foregroundStyle(Theme.gray400)
                            Image(systemName: "chevron.right").foregroundStyle(Theme.gray400)
                        }
                    }
                    .buttonStyle(RowStyle())
                } else {
                    Text(row.title).font(Theme.font(Theme.xl, .semibold))
                }
            }
            .pagePadding()
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Theme.px(16)) {
                    ForEach(row.items) { item in
                        // Posters in a row open into a preview; a grid's would push its columns out.
                        PosterLink(item: item, wide: row.wide, previews: !row.wide, showsTitle: row.collection)
                    }
                    // The whole library, from the end of its row.
                    if !row.collection, let library = row.library {
                        SeeAllCard(library: library, wide: row.wide)
                    }
                }
                .pagePadding()
                .padding(.vertical, Theme.px(8))
            }
            .edgeToEdge()
        }
        .focusSection()
    }
}

/// The last card in a library's row, the size of its posters, that opens the library.
struct SeeAllCard: View {
    let library: Item
    var wide = false

    private var size: CGSize {
        wide ? WideCard.size : CGSize(width: Theme.px(168), height: Theme.px(252))
    }

    var body: some View {
        NavigationLink(value: Route.library(library)) {
            SeeAllFace(name: library.name ?? L("Library"))
                .frame(width: size.width, height: size.height)
        }
        .buttonStyle(CardStyle())
    }
}

private struct SeeAllFace: View {
    @Environment(\.isFocused) private var focused
    let name: String

    var body: some View {
        VStack(spacing: Theme.px(12)) {
            ZStack {
                Circle().fill(focused ? Color.white : Color.white.opacity(0.1))
                Image(systemName: "arrow.right")
                    .font(.system(size: Theme.px(18), weight: .semibold))
                    .foregroundStyle(focused ? Color.black : Color.white)
            }
            .frame(width: Theme.px(48), height: Theme.px(48))
            VStack(spacing: Theme.px(2)) {
                Text(L("See all")).font(Theme.font(Theme.sm, .semibold))
                Text(name)
                    .font(Theme.font(Theme.xs))
                    .foregroundStyle(Theme.gray400)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.px(12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous)
                .fill(Color.white.opacity(focused ? 0.08 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: Theme.px(1))
        )
    }
}

struct TrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.px(6)) {
            configuration.title
            configuration.icon.font(.system(size: Theme.px(12), weight: .semibold))
        }
    }
}

/// A title's poster, 168 × 252, with its name and year under it, as the web app's TV rows show;
/// with `wide`, a still instead.
struct PosterLink: View {
    @Environment(\.cardFocused) private var cardFocused
    @FocusState private var focused: Bool
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    let item: Item
    var wide: Bool = false
    /// Opens into a card preview when focus rests on it (Settings > Interface > Card previews).
    var previews = false
    var showsTitle = false
    @State private var opened = false

    /// A poster's width at the web app's Poster size: small, medium or large.
    static func width(_ size: String) -> CGFloat {
        Theme.px(size == "small" ? 136 : size == "large" ? 200 : 168)
    }

    private var stillWide: Bool { wide || item.isEpisode }
    private var size: CGSize {
        let width = Self.width(prefs.posterSize)
        let base = stillWide ? WideCard.size : CGSize(width: width, height: width * 1.5)
        // Opened, the card is as tall as the poster and as wide as a 16:9 picture that tall.
        return opened ? CGSize(width: base.height * 16 / 9, height: base.height) : base
    }

    /// Movies, shows and episodes preview; a collection's card already shows all it has.
    private var previewable: Bool {
        previews && prefs.cardPreviews && (item.type == "Movie" || item.isSeries || item.isEpisode)
    }

    private var imageURL: URL? {
        guard let client = session.client else { return nil }
        if item.type == "BoxSet" {
            let height = Int(size.height * 2)
            return item.tag("Primary") != nil
                ? client.poster(item, height: height)
                : client.backdrop(item, height: height) ?? client.poster(item, height: height)
        }
        return stillWide ? client.still(item, height: Int(size.height * 2)) : client.poster(item, height: Int(size.height * 2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(8)) {
            NavigationLink(value: item.isFolder ? Route.library(item) : Route.item(item)) {
                ZStack(alignment: .topTrailing) {
                    if opened {
                        CardPreview(item: item, size: size)
                    } else {
                        RemoteImage(url: imageURL, contentMode: item.type == "BoxSet" ? .fit : .fill)
                            .frame(width: size.width, height: size.height)
                    }
                    if item.isSeries, let left = item.userData?.unplayedItemCount, left > 0, item.userData?.played != true {
                        Text(String(left))
                            .font(Theme.font(Theme.xs, .semibold))
                            .padding(.horizontal, Theme.px(8))
                            .padding(.vertical, Theme.px(2))
                            .background(Capsule().fill(Theme.brand500))
                            .padding(Theme.px(8))
                    }
                    if item.userData?.played == true {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: Theme.px(18)))
                            .foregroundStyle(.white, Theme.brand500)
                            .padding(Theme.px(8))
                    }
                }
                .overlay(alignment: .bottom) {
                    if let progress = item.userData?.playedPercentage, progress > 0, item.userData?.played != true {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.25))
                                Rectangle().fill(Theme.brand500).frame(width: geometry.size.width * progress / 100)
                            }
                        }
                        .frame(height: Theme.px(4))
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous))
            }
            .buttonStyle(CardStyle())
            .focused($focused)
            .onChange(of: focused) { _, on in
                if on { cardFocused(item) }
                if !on { withAnimation(.easeOut(duration: 0.25)) { opened = false } }
            }
            // Focus resting on it opens it out, as the web app's TV layout does.
            .task(id: focused) {
                guard focused, previewable else { return }
                try? await Task.sleep(for: CardPreviewTiming.rest)
                guard !Task.isCancelled, focused else { return }
                withAnimation(.easeOut(duration: 0.3)) { opened = true }
            }
            .itemMenu(item)
            // What the web app's Poster text asks for: the title, the year, both or neither.
            let lines = showsTitle ? ["title"] : stillWide ? ["title", "year"] : prefs.posterLines
            VStack(alignment: .leading, spacing: Theme.px(2)) {
                if lines.contains("title") {
                    Text(item.isEpisode ? (item.seriesName ?? item.displayTitle) : (item.name ?? ""))
                        .font(Theme.font(Theme.sm, .medium))
                        .lineLimit(1)
                }
                let second = item.isEpisode ? item.displayTitle : item.productionYear.map(String.init)
                if lines.contains("year"), let second {
                    Text(second)
                        .font(Theme.font(Theme.xs))
                        .foregroundStyle(Theme.gray400)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Theme.px(2))
            .frame(width: size.width, alignment: .leading)
        }
    }
}

/// An image that fills its frame, with a plain card while it loads or where there is none.
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    var body: some View {
        // Takes exactly the frame it's given and clips the picture to it; a filling image would
        // otherwise spill past its frame over whatever is around it.
        Color.clear
            .overlay {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: contentMode)
                    default:
                        Rectangle().fill(Theme.gray900)
                    }
                }
            }
            .background(Theme.gray900)
            .clipped()
    }
}

extension View {
    /// Loads again when the screen comes back, as watch state may have moved.
    func refreshOnReturn(_ action: @escaping () async -> Void) -> some View {
        modifier(RefreshOnReturn(action: action))
    }
}

private struct RefreshOnReturn: ViewModifier {
    let action: () async -> Void
    @State private var appeared = false

    func body(content: Content) -> some View {
        content.onAppear {
            if appeared { Task { await action() } }
            appeared = true
        }
    }
}

/// Posters in rows of six, which a page of items shows.
struct PosterGrid: View {
    @EnvironmentObject private var prefs: Preferences
    let items: [Item]
    var onLast: (() -> Void)? = nil
    /// As many columns as fit, rather than six, for a page that may be narrower than the screen.
    var fitting = false

    private var columns: [GridItem] {
        let size = PosterLink.width(prefs.posterSize)
        if fitting { return [GridItem(.adaptive(minimum: size, maximum: size), spacing: Theme.px(16))] }
        // Six across at the usual size; as many as the page held at it otherwise.
        let count = Int((Theme.px(168) * 6 + Theme.px(16) * 5 + Theme.px(16)) / (size + Theme.px(16)))
        return Array(repeating: GridItem(.fixed(size), spacing: Theme.px(16)), count: max(count, 1))
    }

    var body: some View {
        LazyVGrid(
            columns: columns,
            alignment: .leading,
            spacing: Theme.px(28)
        ) {
            ForEach(items) { item in
                PosterLink(item: item)
                    .onAppear { if item.id == items.last?.id { onLast?() } }
            }
        }
        .pagePadding()
        .padding(.vertical, Theme.px(16))
    }
}

// MARK: - Discover

struct DiscoverView: View {
    @EnvironmentObject private var session: Session
    @State private var movies: [Item] = []
    @State private var shows: [Item] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.px(28)) {
                HStack(alignment: .bottom) {
                    Text(L("Discover")).font(Theme.font(Theme.xl3, .bold))
                    Spacer()
                    NavigationLink {
                        LibrariesView()
                    } label: {
                        Label(L("Browse libraries"), systemImage: "rectangle.grid.2x2")
                    }
                    .buttonStyle(SoftPillStyle())
                }
                .pagePadding()
                .padding(.top, Theme.px(40))

                if !movies.isEmpty {
                    ItemRow(row: HomeRow(id: "discover.movies", title: L("Movies for you"), items: movies))
                }
                if !shows.isEmpty {
                    ItemRow(row: HomeRow(id: "discover.shows", title: L("Shows for you"), items: shows))
                }
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let message {
                    Text(message).foregroundStyle(Theme.gray400).pagePadding()
                }
            }
            .padding(.bottom, Theme.px(44))
        }
        .edgeToEdge()
        .task { await load() }
        .refreshOnReturn { await load() }
        .reloadOnWatchChange { await load() }
    }

    private func load() async {
        guard !loading, let client = session.client, let userId = session.userId else { return }
        loading = true
        defer { loading = false }

        async let favourites: ItemsResult? = try? client.get("/Items", [
            "userId": userId, "Recursive": "true", "IncludeItemTypes": "Movie,Series,Episode",
            "Filters": "IsFavorite", "Limit": "24",
        ])
        async let watched: ItemsResult? = try? client.get("/Items", [
            "userId": userId, "Recursive": "true", "IncludeItemTypes": "Movie,Series,Episode",
            "Filters": "IsPlayed", "SortBy": "DatePlayed", "SortOrder": "Descending", "Limit": "48",
        ])
        let (favouriteResult, watchedResult) = await (favourites, watched)
        guard !Task.isCancelled else { return }
        let favouriteItems = favouriteResult?.items ?? []
        let watchedItems = watchedResult?.items ?? []
        let favouriteIDs = seedIDs(favouriteItems)
        let watchedIDs = seedIDs(watchedItems)
        var seen = Set<String>()
        let seeds = zip(favouriteIDs.prefix(6), watchedIDs.prefix(6)).flatMap { [$0.0, $0.1] }
            + Array(favouriteIDs.prefix(6)) + Array(watchedIDs.prefix(6))
        let unique = seeds.filter { seen.insert($0).inserted }
        let suggestions = await withTaskGroup(of: (Int, ItemsResult?).self) { group in
            for (index, id) in unique.enumerated() {
                group.addTask {
                    let result: ItemsResult? = try? await client.get("/Items/\(id)/Similar", [
                        "userId": userId, "Limit": "16", "EnableUserData": "true",
                    ])
                    return (index, result)
                }
            }
            var ordered: [Int: [Item]] = [:]
            for await (index, result) in group {
                if let result { ordered[index] = result.items ?? [] }
            }
            return ordered.keys.sorted().compactMap { ordered[$0] }
        }
        guard !Task.isCancelled else { return }
        seen.formUnion(favouriteIDs + watchedIDs)
        var picks: [Item] = []
        // Interleave results so any one favourite or watched title doesn't dominate the rows.
        for index in 0..<(suggestions.map(\.count).max() ?? 0) {
            for list in suggestions where index < list.count {
                let item = list[index]
                guard item.type == "Movie" || item.isSeries, item.userData?.played != true,
                      item.userData?.isFavorite != true, item.resumeMs == nil, seen.insert(item.id).inserted else { continue }
                picks.append(item)
            }
        }
        movies = Array(picks.filter { $0.type == "Movie" }.prefix(24))
        shows = Array(picks.filter(\.isSeries).prefix(24))
        loaded = true
        if movies.isEmpty && shows.isEmpty {
            if (favouriteResult == nil && watchedResult == nil) || (!unique.isEmpty && suggestions.isEmpty) {
                message = L("Recommendations could not be loaded from this server.")
            } else if unique.isEmpty {
                message = L("Favourite or watch a movie or show to get recommendations here.")
            } else {
                message = L("No new recommendations yet.")
            }
        } else {
            message = nil
        }
    }

    private func seedIDs(_ items: [Item]) -> [String] {
        var seen = Set<String>()
        return items.compactMap { $0.isEpisode ? $0.seriesId : $0.id }.filter { seen.insert($0).inserted }
    }
}

struct LibrariesView: View {
    @EnvironmentObject private var session: Session
    @State private var views: [Item] = []

    var body: some View {
        ScrollView {
            PageTitle(text: L("Libraries"))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.px(16)), count: 4), spacing: Theme.px(16)) {
                ForEach(views) { view in
                    NavigationLink(value: Route.library(view)) {
                        Text(view.name ?? L("Library"))
                            .font(Theme.font(Theme.lg, .semibold))
                            .multilineTextAlignment(.center)
                            .padding(Theme.px(16))
                            .frame(maxWidth: .infinity, minHeight: Theme.px(96))
                    }
                    .buttonStyle(RowStyle())
                }
            }
            .pagePadding()
            .padding(.vertical, pageMargin)
        }
        .edgeToEdge()
        .task {
            guard let client = session.client, let userId = session.userId, views.isEmpty else { return }
            let result: ItemsResult? = try? await client.get("/UserViews", ["userId": userId])
            views = (result?.items ?? []).filter(isBrowsable)
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var session: Session
    let view: Item

    private enum CollectionFilter: CaseIterable, Hashable {
        case all, movies, shows

        var label: String {
            switch self {
            case .all: return L("All")
            case .movies: return L("Movies")
            case .shows: return L("Shows")
            }
        }

        var itemTypes: String? {
            switch self {
            case .all: return nil
            case .movies: return "Movie"
            case .shows: return "Series"
            }
        }
    }

    @State private var collectionFilter = CollectionFilter.all
    @State private var filter: ItemFilter?
    @State private var sort: SortKey = .name
    @State private var descending = false
    @State private var items: [Item] = []
    @State private var offset = 0
    @State private var total = Int.max
    @State private var genre: String?
    @State private var loading = true
    @State private var activeQuery: Query?
    @State private var loadID = UUID()
    @State private var failure: String?

    private struct Query: Equatable {
        let collection: CollectionFilter
        let filter: ItemFilter?
        let sort: SortKey
        let descending: Bool
    }

    private static let page = 60
    private var isBoxSet: Bool { view.type == "BoxSet" }
    private var query: Query { Query(collection: collectionFilter, filter: filter, sort: sort, descending: descending) }

    var body: some View {
        ScrollView {
            if isBoxSet {
                collectionHeader
            } else {
                PageTitle(text: view.name ?? L("Library"))
                SortFilterBar(filters: session.isStock ? ItemFilter.allCases : [.unplayed], filter: $filter,
                              sorts: session.isStock ? SortKey.allCases : [], sort: $sort, descending: $descending)
            }
            PosterGrid(items: items) { Task { await more() } }
            if loading { ProgressView().padding() }
            if let failure {
                VStack(spacing: Theme.px(12)) {
                    Text(failure).foregroundStyle(Theme.gray400)
                    Button(L("Try again")) { Task { await more() } }.buttonStyle(SoftPillStyle())
                }
                .padding()
            } else if !loading && items.isEmpty {
                Text(L("Nothing here.")).foregroundStyle(Theme.gray400)
            }
        }
        .edgeToEdge()
        .washed(by: view)
        .task(id: query) { await reload() }
    }

    private var collectionHeader: some View {
        VStack(alignment: .leading, spacing: Theme.px(30)) {
            HStack(alignment: .bottom, spacing: Theme.px(24)) {
                RemoteImage(url: session.client?.poster(view, height: 540), contentMode: .fit)
                    .frame(width: Theme.px(284), height: Theme.px(160))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.px(12)))
                Text(view.name ?? L("Collection"))
                    .font(Theme.font(Theme.xl3, .bold))
                    .padding(.bottom, Theme.px(12))
            }
            HStack {
                Text(L("In this collection")).font(Theme.font(Theme.xl, .semibold))
                Spacer()
                ForEach(CollectionFilter.allCases, id: \.self) { option in
                    Button(option.label) { collectionFilter = option }
                        .buttonStyle(SoftPillStyle(selected: collectionFilter == option))
                }
            }
            .focusSection()
        }
        .pagePadding()
        .padding(.top, Theme.px(40))
    }

    private func reload() async {
        let asked = query
        guard activeQuery != asked else { return }
        let id = UUID()
        loadID = id
        activeQuery = nil
        items = []
        offset = 0
        total = Int.max
        loading = true
        failure = nil
        guard let client = session.client, let userId = session.userId else { loading = false; return }
        let opening = await openingGenre(client, userId: userId, view: view)
        guard !Task.isCancelled, id == loadID, asked == query else { return }
        genre = opening
        activeQuery = asked
        loading = false
        await more()
    }

    private func more() async {
        guard !loading, offset < total, let asked = activeQuery, asked == query,
              let client = session.client, let userId = session.userId else { return }
        let id = loadID
        loading = true
        failure = nil
        defer { if id == loadID { loading = false } }

        do {
            let result: ItemsResult = try await client.get("/Items", [
                "userId": userId,
                "ParentId": view.id,
                "StartIndex": String(offset),
                "Limit": String(Self.page),
                "IncludeItemTypes": isBoxSet ? asked.collection.itemTypes : libraryTypes(view),
                "GenreIds": genre,
                "Recursive": "true",
                "EnableTotalRecordCount": "true",
                "Filters": asked.filter?.jellyfin,
                "SortBy": session.isStock && !isBoxSet ? asked.sort.fields : nil,
                "SortOrder": session.isStock && !isBoxSet ? (asked.descending ? "Descending" : "Ascending") : nil,
            ])
            guard !Task.isCancelled, id == loadID, asked == query else { return }
            let page = result.items ?? []
            var seen = Set(items.map(\.id))
            offset += page.count
            items.append(contentsOf: page.filter { seen.insert($0.id).inserted })
            total = page.isEmpty ? offset : (result.totalRecordCount ?? Int.max)
        } catch {
            if !Task.isCancelled, id == loadID, asked == query { failure = error.localizedDescription }
        }
    }
}

// MARK: - Favourites

struct FavouritesView: View {
    @EnvironmentObject private var session: Session
    /// The web app's favourites sorts, newest added first.
    @State private var sort: SortKey = .added
    @State private var descending = true
    @State private var items: [Item] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            PageTitle(text: L("Favourites"))
            SortFilterBar(filter: .constant(nil), sorts: [.added, .name, .released, .rating], sort: $sort, descending: $descending)
            if loaded && items.isEmpty {
                Text(L("Titles you favourite show here."))
                    .font(Theme.font(Theme.base))
                    .foregroundStyle(Theme.gray400)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pagePadding()
                    .padding(.vertical, pageMargin)
                    .focusable()
            }
            PosterGrid(items: items)
        }
        .edgeToEdge()
        .task { await load() }
        .refreshOnReturn { await load() }
        .reloadOnWatchChange { await load() }
        .onChange(of: "\(sort.rawValue)|\(descending)") { _, _ in Task { await load() } }
    }

    private func load() async {
        guard let client = session.client, let userId = session.userId else { return }
        let result: ItemsResult? = try? await client.get("/Items", [
            "userId": userId,
            "Filters": "IsFavorite",
            "Recursive": "true",
            "IncludeItemTypes": "Movie,Series,Episode",
            "SortBy": sort.fields,
            "SortOrder": descending ? "Descending" : "Ascending",
        ])
        items = result?.items ?? []
        loaded = true
    }
}

// MARK: - Search

struct SearchView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    /// A channel picked from the results, which plays live.
    @State private var choice: VersionChoice?
    @State private var term = ""
    @State private var results: [Item] = []
    @State private var searching = false
    /// How far in from the left the search keeps its content, which the grid keyboard makes wide.
    @State private var leadingInset: CGFloat = 0

    /// The grid keyboard, down the left side, rather than the full one across the top.
    private var sideKeyboard: Bool { leadingInset > Theme.px(200) }

    var body: some View {
        ZStack {
            // Measures the room the keyboard leaves, from a view that keeps to it.
            Color.clear
                .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.leading } action: { leadingInset = $0 }
            grid(in: sideKeyboard ? .trailing : .horizontal)
        }
        .searchable(text: $term, prompt: L("Movies, shows and channels"))
        .playFlow($choice)
        .task(id: term) { await search() }
    }

    private func grid(in edges: Edge.Set) -> some View {
        ScrollView {
            // Live TV channels the search finds (server v2.38), which play rather than open a page.
            let channels = results.filter(\.isChannel)
            if !channels.isEmpty {
                VStack(alignment: .leading, spacing: Theme.px(8)) {
                    Text(L("Channels")).font(Theme.font(Theme.xl, .semibold)).pagePadding()
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: Theme.px(16)) {
                            ForEach(channels) { channel in
                                ChannelCard(channel: channel, airing: nil) {
                                    choice = VersionChoice(item: channel, startMs: nil, mode: .straight)
                                }
                            }
                        }
                        .pagePadding()
                        .padding(.vertical, Theme.px(8))
                    }
                    .scrollClipDisabled()
                }
                .focusSection()
            }
            if prefs.combineSearch {
                PosterGrid(items: results.filter { !$0.isChannel }, fitting: true)
            } else {
                // A section each, as the web app's search shows them unless they're combined.
                let movies = results.filter { $0.type == "Movie" }
                let shows = results.filter(\.isSeries)
                VStack(alignment: .leading, spacing: Theme.px(8)) {
                    if !movies.isEmpty {
                        Text(L("Movies")).font(Theme.font(Theme.xl, .semibold)).pagePadding()
                        PosterGrid(items: movies, fitting: true)
                    }
                    if !shows.isEmpty {
                        Text(L("Shows")).font(Theme.font(Theme.xl, .semibold)).pagePadding()
                        PosterGrid(items: shows, fitting: true)
                    }
                }
            }
            if searching { ProgressView() }
            if !searching && term.count >= 2 && results.isEmpty {
                Text(L("No results for “%@”.", "\(term)")).font(Theme.font(Theme.base)).foregroundStyle(Theme.gray400)
            }
        }
        // Edge to edge across, but under the full keyboard, which takes the top of the screen:
        // ignoring that inset or drawing past the scroll view put results behind it. The grid
        // keyboard takes the left instead, so then only the right is ignored.
        .ignoresSafeArea(edges: edges)
    }

    private func search() async {
        guard term.count >= 2 else {
            results = []
            return
        }
        // Waits for typing to pause.
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled, let client = session.client, let userId = session.userId else { return }
        searching = true
        defer { searching = false }
        let result: ItemsResult? = try? await client.get("/Items", [
            "userId": userId,
            "SearchTerm": term,
            "Recursive": "true",
            "IncludeItemTypes": "Movie,Series,TvChannel",
            "Limit": "48",
        ])
        if !Task.isCancelled { results = result?.items ?? [] }
    }
}

// MARK: - Sorts and filters

/// The web app's sorts (components/media/sort-picker.tsx), by Jellyfin's sort fields.
enum SortKey: String, CaseIterable {
    case name, added, released, rating, runtime

    var title: String {
        switch self {
        case .name: return L("Name")
        case .added: return L("Date added")
        case .released: return L("Release date")
        case .rating: return L("Rating")
        case .runtime: return L("Runtime")
        }
    }

    var fields: String {
        switch self {
        case .name: return "SortName"
        case .added: return "DateCreated,SortName"
        case .released: return "PremiereDate,ProductionYear,SortName"
        case .rating: return "CommunityRating,SortName"
        case .runtime: return "Runtime,SortName"
        }
    }

    /// Names read A to Z first; the rest newest, highest or longest first.
    var startsDescending: Bool { self != .name }
}

/// The web app's library filters, by Jellyfin's filter names.
enum ItemFilter: String, CaseIterable {
    case unplayed, resumable, played, favorite

    var title: String {
        switch self {
        case .unplayed: return L("Unwatched")
        case .resumable: return L("In progress")
        case .played: return L("Watched")
        case .favorite: return L("Favourites")
        }
    }

    var jellyfin: String {
        switch self {
        case .unplayed: return "IsUnplayed"
        case .resumable: return "IsResumable"
        case .played: return "IsPlayed"
        case .favorite: return "IsFavorite"
        }
    }
}

/// Pills for a page's filters and sorts: choosing the sort it's on turns its direction round.
struct SortFilterBar: View {
    var filters: [ItemFilter] = []
    @Binding var filter: ItemFilter?
    var sorts: [SortKey] = []
    @Binding var sort: SortKey
    @Binding var descending: Bool

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.px(8)) {
                if !filters.isEmpty {
                    Button(L("All")) { filter = nil }
                        .buttonStyle(SoftPillStyle(selected: filter == nil))
                    ForEach(filters, id: \.self) { option in
                        Button(option.title) { filter = option }
                            .buttonStyle(SoftPillStyle(selected: filter == option))
                    }
                }
                if !filters.isEmpty && !sorts.isEmpty {
                    Rectangle().fill(.white.opacity(0.15)).frame(width: Theme.px(1), height: Theme.px(24))
                        .padding(.horizontal, Theme.px(8))
                }
                ForEach(sorts, id: \.self) { option in
                    Button {
                        if sort == option { descending.toggle() } else {
                            sort = option
                            descending = option.startsDescending
                        }
                    } label: {
                        HStack(spacing: Theme.px(4)) {
                            Text(option.title)
                            if sort == option {
                                Image(systemName: descending ? "arrow.down" : "arrow.up")
                                    .font(.system(size: Theme.px(11), weight: .semibold))
                            }
                        }
                    }
                    .buttonStyle(SoftPillStyle(selected: sort == option))
                }
            }
            .pagePadding()
            .padding(.vertical, Theme.px(8))
        }
        .scrollClipDisabled()
        .focusSection()
    }
}
