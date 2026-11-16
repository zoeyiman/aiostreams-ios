import SwiftUI
import TVServices

// The web app's home (pages/home.tsx, components/hero.tsx) as a TV shows it by default:
// a rotating hero over the server catalogs featured on Home.

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

enum HomeCatalogKind: Int {
    case streaming, trending, latest
}

/// Jellyfin exposes installed catalogs as user views. AIOMetadata supplies their names and types.
func homeCatalogKind(_ view: Item) -> HomeCatalogKind? {
    guard isBrowsable(view) else { return nil }
    let name = view.name?.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) ?? ""
    let words = name.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    let normalized = words.joined(separator: " ")
    if normalized.contains("streaming services") { return .streaming }
    guard view.collectionType != "boxsets" else { return nil }
    if words.contains("trending") { return .trending }
    if words.contains("latest") || ["new releases", "newly released", "recent releases", "recently added",
                                   "new movies", "new shows", "new tv shows", "new series", "now playing"]
        .contains(where: { normalized.contains($0) }) {
        return .latest
    }
    return nil
}

struct HomeView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @State private var hero: [Item] = []
    @State private var catalogs: [HomeRow] = []
    @State private var loaded = false
    @State private var loading = false
    @State private var error: String?
    @State private var choice: VersionChoice?
    @State private var followed: Item?

    private var following: Bool { prefs.heroMode != "rotate" }

    var body: some View {
        Group {
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if following && !hero.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HeroCarousel(items: hero, play: play, followed: followed ?? hero.first,
                                 height: prefs.heroMode == "corner" ? Theme.px(360) : Theme.px(456))
                    ScrollView { rows }.edgeToEdge()
                }
            } else {
                ScrollView { rows }.edgeToEdge()
            }
        }
        .environment(\.cardFocused, { item in
            if following && (item.type == "Movie" || item.isSeries) { followed = item }
        })
        .task(id: prefs.loaded) { if prefs.loaded && !loaded { await load() } }
        .onChange(of: prefs.featured) { _, _ in updateHero() }
        .refreshOnReturn { await load() }
        .reloadOnWatchChange { await load() }
        .playFlow($choice) { Task { await load() } }
    }

    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: Theme.px(40)) {
            if !hero.isEmpty && !following {
                HeroCarousel(items: hero, play: play).padding(.bottom, -Theme.px(32))
            } else {
                Color.clear.frame(height: Theme.px(16))
            }
            ForEach(catalogs) { row in
                ItemRow(row: row)
            }
            if catalogs.isEmpty {
                VStack(spacing: Theme.px(16)) {
                    if loading {
                        ProgressView()
                    } else {
                        Text(error ?? L("No Streaming Services, Trending or Latest catalogs are available on this server."))
                            .foregroundStyle(Theme.gray400)
                        Button(L("Try again")) { Task { await load() } }.buttonStyle(SoftPillStyle())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.px(200))
            }
        }
        .padding(.bottom, Theme.px(64))
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
            // Top Shelf on the Apple TV system home screen continues to offer playback shortcuts.
            async let resume: ItemsResult? = try? client.get("/UserItems/Resume", ["userId": userId, "Limit": "24", "MediaTypes": "Video"])
            async let nextUp: ItemsResult? = try? client.get("/Shows/NextUp", ["userId": userId, "Limit": "24", "EnableResumable": "false"])
            let result: ItemsResult = try await client.get("/UserViews", ["userId": userId])
            var views = (result.items ?? []).compactMap { view in homeCatalogKind(view).map { (view, $0) } }
            let stock = session.isStock

            if stock && !views.contains(where: { $0.1 == .streaming }) {
                let boxSets: ItemsResult? = try? await client.get("/Items", [
                    "userId": userId, "IncludeItemTypes": "BoxSet", "Recursive": "true",
                    "SearchTerm": "Streaming Services", "Limit": "24",
                ])
                if let view = boxSets?.items?.first(where: { homeCatalogKind($0) == .streaming }) {
                    views.append((view, .streaming))
                }
            }
            let ordered = views.enumerated().sorted {
                $0.element.1 == $1.element.1 ? $0.offset < $1.offset : $0.element.1.rawValue < $1.element.1.rawValue
            }.map(\.element)
            let previous = catalogs
            let rows = await withTaskGroup(of: (Int, HomeRow?).self) { group in
                for (index, entry) in ordered.enumerated() {
                    let (view, kind) = entry
                    group.addTask {
                        let streaming = kind == .streaming
                        let genre = await openingGenre(client, userId: userId, view: view)
                        let page: ItemsResult? = try? await client.get("/Items", [
                            "userId": userId, "ParentId": view.id,
                            "IncludeItemTypes": streaming ? "BoxSet" : libraryTypes(view),
                            "GenreIds": genre, "Recursive": streaming ? "false" : "true",
                            "Limit": "24", "Fields": "Overview,Genres",
                        ])
                        guard let page else { return (index, previous.first { $0.id == view.id }) }
                        let titles = (page.items ?? []).filter { item in
                            streaming ? item.type == "BoxSet" : item.type == "Movie" || item.isSeries
                        }
                        guard !titles.isEmpty else { return (index, nil) }
                        return (index, HomeRow(id: view.id, title: view.name ?? L("Library"), items: titles,
                                               library: view, wide: streaming, collection: streaming))
                    }
                }
                if stock {
                    for (index, type) in ["Movie", "Series"].enumerated() {
                        guard !ordered.contains(where: { $0.1 == .latest && libraryTypes($0.0).split(separator: ",").contains(Substring(type)) }) else { continue }
                        group.addTask {
                            let id = "latest.\(type)"
                            let offset = ordered.count + index
                            let page: ItemsResult? = try? await client.get("/Items", [
                                "userId": userId, "IncludeItemTypes": type, "Recursive": "true",
                                "SortBy": "DateCreated", "SortOrder": "Descending",
                                "Limit": "24", "Fields": "Overview,Genres",
                            ])
                            guard let page else { return (offset, previous.first { $0.id == id }) }
                            let titles = (page.items ?? []).filter { $0.type == type }
                            guard !titles.isEmpty else { return (offset, nil) }
                            return (offset, HomeRow(id: id, title: type == "Movie" ? L("Latest movies") : L("Latest shows"), items: titles))
                        }
                    }
                }
                var result: [Int: HomeRow] = [:]
                for await (index, row) in group { result[index] = row }
                return result.keys.sorted().compactMap { result[$0] }
            }
            guard !Task.isCancelled, profile == session.profileID else { return }
            if catalogs.count != rows.count || !zip(catalogs, rows).allSatisfy({ old, new in
                old.id == new.id && old.title == new.title && old.items == new.items
            }) {
                catalogs = rows
            }
            updateHero()
            loaded = true

            let (resuming, next) = await (resume, nextUp)
            if !Task.isCancelled, profile == session.profileID, resuming != nil || next != nil {
                saveTopShelf(client: client, resume: resuming?.items ?? [], nextUp: next?.items ?? [])
            }
        } catch let failure as JellyfinError where failure.status == 401 {
            if !Task.isCancelled { session.expired(client) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func updateHero() {
        guard let client = session.client else { return }
        let picks = heroPicks(client: client)
        if hero != picks { hero = picks }
        if let followed, !catalogs.contains(where: { $0.items.contains(where: { $0.id == followed.id }) }) {
            self.followed = nil
        }
    }

    /// Continue watching and Next up for Top Shelf on the system home screen.
    private func saveTopShelf(client: JellyfinClient, resume: [Item], nextUp: [Item]) {
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

    private func heroPicks(client: JellyfinClient) -> [Item] {
        let rows = catalogs.filter { !$0.collection }
        let chosen = prefs.featured
        if chosen?.isEmpty == true { return [] }
        let selected = (chosen ?? []).compactMap { key in rows.first { "view:\($0.id)" == key } }
        let sources = (selected.isEmpty ? rows : selected).map(\.items)
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

    /// The large image runs behind the rail while the controls stay within the page.
    private var backdrop: some View {
        GeometryReader { geometry in
            let inset = Theme.railInset
            HeroArtwork(url: session.client?.backdrop(item, height: 1080))
                .overlay {
                    ZStack {
                        LinearGradient(colors: [.black.opacity(0.75), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                        LinearGradient(colors: [Theme.background, .black.opacity(0.08), .clear],
                                       startPoint: .bottom, endPoint: .center)
                    }
                }
                .frame(width: geometry.size.width + inset, height: geometry.size.height)
                .offset(x: -inset)
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
                        Color.clear
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .overlay(alignment: .top) {
                                Image(uiImage: image).resizable().scaledToFit()
                                    .frame(width: geometry.size.width,
                                           height: geometry.size.width * image.size.height / max(1, image.size.width))
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
