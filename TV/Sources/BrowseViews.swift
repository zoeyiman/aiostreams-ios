import SwiftUI

/// Where a tapped item leads: a title's page, a library's grid, or a person's titles.
enum Route: Hashable {
    case item(Item)
    case library(Item)
    case collectionCovers(Item)
    case latest(String)
    case rowResults(title: String, items: [Item], wide: Bool = false)
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
                case .collectionCovers(let view): LibraryView(view: view, collectionCovers: true)
                case .latest(let type):
                    LibraryView(view: Item(id: "", name: type == "Movie" ? L("Latest movies") : L("Latest shows"),
                                           collectionType: type == "Movie" ? "movies" : "tvshows"), latest: true)
                case .rowResults(let title, let items, let wide):
                    RowResultsView(title: title, items: items, wide: wide)
                case .person(let person): PersonView(person: person)
                case .playlist(let playlist): PlaylistView(playlist: playlist)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct RowResultsView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let items: [Item]
    let wide: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(10)) {
            HStack(spacing: Theme.px(14)) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(Theme.font(Theme.base, .semibold))
                        .frame(width: Theme.px(28), height: Theme.px(28))
                }
                .buttonStyle(SoftPillStyle())
                .accessibilityLabel(L("Back"))
                Text(title).font(Theme.font(Theme.xl3, .bold))
            }
            .pagePadding()
            .padding(.top, pageTop)
            .focusSection()
            ScrollView {
                PosterGrid(items: items, wide: wide)
                    .padding(.bottom, pageMargin)
            }
            .edgeToEdge()
        }
        .onExitCommand { dismiss() }
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

let pageInset = Theme.px(24)
let pageMargin = pageInset
let pageTop = Theme.px(24)

extension View {
    /// Keep titles, controls and content on the same horizontal guides.
    func pagePadding() -> some View { padding(.leading, pageInset).padding(.trailing, pageMargin) }

    /// The web app draws a TV's pages edge to edge. A scroll view otherwise insets its content
    /// by tvOS's TV-safe margins, even inside a screen that ignores them.
    func edgeToEdge() -> some View {
        ignoresSafeArea()
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
            .padding(.top, pageTop)
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
    var browseRoute: Route?
}

enum MediaRowTarget: Hashable {
    case item(String)
    case more
}

private struct MediaRowFocusKey: EnvironmentKey {
    static let defaultValue: FocusState<MediaRowTarget?>.Binding? = nil
}

extension EnvironmentValues {
    var mediaRowFocus: FocusState<MediaRowTarget?>.Binding? {
        get { self[MediaRowFocusKey.self] }
        set { self[MediaRowFocusKey.self] = newValue }
    }
}

/// The native equivalent of AIOStreams' data-nav-resume row entry.
struct MediaRowFocus: ViewModifier {
    let targets: [MediaRowTarget]
    let reveal: (MediaRowTarget) -> Void
    @FocusState private var focused: MediaRowTarget?
    @State private var remembered: MediaRowTarget?

    func body(content: Content) -> some View {
        content
            .environment(\.mediaRowFocus, $focused)
            .onChange(of: focused) { previous, current in
                guard let current else { return }
                // Moving within the row stays under the system's directional focus engine.
                guard previous == nil else {
                    remembered = current
                    return
                }
                let entry = remembered.flatMap { targets.contains($0) ? $0 : nil } ?? targets.first
                if let entry, entry != current {
                    reveal(entry)
                    focused = entry
                } else {
                    remembered = current
                }
            }
    }
}

struct MediaRowCardFocus: ViewModifier {
    @Environment(\.mediaRowFocus) private var rowFocus
    let target: MediaRowTarget
    var local: FocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if let rowFocus {
            content.focused(rowFocus, equals: target)
        } else if let local {
            content.focused(local)
        } else {
            content
        }
    }
}

struct ItemRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Namespace private var previewViewport
    @State private var viewportWidth: CGFloat = 0
    let row: HomeRow

    private var cards: [Item] { Array(row.items.prefix(24)) }
    private var browseRoute: Route {
        if let library = row.library { return row.collection ? .collectionCovers(library) : .library(library) }
        return row.browseRoute ?? .rowResults(title: row.title, items: row.items)
    }

    private var targets: [MediaRowTarget] { cards.map { .item($0.id) } + [.more] }

    var body: some View {
        ScrollViewReader { scroller in
            VStack(alignment: .leading, spacing: Theme.px(12)) {
                HStack(spacing: Theme.px(8)) {
                    Text(row.title).font(Theme.font(Theme.xl, .semibold))
                    if row.collection, row.library != nil {
                        Text(L("Collections")).foregroundStyle(Theme.gray400)
                    }
                }
                .pagePadding()
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Theme.px(16)) {
                        ForEach(cards) { item in
                            // A grid keeps its columns fixed. Row cards can widen and reveal themselves.
                            PosterLink(item: item, wide: row.wide, previews: !row.wide, showsTitle: row.collection,
                                       previewViewport: previewViewport) { frame in
                                reveal(item.id, frame: frame, in: scroller)
                            }
                            .id(MediaRowTarget.item(item.id))
                        }
                        SeeAllCard(title: row.title, route: browseRoute, wide: row.wide)
                            .id(MediaRowTarget.more)
                    }
                    .pagePadding()
                    .padding(.vertical, Theme.px(8))
                }
                .coordinateSpace(name: previewViewport)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
                .edgeToEdge()
                .modifier(MediaRowFocus(targets: targets) { scroller.scrollTo($0) })
            }
        }
        .focusSection()
    }

    private func reveal(_ id: String, frame: CGRect, in scroller: ScrollViewProxy) -> Bool {
        let rtl = layoutDirection == .rightToLeft
        let trailingEdge = rtl ? viewportWidth - frame.minX : frame.maxX
        let leadingEdge = rtl ? viewportWidth - frame.maxX : frame.minX
        let revealTrailing = trailingEdge > viewportWidth - pageMargin
        guard revealTrailing || leadingEdge < pageInset,
              let trailingAnchor = CardPreviewLayout.revealAnchor(cardWidth: frame.width, viewportWidth: viewportWidth,
                                                     margin: pageMargin) else { return false }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
            scroller.scrollTo(MediaRowTarget.item(id), anchor: UnitPoint(x: revealTrailing ? trailingAnchor : 1 - trailingAnchor, y: 0.5))
        }
        return true
    }
}

struct SeeAllCard: View {
    let title: String
    let route: Route
    var wide = false

    private var size: CGSize {
        wide ? WideCard.size : CGSize(width: Theme.px(168), height: Theme.px(252))
    }

    var body: some View {
        NavigationLink(value: route) {
            SeeAllFace(name: title)
                .frame(width: size.width, height: size.height)
        }
        .buttonStyle(CardStyle())
        .modifier(MediaRowCardFocus(target: .more))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cardFocused) private var cardFocused
    @Environment(\.mediaRowFocus) private var rowFocus
    @FocusState private var focused: Bool
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    let item: Item
    var wide: Bool = false
    /// Opens into a card preview when focus rests on it (Settings > Interface > Card previews).
    var previews = false
    var showsTitle = false
    var portrait = false
    var gridWidth: CGFloat?
    var previewViewport: Namespace.ID?
    var revealPreview: ((CGRect) -> Bool)?
    @State private var opened = false
    @State private var revealed = false

    /// A poster's width at the web app's Poster size: small, medium or large.
    static func width(_ size: String) -> CGFloat {
        Theme.px(size == "small" ? 136 : size == "large" ? 200 : 168)
    }

    private var hasCardFocus: Bool {
        if let rowFocus { return rowFocus.wrappedValue == .item(item.id) }
        return focused
    }

    private var stillWide: Bool { wide || (item.isEpisode && !portrait) }
    private var size: CGSize {
        let width = gridWidth ?? (stillWide ? WideCard.size.width : Self.width(prefs.posterSize))
        let base = CGSize(width: width, height: width * (stillWide ? 9.0 / 16.0 : 1.5))
        // Opened, the card is as tall as the poster and as wide as a 16:9 picture that tall.
        return opened ? CGSize(width: base.height * 16 / 9, height: base.height) : base
    }

    /// Movies, shows and episodes preview; a collection's card already shows all it has.
    private var previewable: Bool {
        previews && prefs.cardPreviews && (item.type == "Movie" || item.isSeries || item.isEpisode)
    }

    private var imageURL: URL? {
        guard let client = session.client else { return nil }
        if portrait && item.isEpisode, let series = item.seriesId {
            return client.image(series, .primary, tag: item.seriesPrimaryImageTag, height: Int(size.height * 2))
        }
        return stillWide ? client.still(item, height: Int(size.height * 2)) : client.poster(item, height: Int(size.height * 2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(8)) {
            NavigationLink(value: item.isFolder ? Route.library(item) : Route.item(item)) {
                ZStack(alignment: .topTrailing) {
                    if opened {
                        CardPreview(item: item, size: size)
                    } else if item.type == "BoxSet" {
                        let urls = session.client?.collectionArtwork(item, width: Int(size.width * 2), wide: stillWide) ?? []
                        CollectionArtwork(urls: urls)
                            .id(urls)
                            .frame(width: size.width, height: size.height)
                    } else {
                        RemoteImage(url: imageURL)
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
            .modifier(MediaRowCardFocus(target: .item(item.id), local: $focused))
            .onChange(of: hasCardFocus) { _, on in
                if on { cardFocused(item) }
                if !on {
                    revealed = false
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { opened = false }
                }
            }
            // Focus resting on it opens it out, as the web app's TV layout does.
            .task(id: hasCardFocus) {
                guard hasCardFocus, previewable else { return }
                try? await Task.sleep(for: CardPreviewTiming.rest)
                guard !Task.isCancelled, hasCardFocus else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { opened = true }
            }
            .onGeometryChange(for: CGRect?.self) { geometry in
                guard opened, let previewViewport else { return nil }
                return geometry.frame(in: .named(previewViewport))
            } action: { frame in
                guard hasCardFocus, opened, !revealed, let frame, frame.width >= size.width - 1 else { return }
                revealed = revealPreview?(frame) ?? false
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

/// Keep logos and lettering inside the card even when the server supplies art of a different shape.
private struct CollectionArtwork: View {
    let urls: [URL]
    @State private var index = 0

    var body: some View {
        Color.black.overlay {
            if urls.indices.contains(index) {
                let url = urls[index]
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure:
                        Color.clear.task(id: url) {
                            guard urls.indices.contains(index), urls[index] == url else { return }
                            index += 1
                        }
                    default:
                        Color.clear
                    }
                }
                .id(url)
            }
        }
        .clipped()
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

/// Fit a whole number of cards and divide the usable width evenly between them.
struct PosterGrid: View {
    @EnvironmentObject private var prefs: Preferences
    @State private var availableWidth: CGFloat = 0
    let items: [Item]
    var onLast: (() -> Void)? = nil
    var wide = false

    private let gap = Theme.px(16)
    private var preferredWidth: CGFloat { wide ? WideCard.size.width : PosterLink.width(prefs.posterSize) }
    private var count: Int { max(1, Int((availableWidth + gap) / (preferredWidth + gap))) }
    private var cardWidth: CGFloat {
        guard availableWidth > 0 else { return preferredWidth }
        return (availableWidth - CGFloat(count - 1) * gap) / CGFloat(count)
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: gap, alignment: .topLeading), count: count),
            alignment: .leading,
            spacing: Theme.px(28)
        ) {
            ForEach(items) { item in
                PosterLink(item: item, wide: wide, showsTitle: wide, portrait: !wide, gridWidth: cardWidth)
                    .onAppear { if item.id == items.last?.id { onLast?() } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
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
                .padding(.top, pageTop)

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
        movies = picks.filter { $0.type == "Movie" }
        shows = picks.filter(\.isSeries)
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
    var collectionCovers = false
    var latest = false

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
    @State private var folders: [CollectionPage] = []
    @State private var visitedFolders: Set<String> = []

    private struct CollectionPage {
        let parent: String
        var offset = 0
    }

    private struct Query: Equatable {
        let collection: CollectionFilter
        let filter: ItemFilter?
        let sort: SortKey
        let descending: Bool
    }

    private static let page = 60
    private var isBoxSet: Bool { view.type == "BoxSet" && !collectionCovers }
    private var query: Query { Query(collection: collectionFilter, filter: filter, sort: sort, descending: descending) }

    var body: some View {
        ScrollView {
            if isBoxSet {
                collectionHeader
            } else {
                PageTitle(text: view.name ?? L("Library"))
                if !collectionCovers && !latest {
                    SortFilterBar(filters: session.isStock ? ItemFilter.allCases : [.unplayed], filter: $filter,
                                  sorts: session.isStock ? SortKey.allCases : [], sort: $sort, descending: $descending)
                }
            }
            PosterGrid(items: items, onLast: { Task { await more() } }, wide: collectionCovers)
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
                let urls = session.client?.collectionArtwork(view, width: Int(Theme.px(568))) ?? []
                CollectionArtwork(urls: urls)
                    .id(urls)
                    .frame(width: Theme.px(284), height: Theme.px(160))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.px(12)))
                Text(view.name ?? L("Collection"))
                    .font(Theme.font(Theme.xl3, .bold))
                    .padding(.bottom, Theme.px(12))
            }
            HStack {
                Text(L("In this collection")).font(Theme.font(Theme.xl, .semibold))
                Spacer()
                HStack(spacing: Theme.px(3)) {
                    ForEach(CollectionFilter.allCases, id: \.self) { option in
                        Button {
                            collectionFilter = option
                        } label: {
                            Text(option.label)
                                .font(Theme.font(Theme.sm, .semibold))
                                .padding(.horizontal, Theme.px(12))
                                .padding(.vertical, Theme.px(6))
                        }
                        .buttonStyle(CollectionSegmentStyle(selected: collectionFilter == option))
                        .accessibilityAddTraits(collectionFilter == option ? .isSelected : [])
                    }
                }
                .padding(Theme.px(4))
                .background(.white.opacity(0.12), in: Capsule())
            }
            .focusSection()
        }
        .pagePadding()
        .padding(.top, pageTop)
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
        folders = isBoxSet ? [CollectionPage(parent: view.id)] : []
        visitedFolders = [view.id]
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
        guard !loading, (isBoxSet ? !folders.isEmpty : offset < total), let asked = activeQuery, asked == query,
              let client = session.client, let userId = session.userId else { return }
        let id = loadID
        loading = true
        failure = nil
        defer { if id == loadID { loading = false } }

        do {
            if isBoxSet {
                try await loadCollectionPage(client: client, userId: userId, asked: asked, id: id)
                return
            }
            let result: ItemsResult = try await client.get("/Items", [
                "userId": userId,
                "ParentId": latest ? nil : view.id,
                "StartIndex": String(offset),
                "Limit": String(Self.page),
                "IncludeItemTypes": collectionCovers ? "BoxSet" : libraryTypes(view),
                "GenreIds": genre,
                "Recursive": collectionCovers ? "false" : "true",
                "EnableTotalRecordCount": "true",
                "Filters": asked.filter?.jellyfin,
                "SortBy": latest ? "DateCreated" : session.isStock && !collectionCovers ? asked.sort.fields : nil,
                "SortOrder": latest ? "Descending" : session.isStock && !collectionCovers ? (asked.descending ? "Descending" : "Ascending") : nil,
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

    /// Some AIOStreams/AIOMetadata box sets list subfolders before their titles. Walk those on
    /// behalf of the viewer and apply the type filter to the actual movies and shows.
    private func loadCollectionPage(client: JellyfinClient, userId: String, asked: Query, id: UUID) async throws {
        var pending = folders
        var visited = visitedFolders
        var seen = Set(items.map(\.id))
        var titles: [Item] = []

        while let folder = pending.first, titles.count < Self.page {
            let result: ItemsResult = try await client.get("/Items", [
                "userId": userId,
                "ParentId": folder.parent,
                "StartIndex": String(folder.offset),
                "Limit": String(Self.page),
                "Recursive": "false",
                "EnableTotalRecordCount": "true",
            ])
            guard !Task.isCancelled, id == loadID, asked == query else { return }
            let page = result.items ?? []
            let nextOffset = folder.offset + page.count
            if page.isEmpty || nextOffset >= (result.totalRecordCount ?? Int.max) {
                pending.removeFirst()
            } else {
                pending[0].offset = nextOffset
            }
            for item in page {
                if item.isFolder {
                    if visited.insert(item.id).inserted { pending.append(CollectionPage(parent: item.id)) }
                } else if (item.type == "Movie" || item.isSeries),
                          asked.collection.itemTypes.map({ $0 == item.type }) ?? true,
                          seen.insert(item.id).inserted {
                    titles.append(item)
                }
            }
        }

        folders = pending
        visitedFolders = visited
        items.append(contentsOf: titles)
    }
}

private struct CollectionSegmentStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Focused { focused in
            configuration.label
                .foregroundStyle(selected ? Color.black : focused ? Color.white : Theme.gray300)
                .background(selected ? Color.white : focused ? Color.white.opacity(0.2) : .clear, in: Capsule())
                .opacity(configuration.isPressed ? 0.8 : 1)
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
    @State private var media: Media = .all
    @State private var watch: Watch = .all
    @State private var resumingIDs = Set<String>()
    @State private var loadID = UUID()

    private enum Media: CaseIterable {
        case all, movies, shows

        var title: String {
            switch self {
            case .all: return L("All")
            case .movies: return L("Movies")
            case .shows: return L("Shows")
            }
        }

        func matches(_ item: Item) -> Bool {
            switch self {
            case .all: return true
            case .movies: return item.type == "Movie"
            case .shows: return item.isSeries || item.isEpisode
            }
        }
    }

    private enum Watch: CaseIterable {
        case all, watched, inProgress, notStarted

        var title: String {
            switch self {
            case .all: return L("All")
            case .watched: return L("Watched")
            case .inProgress: return L("In progress")
            case .notStarted: return L("Not started")
            }
        }
    }

    private var filtered: [Item] {
        items.filter { item in
            guard media.matches(item) else { return false }
            if watch == .all { return true }
            let state: Watch
            if item.resumeMs != nil || resumingIDs.contains(item.id) {
                state = .inProgress
            } else if item.userData?.played == true {
                state = .watched
            } else if item.isSeries && (item.userData?.lastPlayedDate != nil || item.aiostreams?.showWatchedAt != nil) {
                state = .inProgress
            } else {
                state = .notStarted
            }
            return state == watch
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.px(10)) {
                PageTitle(text: L("Favorites"))
                HStack {
                    segments(Media.allCases, selection: $media, title: { $0.title })
                        .accessibilityLabel(L("Media type"))
                    Spacer(minLength: Theme.px(12))
                    segments(Watch.allCases, selection: $watch, title: { $0.title })
                        .accessibilityLabel(L("Watch status"))
                }
                .pagePadding()
                .focusSection()
                SortFilterBar(filter: .constant(nil), sorts: [.added, .name, .released, .rating], sort: $sort, descending: $descending)
                if loaded && filtered.isEmpty {
                    Text(items.isEmpty ? L("Titles you favorite show here.") : L("No favorites match these filters."))
                        .font(Theme.font(Theme.base))
                        .foregroundStyle(Theme.gray400)
                        .pagePadding()
                        .padding(.vertical, Theme.px(16))
                        .focusable()
                }
                PosterGrid(items: filtered)
            }
            .padding(.bottom, pageMargin)
        }
        .edgeToEdge()
        .task { await load() }
        .refreshOnReturn { await load() }
        .reloadOnWatchChange { await load() }
        .onChange(of: "\(sort.rawValue)|\(descending)") { _, _ in Task { await load() } }
    }

    private func segments<Option: Hashable>(_ options: [Option], selection: Binding<Option>,
                                            title: @escaping (Option) -> String) -> some View {
        HStack(spacing: Theme.px(3)) {
            ForEach(options, id: \.self) { option in
                Button { selection.wrappedValue = option } label: {
                    Text(title(option))
                        .font(Theme.font(Theme.sm, .semibold))
                        .padding(.horizontal, Theme.px(12))
                        .padding(.vertical, Theme.px(6))
                }
                .buttonStyle(CollectionSegmentStyle(selected: selection.wrappedValue == option))
                .accessibilityAddTraits(selection.wrappedValue == option ? .isSelected : [])
            }
        }
        .padding(Theme.px(4))
        .background(.white.opacity(0.12), in: Capsule())
    }

    private func load() async {
        guard let client = session.client, let userId = session.userId else { return }
        let id = UUID()
        loadID = id
        async let resume: ItemsResult? = try? client.get("/UserItems/Resume", [
            "userId": userId, "MediaTypes": "Video", "Limit": "250",
        ])
        async let favorites: ItemsResult? = try? client.get("/Items", [
            "userId": userId,
            "Filters": "IsFavorite",
            "Recursive": "true",
            "IncludeItemTypes": "Movie,Series,Episode",
            "SortBy": sort.fields,
            "SortOrder": descending ? "Descending" : "Ascending",
        ])
        let (result, progress) = await (favorites, resume)
        guard !Task.isCancelled, loadID == id else { return }
        items = result?.items ?? items
        if let progress {
            resumingIDs = Set((progress.items ?? []).flatMap { item in
                [item.id, item.seriesId].compactMap { $0 }
            })
        }
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
    @State private var channelResults: [Item] = []
    @State private var searchedTerm = ""
    @State private var hints: [Hint] = []
    @State private var hintedTerm = ""
    @State private var chosenTerm = ""

    private struct Hint: Decodable {
        let name: String?
        let productionYear: Int?
    }

    private struct HintResult: Decodable {
        let searchHints: [Hint]
    }

    private var query: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var searching: Bool { query.count >= 2 && query != searchedTerm }
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
        .task(id: query) { await search(query) }
        .task(id: query) { await suggest(query) }
    }

    private func grid(in edges: Edge.Set) -> some View {
        ScrollView {
            if hintedTerm == query, chosenTerm != query, !hints.isEmpty {
                suggestions
            }
            let titles = searchedTerm == query ? results : []
            let channels = searchedTerm == query ? channelResults : []
            if !channels.isEmpty {
                VStack(alignment: .leading, spacing: Theme.px(8)) {
                    Text(L("Live TV")).font(Theme.font(Theme.xl, .semibold)).pagePadding()
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
                PosterGrid(items: titles)
            } else {
                // A section each, as the web app's search shows them unless they're combined.
                let movies = titles.filter { $0.type == "Movie" }
                let shows = titles.filter(\.isSeries)
                VStack(alignment: .leading, spacing: Theme.px(8)) {
                    if !movies.isEmpty {
                        Text(L("Movies")).font(Theme.font(Theme.xl, .semibold)).pagePadding()
                        PosterGrid(items: movies)
                    }
                    if !shows.isEmpty {
                        Text(L("Shows")).font(Theme.font(Theme.xl, .semibold)).pagePadding()
                        PosterGrid(items: shows)
                    }
                }
            }
            if searching { ProgressView() }
            if !searching && query.count >= 2 && titles.isEmpty && channels.isEmpty {
                Text(L("No results for “%@”.", "\(term)")).font(Theme.font(Theme.base)).foregroundStyle(Theme.gray400)
            }
        }
        // Edge to edge across, but under the full keyboard, which takes the top of the screen:
        // ignoring that inset or drawing past the scroll view put results behind it. The grid
        // keyboard takes the left instead, so then only the right is ignored.
        .ignoresSafeArea(edges: edges)
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: Theme.px(5)) {
            Text(L("Suggestions")).font(Theme.font(Theme.sm, .semibold)).foregroundStyle(Theme.gray300)
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                if let name = hint.name, !name.isEmpty {
                    Button {
                        chosenTerm = name
                        term = name
                    } label: {
                        HStack(spacing: Theme.px(10)) {
                            Label(name, systemImage: "magnifyingglass").lineLimit(1)
                            if let year = hint.productionYear {
                                Text(String(year)).foregroundStyle(Theme.gray400)
                            }
                        }
                    }
                    .buttonStyle(SoftPillStyle())
                }
            }
        }
        .pagePadding()
        .focusSection()
    }

    private func suggest(_ query: String) async {
        guard query.count >= 2, query != chosenTerm else { return }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled, let client = session.client, let userId = session.userId else { return }
        let result: HintResult? = try? await client.get("/Search/Hints", [
            "userId": userId, "SearchTerm": query, "IncludeItemTypes": "Movie,Series", "Limit": "5",
        ])
        guard !Task.isCancelled, self.query == query else { return }
        hints = result?.searchHints ?? []
        hintedTerm = query
    }

    private func search(_ query: String) async {
        guard query.count >= 2 else {
            results = []
            channelResults = []
            searchedTerm = ""
            chosenTerm = ""
            return
        }
        if chosenTerm != query { chosenTerm = "" }
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled, let client = session.client, let userId = session.userId else { return }
        let parameters: [String: String?] = [
            "userId": userId, "SearchTerm": query, "Recursive": "true", "Limit": "48",
        ]
        async let titles: ItemsResult? = try? client.get("/Items", parameters.merging(["IncludeItemTypes": "Movie,Series"]) { _, next in next })
        async let channels: ItemsResult? = try? client.get("/Items", parameters.merging(["IncludeItemTypes": "TvChannel"]) { _, next in next })
        let (foundTitles, foundChannels) = await (titles, channels)
        guard !Task.isCancelled, self.query == query else { return }
        let live = (foundChannels?.items ?? []).filter(\.isChannel)
        let liveIDs = Set(live.map(\.id))
        results = (foundTitles?.items ?? []).filter {
            ($0.type == "Movie" || $0.isSeries) && $0.channelId == nil && !liveIDs.contains($0.id)
        }
        channelResults = live
        searchedTerm = query
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
        case .favorite: return L("Favorites")
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
