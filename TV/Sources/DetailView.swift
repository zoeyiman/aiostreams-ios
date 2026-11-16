import SwiftUI
import UIKit

// The web app's title page (pages/item.tsx) as a TV shows it: the backdrop over the top,
// the poster beside the title's logo, facts, genres and overview, its actions, then the
// seasons as pills over a row of episodes, the cast, and titles like it.

struct DetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    let item: Item
    /// The trailer playing, or being found.
    @State private var trailer: PlayRequest?
    @State private var findingTrailer = false
    @State private var trailerFailed = false

    @State private var full: Item?
    @State private var seasons: [Item] = []
    @State private var season: Item?
    @State private var episodes: [Item] = []
    @State private var nextUp: Item?
    @State private var similar: [Item] = []
    @State private var choice: VersionChoice?
    @State private var pickingEpisode = false
    @State private var randomChoice: VersionChoice?
    @FocusState private var playFocused: Bool

    private var shown: Item { full ?? item }

    /// What Play plays: the title, or a show's next episode.
    private var target: Item? { shown.isSeries ? nextUp : (shown.playable ? shown : nil) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ItemBackdrop(item: shown, overArtwork: prefs.flag("artBackground", false))
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.px(48)) {
                    header
                    if shown.isSeries { seasonsSection }
                    castSection
                    if !similar.isEmpty {
                        ItemRow(row: HomeRow(id: "similar", title: L("More like this"), items: similar))
                            .padding(.leading, Theme.px(12))
                    }
                }
                // 26% down a 720-line screen.
                .padding(.top, Theme.px(187))
                .padding(.bottom, Theme.px(64))
            }
            .scrollClipDisabled(false)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.backward")
                    .font(Theme.font(Theme.sm, .semibold))
                    .frame(width: Theme.px(38), height: Theme.px(36))
            }
            .buttonStyle(RowBrowseArrowStyle())
            .accessibilityLabel(L("Back"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .pagePadding()
            .padding(.vertical, Theme.px(5))
            .background(Theme.background.opacity(0.96))
        }
        .onExitCommand { dismiss() }
        .task { await load() }
        // Find versions when a title opens: what Play would play, looked for straight away.
        .task(id: target?.id) {
            guard prefs.flag("preloadVersions", false), let target, !target.isChannel,
                  let client = session.client, let userId = session.userId else { return }
            VersionSearches.start(target.id, client: client, userId: userId)
        }
        .reloadOnWatchChange { await load() }
        .playFlow($choice) { Task { await load() } }
        .fullScreenCover(isPresented: $pickingEpisode, onDismiss: {
            choice = randomChoice
            randomChoice = nil
        }) {
            RandomEpisodePicker(series: shown) { episode in
                randomChoice = VersionChoice(item: episode, startMs: episode.resumeMs, mode: .list)
                pickingEpisode = false
            }
            .environmentObject(session)
            .environmentObject(prefs)
        }
        .fullScreenCover(item: $trailer) { request in
            PlayerScreen(request: request, close: { trailer = nil })
                .environmentObject(session)
                .environmentObject(prefs)
        }
        .alert(L("This trailer didn't load."), isPresented: $trailerFailed) {
            Button(L("OK"), role: .cancel) {}
        }
        .onAppear { playFocused = true }
        // Background from artwork: this title's.
        .washed(by: shown)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: Theme.px(32)) {
            RemoteImage(url: session.client?.poster(shown, height: 516))
                .frame(width: Theme.px(172), height: Theme.px(258))
                .clipShape(RoundedRectangle(cornerRadius: Theme.px(12), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.px(12), style: .continuous).stroke(.white.opacity(0.1), lineWidth: Theme.px(1)))
                .shadow(color: .black.opacity(0.6), radius: Theme.px(24), y: Theme.px(12))
            VStack(alignment: .leading, spacing: Theme.px(16)) {
                TitleLogo(item: shown, maxHeight: Theme.px(128), maxWidth: Theme.px(416), titleSize: 48)
                if let tagline = shown.taglines?.first, !tagline.isEmpty {
                    Text(tagline).font(Theme.font(Theme.base)).italic().foregroundStyle(Theme.gray300)
                }
                facts
                if let genres = shown.genres, !genres.isEmpty {
                    HStack(spacing: Theme.px(6)) {
                        ForEach(genres.prefix(6), id: \.self) { genre in
                            Text(genre)
                                .font(Theme.font(13, .semibold))
                                .padding(.horizontal, Theme.px(10))
                                .padding(.vertical, Theme.px(3))
                                .background(Capsule().fill(.white.opacity(0.1)))
                                .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: Theme.px(1)))
                        }
                    }
                }
                if let overview = shown.overview, !overview.isEmpty {
                    Text(overview)
                        .font(Theme.font(Theme.base))
                        .lineSpacing(Theme.px(5))
                        .foregroundStyle(Theme.gray300)
                        .lineLimit(4)
                }
                actions
            }
            .frame(maxWidth: Theme.px(768), alignment: .leading)
        }
        .pagePadding()
    }

    /// `2024 • PG-13 • 2h 47m • ★ 8.4`, the rating boxed.
    private var facts: some View {
        var parts: [AnyView] = []
        if let year = shown.productionYear { parts.append(AnyView(Text(String(year)))) }
        if let rating = shown.officialRating, !rating.isEmpty {
            parts.append(AnyView(
                Text(rating)
                    .font(Theme.font(Theme.xs))
                    .padding(.horizontal, Theme.px(6))
                    .padding(.vertical, Theme.px(1))
                    .overlay(RoundedRectangle(cornerRadius: Theme.px(4)).stroke(.white.opacity(0.3), lineWidth: Theme.px(1)))
            ))
        }
        if !shown.isSeries, let runtime = shown.runtimeText { parts.append(AnyView(Text(runtime))) }
        if shown.isSeries, let status = shown.status, status == "Continuing" || status == "Ended" {
            parts.append(AnyView(Text(status == "Ended" ? L("Ended") : L("Continuing"))))
        }
        if let score = shown.communityRating, score > 0 {
            parts.append(AnyView(HStack(spacing: Theme.px(4)) {
                Image(systemName: "star.fill").foregroundStyle(Theme.star).font(.system(size: Theme.px(12)))
                Text(String(format: "%.1f", score))
            }))
        }
        return MetaLine(parts: parts)
            .font(Theme.font(Theme.sm))
            .foregroundStyle(Theme.gray200)
    }

    /// The web app's labels: `Resume S01E04`, `Resume from 1:35:11`, `Play S01E01`, `Play`.
    private var playLabel: String {
        let code = shown.isSeries ? target?.episodeCode : nil
        if let resume = target?.resumeMs {
            return code.map { L("Resume %@", "\($0)") } ?? L("Resume from %@", "\(clock(resume))")
        }
        return code.map { L("Play %@", "\($0)") } ?? L("Play")
    }

    private var actions: some View {
        HStack(spacing: Theme.px(8)) {
            if let target {
                Button {
                    choice = VersionChoice(item: target, startMs: target.resumeMs, mode: target.isEpisode ? .list : .usual)
                } label: {
                    Label(playLabel, systemImage: "play.fill")
                }
                .buttonStyle(PrimaryPillStyle())
                .focused($playFocused)
            }
            Button {
                Task { await setFavourite(!(shown.userData?.isFavorite ?? false)) }
            } label: {
                Image(systemName: shown.userData?.isFavorite == true ? "heart.fill" : "heart")
            }
            .buttonStyle(CircleIconStyle(active: shown.userData?.isFavorite == true))
            if shown.isSeries || shown.type == "Movie" {
                let dropped = shown.userData?.likes == false
                Button {
                    Task { await setDropped(!dropped) }
                } label: {
                    Image(systemName: dropped ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                }
                .buttonStyle(CircleIconStyle())
                .accessibilityLabel(shown.isSeries
                    ? (dropped ? L("Undrop show") : L("Drop show"))
                    : (dropped ? L("Remove dislike") : L("Dislike movie")))
            }
            if let target, target.resumeMs != nil {
                Button {
                    choice = VersionChoice(item: target, startMs: 0, mode: target.isEpisode ? .list : .usual)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(CircleIconStyle())
            }
            if shown.isSeries {
                Button { pickingEpisode = true } label: { Image(systemName: "shuffle") }
                    .buttonStyle(CircleIconStyle())
                    .accessibilityLabel(L("Random episode"))
            }
            if shown.remoteTrailers?.contains(where: { $0.url != nil }) == true {
                Button {
                    Task { await playTrailer() }
                } label: {
                    if findingTrailer { ProgressView() } else { Image(systemName: "film") }
                }
                .buttonStyle(CircleIconStyle())
                .disabled(findingTrailer)
            }
            Button {
                Task { await setPlayed(!(shown.userData?.played ?? false)) }
            } label: {
                Image(systemName: "checkmark")
            }
            .buttonStyle(CircleIconStyle(active: shown.userData?.played == true))
        }
        .focusSection()
    }

    // MARK: Seasons and episodes

    @ViewBuilder private var seasonsSection: some View {
        VStack(alignment: .leading, spacing: Theme.px(16)) {
            if seasons.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: Theme.px(8)) {
                        ForEach(seasons) { candidate in
                            Button(candidate.name ?? L("Season")) {
                                season = candidate
                                Task { await loadEpisodes() }
                            }
                            .buttonStyle(SeasonPillStyle(selected: candidate.id == season?.id))
                        }
                    }
                    .pagePadding()
                    .padding(.vertical, Theme.px(12))
                }
                .scrollClipDisabled(false)
                .focusSection()
            } else if let only = seasons.first {
                Text(only.name ?? L("Episodes")).font(Theme.font(Theme.xl, .semibold)).pagePadding()
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Theme.px(16)) {
                    ForEach(episodes) { episode in
                        EpisodeCard(episode: episode) {
                            choice = VersionChoice(item: episode, startMs: episode.resumeMs, mode: .list)
                        }
                    }
                }
                .pagePadding()
                .padding(.vertical, Theme.px(8))
            }
            .edgeToEdge()
            .focusSection()
        }
    }

    // MARK: Cast

    @ViewBuilder private var castSection: some View {
        let cast = (shown.people ?? []).filter { person in
            let role = person.type?.lowercased()
            return role == nil || role == "actor" || role == "gueststar" || role == "guest star"
        }
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: Theme.px(16)) {
                Text(L("Cast")).font(Theme.font(Theme.xl, .semibold)).pagePadding()
                    .padding(.top, Theme.px(12))
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Theme.px(16)) {
                        ForEach(cast) { person in
                            PersonCard(person: person, url: personImage(person))
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

    private func personImage(_ person: Person) -> URL? {
        guard let client = session.client, let tag = person.primaryImageTag else { return nil }
        return client.image(person.id, .primary, tag: tag, width: 240)
    }

    // MARK: Trailer

    /// Plays the title's first trailer: a YouTube one through the stream the app finds, as the web
    /// app's players do, any other by its address.
    private func playTrailer() async {
        guard !findingTrailer, let trailers = shown.remoteTrailers else { return }
        findingTrailer = true
        defer { findingTrailer = false }
        var found: (url: String, language: String?)?
        for candidate in trailers {
            if let id = candidate.youTubeId {
                let stream: YouTube.Stream? = await withCheckedContinuation { done in
                    YouTube.resolve(id) { done.resume(returning: $0) }
                }
                if let stream { found = (stream.url, stream.originalLanguage) }
            } else if let url = candidate.url, url.lowercased().hasPrefix("http") {
                found = (url, nil)
            }
            if found != nil { break }
        }
        guard let found else {
            trailerFailed = true
            return
        }
        // The account's audio languages, with Original meaning the trailer's own.
        let chosen = prefs.languages(list: "AudioLanguages", one: "AudioLanguagePreference")
        var languages = chosen.compactMap { $0 == "OriginalLanguage" ? found.language : $0 }
        if languages.isEmpty, let original = found.language { languages = [original] }
        trailer = PlayRequest(
            item: shown,
            source: MediaSource(id: "trailer", name: L("Trailer"), path: found.url),
            playSessionId: nil,
            startMs: nil,
            isTrailer: true,
            audioLanguages: languages
        )
    }

    // MARK: Loading

    private func load() async {
        guard let client = session.client, let userId = session.userId else { return }
        let fields = "Genres,Overview,People,Taglines,Status,RemoteTrailers,ProviderIds"
        if let detail: Item = try? await client.get("/Items/\(item.id)", ["userId": userId, "Fields": fields]) {
            full = detail
        } else {
            let found: ItemsResult? = try? await client.get("/Items", [
                "userId": userId, "Ids": item.id, "Fields": fields,
            ])
            if let first = found?.items?.first { full = first }
        }
        let similarResult: ItemsResult? = try? await client.get("/Items/\(item.id)/Similar", ["userId": userId, "Limit": "12"])
        similar = similarResult?.items ?? []
        guard shown.isSeries else { return }
        let next: ItemsResult? = try? await client.get("/Shows/NextUp", ["userId": userId, "SeriesId": item.id, "Limit": "1"])
        nextUp = next?.items?.first
        let list: ItemsResult? = try? await client.get("/Shows/\(item.id)/Seasons", ["userId": userId])
        seasons = list?.items ?? []
        // Opens on the next episode's season, else the first with something left, as the web app does.
        if season == nil || !seasons.contains(where: { $0.id == season?.id }) {
            season = seasons.first { $0.id == nextUp?.seasonId }
                ?? seasons.first { $0.userData?.played != true && ($0.indexNumber ?? 0) > 0 }
                ?? seasons.first
        }
        await loadEpisodes()
        if nextUp == nil { nextUp = episodes.first { $0.playable } }
    }

    private func loadEpisodes() async {
        guard let client = session.client, let userId = session.userId, let season else { return }
        let list: ItemsResult? = try? await client.get("/Shows/\(item.id)/Episodes", [
            "userId": userId,
            "SeasonId": season.id,
            "Fields": "Overview",
        ])
        episodes = list?.items ?? []
    }

    private func setDropped(_ dropped: Bool) async {
        guard let client = session.client, let userId = session.userId else { return }
        do {
            try await client.call("POST", "/UserItems/\(shown.id)/Rating",
                                  ["userId": userId, "Likes": dropped ? "false" : "true"])
            NotificationCenter.default.post(name: .watchStateChanged, object: nil)
        } catch {
            AppLog.warn("details", error.localizedDescription)
        }
    }

    private func setPlayed(_ played: Bool) async {
        guard let client = session.client, let userId = session.userId else { return }
        try? await client.call(played ? "POST" : "DELETE", "/UserPlayedItems/\(shown.id)", ["userId": userId])
        await load()
    }

    private func setFavourite(_ favourite: Bool) async {
        guard let client = session.client, let userId = session.userId else { return }
        try? await client.call(favourite ? "POST" : "DELETE", "/UserFavoriteItems/\(shown.id)", ["userId": userId])
        await load()
    }

    private func clock(_ ms: Double) -> String {
        let seconds = Int(ms / 1000)
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The title's backdrop over the top 85% of the screen, under the rail, shaded into the page.
struct ItemBackdrop: View {
    @EnvironmentObject private var session: Session
    let item: Item
    /// Over the background from artwork: the art fades out into it, rather than into the page's
    /// colour, which would cover the blurred art beneath (as the web app's `data-art-wash` does).
    var overArtwork = false

    private static var height: CGFloat { Theme.px(612) + Theme.topBarInset }

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width + Theme.railInset, Self.height * 2.6)
            ZStack(alignment: .bottom) {
                RemoteImage(url: session.client?.backdrop(item, height: 1080))
                    .frame(width: width, height: Self.height)
                    .mask(
                        LinearGradient(
                            stops: [.init(color: .clear, location: 0), .init(color: .black, location: Theme.px(192) / width)],
                            startPoint: .start,
                            endPoint: .end
                        )
                    )
                    // Over the artwork, it fades out downwards and towards the details too.
                    .mask(
                        LinearGradient(
                            stops: overArtwork
                                ? [.init(color: .clear, location: 0), .init(color: .black, location: 0.5)]
                                : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .mask(
                        LinearGradient(
                            stops: overArtwork
                                ? [.init(color: .clear, location: 0), .init(color: .black, location: 0.5)]
                                : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
                            startPoint: .start,
                            endPoint: .end
                        )
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                if !overArtwork {
                LinearGradient(
                    stops: [
                        .init(color: Theme.background, location: 0),
                        .init(color: Theme.background.opacity(0.6), location: 0.4),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .start,
                    endPoint: .end
                )
                LinearGradient(
                    stops: [
                        .init(color: Theme.background, location: 0),
                        .init(color: Theme.background.opacity(0.7), location: 0.5),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(height: Self.height * 3 / 4)
                }
            }
            .frame(height: Self.height)
        }
        .frame(height: Self.height)
        .padding(.leading, -Theme.railInset)
        // Up under the top bar too, where there is one.
        .padding(.top, -Theme.topBarInset)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// A season's pill: white when chosen, as the web app's season pills are.
struct SeasonPillStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        SeasonPill(label: configuration.label, selected: selected, pressed: configuration.isPressed)
    }

    private struct SeasonPill<Label: View>: View {
        @Environment(\.isFocused) private var focused
        let label: Label
        let selected: Bool
        let pressed: Bool

        var body: some View {
            label
                .font(Theme.font(Theme.sm, .medium))
                .foregroundStyle(selected ? Color.black : (focused ? Color.white : Theme.gray200))
                .padding(.horizontal, Theme.px(14))
                .frame(height: Theme.px(34))
                .background(Capsule().fill(selected ? Color.white : (focused ? Color.white.opacity(0.16) : Theme.gray800)))
                .focusRing(focused)
                .opacity(pressed ? 0.8 : 1)
        }
    }
}

/// An episode in the row: its still with how far it got, its number and name, length and score,
/// and its synopsis.
struct EpisodeCard: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @FocusState private var focused: Bool
    let episode: Item
    let action: () -> Void

    /// Spoiler blur: an episode not started, until it has focus.
    private var hidden: Bool { prefs.blurSpoilers && episode.unstarted && !focused }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(8)) {
            Button(action: action) {
                ZStack(alignment: .bottom) {
                    RemoteImage(url: session.client?.poster(episode, height: Int(WideCard.size.height * 2)))
                        .frame(width: WideCard.size.width, height: WideCard.size.height)
                        .blur(radius: hidden ? Theme.px(12) : 0, opaque: true)
                        .animation(.easeOut(duration: 0.3), value: hidden)
                    if let progress = episode.userData?.playedPercentage, progress > 0, episode.userData?.played != true {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.white.opacity(0.25))
                                Rectangle().fill(Theme.brand500).frame(width: geometry.size.width * progress / 100)
                            }
                        }
                        .frame(height: Theme.px(4))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if episode.userData?.played == true {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: Theme.px(18)))
                            .foregroundStyle(.white, Theme.brand500)
                            .padding(Theme.px(8))
                    }
                }
                .frame(width: WideCard.size.width, height: WideCard.size.height)
                .clipShape(RoundedRectangle(cornerRadius: Theme.px(12), style: .continuous))
            }
            .buttonStyle(CardStyle(radius: Theme.px(12)))
            .focused($focused)
            .itemMenu(episode, onPage: true)
            VStack(alignment: .leading, spacing: Theme.px(3)) {
                Text([episode.indexNumber.map { "\($0)." }, episode.name].compactMap { $0 }.joined(separator: " "))
                    .font(Theme.font(15, .semibold))
                    .lineLimit(1)
                    .blur(radius: hidden ? Theme.px(5) : 0)
                    .animation(.easeOut(duration: 0.3), value: hidden)
                HStack(spacing: Theme.px(8)) {
                    if let runtime = episode.runtimeText { Text(runtime) }
                    if let score = episode.communityRating, score > 0 {
                        HStack(spacing: Theme.px(3)) {
                            Image(systemName: "star.fill").foregroundStyle(Theme.star).font(.system(size: Theme.px(10)))
                            Text(String(format: "%.1f", score))
                        }
                    }
                    if let left = episode.timeLeft { Text(left) }
                }
                .font(Theme.font(Theme.xs))
                .foregroundStyle(Theme.gray400)
                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview)
                        .font(Theme.font(13))
                        .foregroundStyle(Theme.gray400)
                        .lineLimit(3)
                        .blur(radius: hidden ? Theme.px(5) : 0)
                        .animation(.easeOut(duration: 0.3), value: hidden)
                }
            }
            .padding(.horizontal, Theme.px(2))
            .frame(width: WideCard.size.width, alignment: .leading)
        }
    }
}

/// A cast member: a round picture, their name and role.
struct PersonCard: View {
    @Environment(\.openRoute) private var openRoute
    @EnvironmentObject private var session: Session
    @State private var portrait: UIImage?
    let person: Person
    let url: URL?

    var body: some View {
        VStack(spacing: Theme.px(8)) {
            Button { openRoute(.person(person)) } label: {
                ZStack {
                    Circle().fill(Theme.gray900)
                    Text(initials).font(Theme.font(Theme.lg, .semibold)).foregroundStyle(Theme.gray400)
                    if let portrait {
                        Image(uiImage: portrait).resizable().aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: Theme.px(96), height: Theme.px(96))
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: Theme.px(1)))
            }
            .buttonStyle(CircleCardStyle())
            Text(person.name ?? "")
                .font(Theme.font(Theme.xs, .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let role = person.role, !role.isEmpty {
                Text(role)
                    .font(Theme.font(Theme.xs))
                    .foregroundStyle(Theme.gray400)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: Theme.px(112))
        .task(id: url) { await loadPortrait() }
    }

    private func loadPortrait() async {
        portrait = nil
        if let url, let image = await downloadPortrait(url) {
            portrait = image
            return
        }
        guard !Task.isCancelled, let client = session.client, let userId = session.userId else { return }
        // The person route resolves provider metadata and registers the primary image on AIOMetadata.
        let profile: Item? = try? await client.get("/Items/\(person.id)", ["userId": userId])
        guard !Task.isCancelled, let tag = profile?.tag("Primary") else { return }
        let address = client.image(person.id, .primary, tag: tag, width: 240)
        portrait = await downloadPortrait(address)
    }

    private func downloadPortrait(_ url: URL) async -> UIImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return UIImage(data: data)
    }

    private var initials: String {
        (person.name ?? "").split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}

/// A round picture's ring, round the circle.
struct CircleCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Ringed(label: configuration.label)
    }

    private struct Ringed<Label: View>: View {
        @Environment(\.isFocused) private var focused
        let label: Label

        var body: some View {
            label.brightness(focused ? 0.10 : 0)
                .scaleEffect(focused ? 1.035 : 1)
        }
    }
}


/// Like the desktop picker, keeps one pool per opening and excludes the previous pick when possible.
struct RandomEpisodePicker: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @Environment(\.dismiss) private var dismiss
    @State private var episodes: [Item]?
    @State private var episode: Item?
    @State private var failed = false
    @State private var loading = false
    @FocusState private var playFocused: Bool
    let series: Item
    let play: (Item) -> Void

    var body: some View {
        VStack(spacing: Theme.px(16)) {
            Text(L("Random episode")).font(Theme.font(Theme.xl, .semibold))
            if let episode {
                RemoteImage(url: session.client?.still(episode, height: 540))
                    .frame(width: Theme.px(448), height: Theme.px(252))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.px(12)))
                Text(episode.displayTitle).font(Theme.font(Theme.lg, .semibold))
                HStack(spacing: Theme.px(12)) {
                    Button(episode.resumeMs == nil ? L("Play") : L("Resume")) { play(episode) }
                        .buttonStyle(PrimaryPillStyle())
                        .focused($playFocused)
                    if (episodes?.count ?? 0) > 1 {
                        Button(L("Roll again")) { roll() }.buttonStyle(SoftPillStyle())
                    }
                }
            } else if failed {
                Text(L("Could not pick an episode."))
                Button(L("Try again")) { Task { await load() } }.buttonStyle(SoftPillStyle())
            } else if episodes?.isEmpty == true {
                Text(L("This show has no episodes to pick from yet."))
            } else {
                ProgressView()
            }
            Button(L("Back")) { dismiss() }.buttonStyle(SoftPillStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await load() }
        .onChange(of: episode?.id) { previous, _ in
            if previous == nil { playFocused = true }
        }
        .onExitCommand { dismiss() }
    }

    private func load() async {
        guard !loading, let client = session.client, let userId = session.userId else { return }
        loading = true
        failed = false
        defer { loading = false }
        do {
            let result: ItemsResult = try await client.get("/Shows/\(series.id)/Episodes", ["userId": userId])
            guard !Task.isCancelled else { return }
            let now = Date()
            episodes = (result.items ?? []).filter { candidate in
                let future = parseDate(candidate.premiereDate).map { $0 > now } ?? false
                return candidate.isEpisode && candidate.playable && candidate.parentIndexNumber != 0
                    && (!prefs.markUnaired || !future)
            }
            roll()
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }

    private func roll() {
        guard let episodes else { return }
        episode = episodes.filter { $0.id != episode?.id }.randomElement() ?? episodes.first
    }
}
