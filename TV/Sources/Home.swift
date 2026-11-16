import SwiftUI
import TVServices

// The web app's home (pages/home.tsx, components/hero.tsx) as a TV shows it by default:
// a rotating hero over the first rows, then Continue watching, Next up and each library.

/// The web app's hero picks: the heads of the Movies and Shows libraries, interleaved.
private let heroPerLibrary = 8
private let heroMax = 10

/// What's partway through, then the next episodes, one card a show, most recently watched or aired first,
/// as the web app merges them (lib/jellyfin/queries.ts `mergeRows`).
func mergeRows(_ resume: [Item], _ nextUp: [Item]) -> [Item] {
    var seen = Set<String>()
    let kept = (resume + nextUp).filter { item in
        let keys = [item.id, item.seriesId].compactMap { $0 }
        guard !keys.contains(where: seen.contains) else { return false }
        seen.formUnion(keys)
        return true
    }
    // The later of when it was last watched and, for a next episode, when it aired (not still to come),
    // as the web app sorts it since Android v0.15.0; a next episode with no watch time stays last.
    let watched = { (item: Item) -> Date in
        guard let last = parseDate(item.aiostreams?.showWatchedAt ?? item.userData?.lastPlayedDate) else { return .distantPast }
        let aired = min(parseDate(item.premiereDate) ?? .distantPast, Date())
        return max(last, aired)
    }
    // Stable, so next episodes without a time stay after what's partway through.
    return kept.enumerated()
        .sorted { a, b in
            let (x, y) = (watched(a.element), watched(b.element))
            return x != y ? x > y : a.offset < b.offset
        }
        .map(\.element)
}

struct HomeView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @State private var hero: [Item] = []
    @State private var resume: [Item] = []
    @State private var nextUp: [Item] = []
    /// Episodes of shows you follow airing soon (Jellyfin's Shows/Upcoming), as the web app's row.
    @State private var upcoming: [Item] = []
    @Environment(\.openRoute) private var openRoute
    @Environment(\.openPlace) private var openPlace
    /// Favourite channels with what's on now.
    @State private var channels: [Item] = []
    @State private var airing: [String: Item] = [:]
    @State private var libraries: [HomeRow] = []
    @State private var collectionRows: [HomeRow] = []
    @State private var loaded = false
    @State private var loading = false
    @State private var error: String?
    @State private var choice: VersionChoice?

    /// The focused card's title, which a following hero shows.
    @State private var followed: Item?

    /// Hero: rotates through featured titles, or follows the focused card, pinned over the rows.
    private var following: Bool { prefs.heroMode != "rotate" }

    var body: some View {
        Group {
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if following && !hero.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HeroCarousel(items: hero, play: play, followed: followed ?? hero.first,
                                 height: prefs.heroMode == "corner" ? Theme.px(360) : Theme.px(456))
                    ScrollView { rows }
                        .edgeToEdge()
                }
            } else {
                ScrollView { rows }
                    .edgeToEdge()
            }
        }
        .environment(\.cardFocused, { item in if following { followed = item } })
        .task(id: prefs.loaded) { if prefs.loaded && !loaded { await load() } }
        .onChange(of: prefs.featured) { _, _ in Task { await load() } }
        .refreshOnReturn { await load() }
        .reloadOnWatchChange { await load() }
        .playFlow($choice) { Task { await load() } }
    }

    private var rows: some View {
            LazyVStack(alignment: .leading, spacing: Theme.px(40)) {
                if !hero.isEmpty && !following {
                    HeroCarousel(items: hero, play: play)
                        // Rows sit just under it.
                        .padding(.bottom, -Theme.px(32))
                } else {
                    Color.clear.frame(height: Theme.px(16))
                }
                // With "Merge continue watching and next up" on, one row holds both, as the web app's.
                let merging = prefs.flag("mergeNextUp", false)
                let continuing = merging ? mergeRows(resume, nextUp) : resume
                if !continuing.isEmpty {
                    // Activity is in the rail, so the row needs no button of its own.
                    WideRow(title: L("Continue watching"), items: continuing, play: play) { EmptyView() }
                }
                if !merging && !nextUp.isEmpty {
                    WideRow(title: L("Next up"), items: nextUp, play: play) { EmptyView() }
                }
                if !channels.isEmpty {
                    LiveRow(channels: channels, airing: airing, play: playChannel) {
                        Button { openPlace(.live) } label: {
                            Label(L("All channels"), systemImage: "play.tv")
                        }
                        .buttonStyle(SoftPillStyle())
                    }
                }
                if !upcoming.isEmpty {
                    // Nothing to play yet, so a card opens its show.
                    WideRow(title: L("Upcoming"), items: upcoming, upcoming: true, play: openShow) { EmptyView() }
                }
                ForEach(collectionRows) { row in
                    ItemRow(row: row)
                }
                ForEach(libraries) { row in
                    ItemRow(row: row)
                }
                if loading && hero.isEmpty && libraries.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, Theme.px(200))
                }
                if !loading && hero.isEmpty && resume.isEmpty && nextUp.isEmpty && upcoming.isEmpty
                    && channels.isEmpty && collectionRows.isEmpty && libraries.isEmpty {
                    VStack(spacing: Theme.px(16)) {
                        Text(error ?? L("Nothing here yet. Add catalogs to your configuration."))
                            .font(Theme.font(Theme.base))
                            .foregroundStyle(Theme.gray400)
                        Button(L("Try again")) { Task { await load() } }
                            .buttonStyle(SoftPillStyle())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.px(200))
                }
            }
            .padding(.bottom, Theme.px(64))
    }

    /// Home only shows favourite channels. Viewing history belongs to Live TV.
    private func loadChannels(client: JellyfinClient, userId: String) async {
        let limit = 20
        let favourites: ItemsResult? = try? await client.get("/LiveTv/Channels", [
            "userId": userId, "IsFavorite": "true", "Limit": String(limit), "AddCurrentProgram": "true",
        ])
        guard !Task.isCancelled, let favourites else { return }
        channels = favourites.items ?? []
        guard !channels.isEmpty else { return }
        let now: ItemsResult? = try? await client.post("/LiveTv/Programs", body: [
            "UserId": userId, "ChannelIds": channels.map(\.id), "IsAiring": true, "Fields": ["Overview"],
        ])
        guard !Task.isCancelled else { return }
        airing = Dictionary((now?.items ?? []).compactMap { programme in programme.channelId.map { ($0, programme) } }) { first, _ in first }
    }

    private func playChannel(_ channel: Item) {
        choice = VersionChoice(item: channel, startMs: nil, mode: .straight)
    }

    /// An upcoming episode's show, or the title itself.
    private func openShow(_ item: Item) {
        if let series = item.seriesId {
            openRoute(.item(Item(id: series, name: item.seriesName, type: "Series")))
        } else {
            openRoute(.item(item))
        }
    }

    private func play(_ item: Item) {
        Task { choice = await playChoice(for: item, session: session) }
    }

    private func load() async {
        guard prefs.loaded, !loading, let client = session.client, let userId = session.userId else { return }
        let profile = session.profileID
        loading = true
        error = nil
        defer {
            loading = false
            if !Task.isCancelled { loaded = true }
        }
        do {
            async let resumeResult: ItemsResult = client.get("/UserItems/Resume", ["userId": userId, "Limit": "24", "MediaTypes": "Video"])
            async let nextResult: ItemsResult = client.get("/Shows/NextUp", ["userId": userId, "Limit": "24", "EnableResumable": "false"])
            async let upcomingResult: ItemsResult = client.get("/Shows/Upcoming", ["userId": userId, "Limit": "24"])
            async let viewsResult: ItemsResult = client.get("/UserViews", ["userId": userId])
            // Assigning only on change keeps SwiftUI's views (and the focused card) in place on a refresh.
            let newResume = try? await resumeResult.items
            let newNextUp = try? await nextResult.items
            let newUpcoming = try? await upcomingResult.items
            let allViews = try await viewsResult.items ?? []
            let views = allViews.filter(isBrowsable)
            let hasLiveTV = allViews.contains { $0.collectionType == "livetv" }
            let needsRootCollections = session.isStock && !views.contains { $0.collectionType == "boxsets" }
            async let rootBoxSets: ItemsResult? = needsRootCollections ? try? client.get("/Items", [
                "userId": userId, "IncludeItemTypes": "BoxSet", "Recursive": "true",
                "Limit": "24", "SortBy": "SortName",
            ]) : nil

            // Each library's head, in the configuration's order, as each arrives.
            var heads: [Int: (Item, [Item])] = [:]
            let previousRows = libraries
            let previousCollections = collectionRows
            await withTaskGroup(of: (Int, Item, [Item]?).self) { group in
                for (index, view) in views.enumerated() {
                    group.addTask {
                        let genre = await openingGenre(client, userId: userId, view: view)
                        let result: ItemsResult? = try? await client.get("/Items", [
                            "userId": userId,
                            "ParentId": view.id,
                            "IncludeItemTypes": libraryTypes(view),
                            "GenreIds": genre,
                            "Recursive": view.collectionType == "boxsets" ? "false" : "true",
                            "Limit": "24",
                            "Fields": "Overview,Genres",
                        ])
                        return (index, view, result.map { $0.items ?? [] })
                    }
                }
                for await (index, view, items) in group {
                    let previous = (previousRows.first { $0.id == view.id }?.items ?? [])
                        + (previousCollections.first { $0.id == "collections.\(view.id)" }?.items ?? [])
                    heads[index] = (view, items ?? previous)
                }
            }
            let nativeBoxSets = await rootBoxSets?.items ?? []
            guard !Task.isCancelled, profile == session.profileID else { return }
            if let newResume, newResume != resume { resume = newResume }
            if let newNextUp, newNextUp != nextUp { nextUp = newNextUp }
            if let newUpcoming, newUpcoming != upcoming { upcoming = newUpcoming }
            saveTopShelf(client: client)

            var collections = heads.keys.sorted().compactMap { key -> HomeRow? in
                guard let (view, items) = heads[key] else { return nil }
                let covers = items.filter { $0.type == "BoxSet" }
                guard !covers.isEmpty else { return nil }
                return HomeRow(id: "collections.\(view.id)", title: view.name ?? L("Collections"), items: covers,
                               library: view.collectionType == "boxsets" ? view : nil, wide: true, collection: true)
            }
            if !nativeBoxSets.isEmpty {
                collections.append(HomeRow(id: "home.boxsets", title: L("Collections"), items: nativeBoxSets,
                                           wide: true, collection: true))
            }
            if !sameRows(collections, collectionRows) { collectionRows = collections }
            let rows = homeRows(heads)
            if !sameRows(rows, libraries) { libraries = rows }
            let picks = heroPicks(views: views, heads: heads, client: client)
            if picks != hero {
                hero = picks
            }
            loaded = true
            if hasLiveTV {
                await loadChannels(client: client, userId: userId)
            } else {
                channels = []
                airing = [:]
            }
        } catch let failure as JellyfinError where failure.status == 401 {
            if !Task.isCancelled { session.expired(client) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Continue watching and Next up, for the Apple TV's home screen (Top Shelf).
    private func saveTopShelf(client: JellyfinClient) {
        func entries(_ items: [Item]) -> [TopShelfStore.Entry] {
            items.prefix(12).map { item in
                let title = item.isEpisode
                    ? [item.seriesName, item.episodeCode].compactMap { $0 }.joined(separator: " · ")
                    : item.name ?? ""
                let progress = item.userData?.playedPercentage.map { $0 / 100 }
                return TopShelfStore.Entry(id: item.id, title: title, image: client.still(item, height: 540),
                                           progress: progress.flatMap { $0 > 0 ? $0 : nil })
            }
        }
        let sections: [TopShelfStore.Section] = prefs.flag("mergeNextUp", false)
            ? [.init(title: L("Continue watching"), entries: entries(mergeRows(resume, nextUp)))]
            : [.init(title: L("Continue watching"), entries: entries(resume)), .init(title: L("Next up"), entries: entries(nextUp))]
        TopShelfStore.save(.init(sections: sections))
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    /// What the web app's Featured on home names (`resume`, `next-up`, `view:<id>`), taking turns;
    /// on Automatic, the Movies and Shows libraries' heads, or the first library's. Only titles with
    /// a backdrop.
    private func homeRows(_ heads: [Int: (Item, [Item])]) -> [HomeRow] {
        heads.keys.sorted().compactMap { key in
            guard let entry = heads[key] else { return nil }
            let titles = entry.1.filter { $0.type != "BoxSet" }
            guard !titles.isEmpty else { return nil }
            return HomeRow(id: entry.0.id, title: entry.0.name ?? L("Library"), items: titles, library: entry.0)
        }
    }

    /// Same rows, titles and titles in the same order, each as it was, its progress and watched
    /// mark included: nothing the screen would show differently.
    private func sameRows(_ a: [HomeRow], _ b: [HomeRow]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { x, y in
            x.id == y.id && x.title == y.title && x.items == y.items
        }
    }

    private func heroPicks(views: [Item], heads: [Int: (Item, [Item])], client: JellyfinClient) -> [Item] {
        let lists = heads.keys.sorted().compactMap { heads[$0] }
        var sources: [[Item]]
        // A removed library is skipped, and a list left without any is automatic, as the web app has it.
        let chosen = prefs.featured?.filter { source in
            !source.hasPrefix("view:") || views.contains { "view:\($0.id)" == source }
        }
        if let chosen, !(chosen.isEmpty && !(prefs.featured ?? []).isEmpty) {
            sources = chosen.map { source in
                switch source {
                case "resume": return prefs.flag("mergeNextUp", false) ? mergeRows(resume, nextUp) : resume
                case "next-up": return nextUp
                default: return lists.first { "view:\($0.0.id)" == source }?.1 ?? []
                }
            }
        } else {
            sources = ["movies", "tvshows"].compactMap { kind in lists.first { $0.0.collectionType == kind }?.1 }
            if sources.isEmpty, let first = lists.first?.1 { sources = [first] }
        }
        let candidates = sources.map { Array($0.prefix(heroPerLibrary)) }
        var picks: [Item] = []
        var seen = Set<String>()
        for index in 0..<(candidates.map(\.count).max() ?? 0) {
            for list in candidates where index < list.count && picks.count < heroMax {
                let item = list[index]
                guard item.type != "BoxSet", !item.isChannel, !seen.contains(item.id), client.backdrop(item, height: 100) != nil,
                      item.backdropImageTags?.isEmpty == false || item.parentBackdropImageTags?.isEmpty == false || item.seriesId != nil else { continue }
                seen.insert(item.id)
                picks.append(item)
            }
        }
        return picks
    }
}

// MARK: - Hero

private enum HeroAction: Hashable { case play, info, next, previous }

/// One title at a time over the top of Home, turning every 9 seconds while nothing in it has focus.
/// Right past its last button turns to the next title; left past its first, to the one before.
struct HeroCarousel: View {
    @EnvironmentObject private var session: Session
    let items: [Item]
    let play: (Item) -> Void
    /// The focused card's title, which the hero shows instead of rotating (Hero: follows the card).
    var followed: Item? = nil
    var height: CGFloat = HeroCarousel.height

    @State private var selectedID: String?
    private var index: Int { items.firstIndex { $0.id == selectedID } ?? 0 }
    @FocusState private var focus: HeroAction?
    /// When the hero last turned, as the new title's details take a moment to take focus.
    @State private var turnedAt = Date.distantPast

    /// `max(36rem, 53vh)` on a 720-line TV.
    static let height = Theme.px(576)
    @EnvironmentObject private var prefs: Preferences

    private var item: Item { followed ?? items[min(index, items.count - 1)] }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdrop
            shade
            details
                .id(item.id)
                .transition(.opacity)
            if items.count > 1 && followed == nil { dots }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.6), value: index)
        .task(id: "\(item.id)-\(items.count)-\(focus == nil)-\(prefs.heroSeconds)") {
            guard focus == nil, items.count > 1, followed == nil else { return }
            try? await Task.sleep(for: .seconds(prefs.heroSeconds))
            guard !Task.isCancelled, focus == nil else { return }
            selectedID = items[(index + 1) % items.count].id
        }
        // Background from artwork: the hero's title, turning with it.
        .washed(by: item)
        // Right past More info, or left past the first button, focus lands on a slip beside them,
        // which turns the hero and hands focus back; a press can't skip the button it lands on.
        .onChange(of: focus) { _, now in
            guard now == .next || now == .previous else { return }
            // Right after a turn, the new details are still arriving and focus can fall on a slip
            // by itself, which isn't a press: it goes to the new title's first button instead.
            if Date().timeIntervalSince(turnedAt) < 0.8 {
                settle(on: items[index].playable ? .play : .info)
                return
            }
            let next = now == .next ? (index + 1) % items.count : (index - 1 + items.count) % items.count
            selectedID = items[next].id
            turnedAt = Date()
            settle(on: now == .next ? (items[index].playable ? .play : .info) : .info)
        }
    }

    /// Puts focus on a button of the title now showing, once its details are in place.
    private func settle(on target: HeroAction) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            focus = target
        }
    }

    /// A narrow, invisible stop beside the buttons that turns the hero when focus reaches it.
    private func slip(_ action: HeroAction, enabled: Bool) -> some View {
        Color.clear
            .frame(width: Theme.px(8), height: Theme.px(40))
            .focusable(enabled)
            .focused($focus, equals: action)
    }

    /// Keep the entire backdrop in frame and hold its picture until the next one loads.
    private var backdrop: some View {
        HeroArtwork(url: session.client?.backdrop(item, height: 1080))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var shade: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.78), .clear], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .bottom, endPoint: .center)
        }
        .allowsHitTesting(false)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Theme.px(16)) {
            TitleLogo(item: item, maxHeight: Theme.px(112), maxWidth: Theme.px(384), titleSize: 48)
            HeroMeta(item: item)
            if let overview = item.overview, !overview.isEmpty {
                Text(overview)
                    .font(Theme.font(Theme.base))
                    .foregroundStyle(Theme.gray300)
                    .lineLimit(3)
                    .frame(maxWidth: Theme.px(672), alignment: .leading)
            }
            HStack(spacing: Theme.px(8)) {
                // Always there, so the buttons never shift; it takes focus only past the first title.
                slip(.previous, enabled: items.count > 1 && followed == nil && index > 0)
                if item.playable {
                    Button { play(item) } label: {
                        Label(L("Play"), systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryPillStyle())
                    .focused($focus, equals: .play)
                }
                NavigationLink(value: Route.item(item)) {
                    Label(L("More info"), systemImage: "info.circle")
                }
                .buttonStyle(item.playable ? AnyButtonStyle(SecondaryPillStyle()) : AnyButtonStyle(PrimaryPillStyle()))
                .focused($focus, equals: .info)
                slip(.next, enabled: items.count > 1 && followed == nil)
            }
            // The left slip and its gap sit out past the edge, keeping the buttons under the title.
            .padding(.leading, -Theme.px(16))
            .focusSection()
        }
        .frame(maxWidth: Theme.px(768), alignment: .leading)
        .padding(.leading, Theme.px(20))
        .padding(.bottom, Theme.px(56))
    }

    private var dots: some View {
        HStack(spacing: Theme.px(6)) {
            ForEach(items.indices, id: \.self) { at in
                Capsule()
                    .fill(at == index ? Color.white : Color.white.opacity(0.35))
                    .frame(width: at == index ? Theme.px(24) : Theme.px(6), height: Theme.px(6))
            }
        }
        .padding(.trailing, Theme.px(16))
        .padding(.bottom, Theme.px(56))
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Wraps a button style chosen at run time.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// A title's logo artwork where it has one; its name in large type otherwise.
struct TitleLogo: View {
    @EnvironmentObject private var session: Session
    let item: Item
    let maxHeight: CGFloat
    let maxWidth: CGFloat
    let titleSize: CGFloat

    var body: some View {
        if let url = session.client?.logo(item, width: Int(maxWidth * 2)) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: .leading)
                case .failure:
                    title
                default:
                    Color.clear.frame(width: maxWidth, height: maxHeight)
                }
            }
        } else {
            title
        }
    }

    private var title: some View {
        Text(item.isEpisode ? (item.seriesName ?? item.displayTitle) : (item.name ?? ""))
            .font(Theme.font(titleSize, .bold))
            .lineLimit(2)
            .frame(maxWidth: Theme.px(640), alignment: .leading)
    }
}

/// `2025 • ★ 8.3 • Drama, Crime`, or an episode's code and name for the first part.
private struct HeroArtwork: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .overlay {
                GeometryReader { geometry in
                    if let image {
                        ZStack {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .blur(radius: Theme.px(32), opaque: true)
                                .opacity(0.55)
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                        }
                        .clipped()
                    }
                }
            }
            .task(id: url) {
                guard let url else { image = nil; return }
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    guard !Task.isCancelled else { return }
                    if let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) {
                        image = UIImage(data: data)
                    } else {
                        image = nil
                    }
                } catch {
                    if !Task.isCancelled { image = nil }
                }
            }
    }
}

struct HeroMeta: View {
    let item: Item

    var body: some View {
        var parts: [AnyView] = []
        if item.isEpisode {
            parts.append(AnyView(Text(item.displayTitle)))
        } else if let year = item.productionYear {
            parts.append(AnyView(Text(String(year))))
        }
        if let score = item.communityRating, score > 0 {
            parts.append(AnyView(HStack(spacing: Theme.px(4)) {
                Image(systemName: "star.fill").foregroundStyle(Theme.star).font(.system(size: Theme.px(12)))
                Text(String(format: "%.1f", score))
            }))
        }
        if let genres = item.genres, !genres.isEmpty {
            parts.append(AnyView(Text(genres.prefix(3).joined(separator: ", "))))
        }
        return MetaLine(parts: parts)
            .font(Theme.font(Theme.sm))
            .foregroundStyle(Theme.gray200)
    }
}

// MARK: - Rows

/// What's under way, as stills that play from the row: the web app's EpisodeRow.
struct WideRow<Action: View>: View {
    let title: String
    let items: [Item]
    /// Cards with the day each airs, and how long until then.
    var upcoming = false
    let play: (Item) -> Void
    @ViewBuilder let action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(12)) {
            HStack {
                Text(title).font(Theme.font(Theme.xl, .semibold))
                Spacer()
                action()
            }
            .pagePadding()
            .focusSection()
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Theme.px(16)) {
                    ForEach(items) { item in
                        WideCard(item: item, upcoming: upcoming) { play(item) }
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

/// A 304 × 171 still with how far it got, its name and time left, and the episode or year under it.
struct WideCard: View {
    @Environment(\.cardFocused) private var cardFocused
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @FocusState private var focused: Bool
    let item: Item
    /// Not out yet: the air day over the still, and how long until it beside the name.
    var upcoming = false
    let action: () -> Void

    private var airs: Date? { upcoming ? parseDate(item.premiereDate) : nil }
    /// Spoiler blur: an episode not started, until it has focus.
    private var hidden: Bool { prefs.blurSpoilers && item.unstarted && !focused }

    static let size = CGSize(width: Theme.px(304), height: Theme.px(171))

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(8)) {
            Button(action: action) {
                ZStack(alignment: .bottom) {
                    RemoteImage(url: session.client?.still(item, height: Int(Self.size.height * 2)))
                        .frame(width: Self.size.width, height: Self.size.height)
                        .blur(radius: hidden ? Theme.px(12) : 0, opaque: true)
                        .animation(.easeOut(duration: 0.3), value: hidden)
                        .overlay(alignment: .topLeading) {
                            if let airs {
                                Text(airs.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(AppLanguage.locale)))
                                    .font(Theme.font(Theme.xs, .semibold))
                                    .padding(.horizontal, Theme.px(8))
                                    .padding(.vertical, Theme.px(3))
                                    .background(Capsule().fill(.black.opacity(0.75)))
                                    .padding(Theme.px(8))
                            }
                        }
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
                .frame(width: Self.size.width, height: Self.size.height)
                .clipShape(RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous))
            }
            .buttonStyle(CardStyle())
            .focused($focused)
            .onChange(of: focused) { _, on in if on { cardFocused(item) } }
            .itemMenu(item)
            VStack(alignment: .leading, spacing: Theme.px(2)) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.isEpisode ? (item.seriesName ?? "") : (item.name ?? ""))
                        .font(Theme.font(15, .semibold))
                        .lineLimit(1)
                    Spacer(minLength: Theme.px(8))
                    if let until = airs.map(untilLabel) ?? item.timeLeft {
                        Text(until).font(Theme.font(Theme.xs)).foregroundStyle(Theme.gray400)
                    }
                }
                Text(item.isEpisode ? item.displayTitle : item.productionYear.map(String.init) ?? "")
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.gray400)
                    .lineLimit(1)
                    .blur(radius: hidden ? Theme.px(5) : 0)
                    .animation(.easeOut(duration: 0.3), value: hidden)
            }
            .padding(.horizontal, Theme.px(2))
            .frame(width: Self.size.width, alignment: .leading)
        }
    }
}

/// How long until a date, as the web app's Upcoming row says it: today, tomorrow, in 5 days, in 3 weeks.
func untilLabel(_ date: Date) -> String {
    let calendar = Calendar.current
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: date)).day ?? 0
    switch days {
    case ..<1: return L("today")
    case 1: return L("tomorrow")
    case ..<14: return L("in %ld days", days)
    default: return L("in %ld weeks", Int((Double(days) / 7).rounded()))
    }
}

/// Channels as wide cards: the logo over a dark tile, the channel's name and what's on, with how far
/// through it is. Selecting one plays it live.
struct LiveRow<Action: View>: View {
    let channels: [Item]
    let airing: [String: Item]
    let play: (Item) -> Void
    @ViewBuilder let action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(12)) {
            HStack {
                Text(L("Live TV")).font(Theme.font(Theme.xl, .semibold))
                Spacer()
                action()
            }
            .pagePadding()
            .focusSection()
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Theme.px(16)) {
                    ForEach(channels) { channel in
                        ChannelCard(channel: channel, airing: airing[channel.id]) { play(channel) }
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

struct ChannelCard: View {
    let channel: Item
    let airing: Item?
    let action: () -> Void

    /// What's on: from the guide, else what the channel list sent along.
    private var programme: (name: String, start: Date?, end: Date?)? {
        if let airing { return (airing.name ?? "", airing.starts, airing.ends) }
        if let current = channel.currentProgram { return (current.name ?? "", current.starts, current.ends) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(8)) {
            Button(action: action) {
                ZStack(alignment: .bottom) {
                    ZStack {
                        Theme.gray900
                        ChannelLogo(channel: channel)
                            .frame(width: Theme.px(160), height: Theme.px(90))
                    }
                    .frame(width: WideCard.size.width, height: WideCard.size.height)
                    if let programme {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.25))
                                Rectangle().fill(Theme.brand500)
                                    .frame(width: geometry.size.width * airedShare(from: programme.start, to: programme.end, now: Date()))
                            }
                        }
                        .frame(height: Theme.px(4))
                    }
                }
                .frame(width: WideCard.size.width, height: WideCard.size.height)
                .clipShape(RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous))
            }
            .buttonStyle(CardStyle())
            VStack(alignment: .leading, spacing: Theme.px(2)) {
                HStack(spacing: Theme.px(6)) {
                    if let number = channel.channelNumber {
                        Text(number).foregroundStyle(Theme.gray400).monospacedDigit()
                    }
                    Text(channel.name ?? "").lineLimit(1)
                }
                .font(Theme.font(15, .semibold))
                Text(programme?.name ?? L("Live"))
                    .font(Theme.font(13))
                    .foregroundStyle(Theme.gray400)
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.px(2))
            .frame(width: WideCard.size.width, alignment: .leading)
        }
    }
}

/// Told which card has focus, for a hero that follows it.
private struct CardFocusedKey: EnvironmentKey {
    static let defaultValue: (Item) -> Void = { _ in }
}

extension EnvironmentValues {
    var cardFocused: (Item) -> Void {
        get { self[CardFocusedKey.self] }
        set { self[CardFocusedKey.self] = newValue }
    }
}
