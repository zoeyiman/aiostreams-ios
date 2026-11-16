import AetherEngineFeatures
import Combine
import SwiftUI

// The web app's player as a TV shows it: the title over the top, a purple progress bar with
// chapter marks, and a row of controls, which hide while the video plays. Hidden, the remote
// drives playback itself; shown, its buttons and the bar take focus.

struct PlayerScreen: View {
    let request: PlayRequest
    /// A player opened again from Picture in Picture, which carries on as it was.
    var existing: PlayerModel?
    let close: () -> Void
    /// Lists an episode's versions, for one whose next episode has none that carries on.
    var listVersions: (Item) -> Void = { _ in }

    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @State private var model: PlayerModel?
    /// The episode a version is being found for, to play on in.
    @State private var finding: Item?
    @State private var changingChannel = false
    @State private var switchingEpisode: Item?
    @State private var recentLive: [Item] = []
    @State private var closing = false

    var body: some View {
        Group {
            if let model {
                PlayerChrome(model: model, close: finish, playNext: { next in Task { await playOn(next, showArtwork: next.isEpisode) } }, finding: finding,
                             recentLive: recentLive, tuneRecent: { channel in Task { await playChannel(channel) } },
                             pickEpisode: { next in Task { await playOn(next, showArtwork: true) } },
                             leave: close, changeChannel: { step in Task { await changeChannel(step) } },
                             switchVersion: { source in Task { await switchVersion(to: source) } },
                             chooseAnotherVersion: {
                                 listVersions(model.request.item)
                                 finish()
                             })
                    // A new title starts the controls over.
                    .id(model.request.id)
                    .onReceive(Publishers.CombineLatest3(model.$started, model.$waiting, model.$failure)) { started, waiting, failure in
                        if switchingEpisode?.id == model.request.item.id, (started && !waiting) || failure != nil {
                            switchingEpisode = nil
                        }
                    }
                    .onReceive(model.$started.removeDuplicates()) { started in
                        guard started else { return }
                        let item = model.request.item
                        if let channelID = item.isChannel ? item.id : item.channelId {
                            RecentChannels.note(channelID, for: session.profileID)
                            if item.isChannel { Task { await loadRecentLive() } }
                        }
                    }
            } else {
                Color.black
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            if let switchingEpisode {
                EpisodeLoadingView(item: switchingEpisode)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            } else if let finding {
                VStack(spacing: Theme.px(8)) {
                    Text(L("Finding a version of %@…", "\(finding.displayTitle)")).font(Theme.font(Theme.base, .medium))
                    ProgressView().progressViewStyle(.linear).frame(width: Theme.px(220))
                }
                .padding(.horizontal, Theme.px(20))
                .padding(.vertical, Theme.px(12))
                .background(Capsule().fill(Color(white: 17 / 255).opacity(0.95)))
                .padding(.bottom, Theme.px(40))
            }
        }
        // The party stopped this title, or moved on: its player closes.
        .onReceive(PartyFollow.shared.$bound) { bound in
            if let entry = model?.request.partyEntry, bound != entry {
                model?.stop()
                close()
            }
        }
        .task {
            guard model == nil else { return }
            if let existing {
                model = existing
                TVPictureInPicture.shared.restored()
            } else {
                await start(request)
            }
        }
    }

    private func start(_ request: PlayRequest) async {
        guard let client = session.client else { return }
        let profile = session.profileID
        // A title in Picture in Picture gives way to this one.
        TVPictureInPicture.shared.stop()
        // The show's pick, as the web app keeps it, over the account's rules.
        if let userId = session.userId { await ShowPicks.shared.load(client: client, userId: userId) }
        guard !Task.isCancelled, session.profileID == profile else { return }
        let base = prefs.trackRules(audioLanguages: request.audioLanguages)
        let tracks = request.isTrailer ? base
            : ShowPicks.shared.rules(base, for: request.item, rememberAudio: prefs.rememberAudio, rememberSubtitles: prefs.rememberSubtitles)
        let player = PlayerModel(
            request: request,
            client: client,
            tracks: tracks,
            baseTracks: base,
            remember: (prefs.rememberAudio, prefs.rememberSubtitles),
            audioShaping: prefs.audioShaping,
            audioDelay: Double(prefs.audioDelayMs) / 1000,
            liveDisplay: (prefs.liveMatchFrameRate, prefs.liveMatchDynamicRange),
            look: prefs.subtitleLook,
            speakers: prefs.speakers,
            animeUpscaling: prefs.animeUpscaling,
            userId: session.userId,
            rules: prefs.playerRules
        )
        player.scrubPreviews = prefs.seekPreviews
        model = player
        player.start()
    }

    /// Plays the next episode here, in the version that carries on from this one: the same binge
    /// group, else the only or first one where allowed. Without one, its versions are listed.
    private func playOn(_ next: Item, showArtwork: Bool = false) async {
        guard finding == nil, let current = model, let client = session.client, let userId = session.userId else { return }
        finding = next
        if showArtwork { switchingEpisode = next }
        defer {
            finding = nil
            if model?.request.item.id != next.id { switchingEpisode = nil }
        }
        let info = try? await client.playbackInfo(userId: userId, itemId: next.id)
        let sources = (info?.mediaSources ?? []).filter { $0.aiostreams?.ytId == nil }
        let group = current.request.source.aiostreams?.bingeGroup
        let carried = group.flatMap { group in sources.first { $0.aiostreams?.bingeGroup == group } }
            ?? (sources.count == 1 || prefs.nextFallbackFirst ? sources.first : nil)
        guard let source = carried else {
            listVersions(next)
            finish()
            return
        }
        // Named again, the version brings its subtitles from the configuration's subtitle addons.
        var chosen = source
        var playSession = info?.playSessionId
        if let named = try? await client.playbackInfo(userId: userId, itemId: next.id, sourceId: source.ownId),
           let match = named.mediaSources?.first(where: { $0.ownId == source.ownId }) ?? named.mediaSources?.first {
            chosen = match
            playSession = named.playSessionId ?? playSession
        }
        LastVersions.set(next.id, chosen)
        current.stop()
        let startMs = next.userData?.played == true ? nil : next.resumeMs
        // From a playlist, the rest of it carries on after.
        let rest = Array(current.request.queue.drop { $0.id != next.id }.dropFirst())
        await start(PlayRequest(item: next, source: chosen, playSessionId: playSession, startMs: startMs, queue: rest))
    }

    private func switchVersion(to source: MediaSource) async {
        guard !closing, finding == nil, let current = model, let client = session.client,
              let userId = session.userId else { return }
        let item = current.request.item
        finding = item
        defer { finding = nil }
        let info = try? await client.playbackInfo(userId: userId, itemId: item.id, sourceId: source.ownId)
        guard !closing, model === current else { return }
        let chosen = info?.mediaSources?.first(where: { $0.ownId == source.ownId }) ?? source
        let position = current.position * 1000
        LastVersions.set(item.id, chosen)
        current.stop()
        await start(PlayRequest(item: item, source: chosen, playSessionId: info?.playSessionId,
                                startMs: position.isFinite ? position : nil, queue: current.request.queue))
    }

    private func loadRecentLive() async {
        guard let client = session.client, let userId = session.userId else { return }
        let ids = Array(RecentChannels.ids(for: session.profileID).prefix(8))
        guard !ids.isEmpty else { recentLive = []; return }
        let result: ItemsResult? = try? await client.get("/Items", [
            "userId": userId, "Ids": ids.joined(separator: ","),
        ])
        let items = Dictionary((result?.items ?? []).filter(\.isChannel).map { ($0.id, $0) }) { first, _ in first }
        recentLive = ids.compactMap { items[$0] }
    }

    private func finish() {
        closing = true
        // Leaving a watch party's title sits it out, staying in the party.
        if let entry = model?.request.partyEntry { PartyFollow.shared.leftPlayer(entry) }
        model?.stop()
        close()
    }

    /// The next or previous channel, from up or down on a channel's video, in the guide's order.
    private func changeChannel(_ step: Int) async {
        guard let current = model, current.request.item.isChannel, finding == nil, !changingChannel,
              let client = session.client, let userId = session.userId else { return }
        changingChannel = true
        defer { changingChannel = false }
        var channels = current.request.channelLineup
        if channels.isEmpty {
            let list: ItemsResult? = try? await client.get("/LiveTv/Channels", [
                "userId": userId, "AddCurrentProgram": "false", "EnableImages": "false",
            ])
            channels = list?.items ?? []
        }
        guard let index = channels.firstIndex(where: { $0.id == current.request.item.id }), channels.count > 1 else { return }
        let next = channels[(index + step + channels.count) % channels.count]
        await playChannel(next, lineup: channels)
    }

    private func playChannel(_ next: Item, lineup: [Item]? = nil) async {
        guard let current = model, current.request.item.id != next.id, finding == nil,
              let client = session.client, let userId = session.userId else { return }
        finding = next
        defer { finding = nil }
        guard let info = try? await client.playbackInfo(userId: userId, itemId: next.id),
              var source = info.mediaSources?.first else { return }
        var playSession = info.playSessionId
        // Named, as when a channel is chosen from Live TV, for its stream in full.
        if let named = try? await client.playbackInfo(userId: userId, itemId: next.id, sourceId: source.ownId),
           let match = named.mediaSources?.first(where: { $0.ownId == source.ownId }) ?? named.mediaSources?.first {
            source = match
            playSession = named.playSessionId ?? playSession
        }
        current.stop()
        await start(PlayRequest(item: next, source: source, playSessionId: playSession, startMs: nil,
                                channelLineup: lineup ?? current.request.channelLineup))
    }
}

/// Episodes played on by themselves since anyone last pressed anything, for "Are you still watching?".
@MainActor
enum UnattendedPlays {
    static var count = 0
}

private enum PlayerFocus: Hashable {
    case surface, bar, play, back, forward, tracks, audio, chapters, speed, fit, skip, next, nextEpisode, keepWatching, stop, sync, episodes, versions, stats, pip
}

private enum PlayerPanel: Hashable {
    case tracks, audio, chapters, speed, sync, episodes, versions
}

private struct PlayerChrome: View {
    @ObservedObject var model: PlayerModel
    let close: () -> Void
    let playNext: (Item) -> Void
    let finding: Item?
    let recentLive: [Item]
    let tuneRecent: (Item) -> Void
    let pickEpisode: (Item) -> Void
    /// Closes the player's screen with the video still going, for Picture in Picture.
    var leave: () -> Void = {}
    /// Up or down on a channel's video: the next or previous channel.
    var changeChannel: (Int) -> Void = { _ in }
    let switchVersion: (MediaSource) -> Void
    let chooseAnotherVersion: () -> Void

    private var canChooseAnotherVersion: Bool {
        !model.isLive && !model.request.isTrailer && model.request.partyEntry == nil
    }

    /// The stats over the video's corner.
    @State private var stats = false
    /// Select was held for faster playback, so its letting go isn't a press.
    @State private var heldSelect = false

    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    /// The segment a skip button is offered for.
    @State private var offer: MediaSegment?
    /// The first seconds of an offered segment, when its button shows over hidden controls.
    @State private var offerFresh = false
    @State private var freshTask: Task<Void, Never>?
    /// "Skipped intro", after a skip the settings made.
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?
    /// Back hid the up next offer; seeking back before it brings it back.
    @State private var upNextDismissed = false
    @State private var askingStill = false
    @State private var countdownLeft: Double = 15
    @State private var playingOn = false

    @State private var shown = true
    @State private var panel: PlayerPanel?
    @State private var hideTask: Task<Void, Never>?
    @State private var controlsTop: CGFloat?

    /// The share of the screen under the top of the controls, with a little room above them.
    private var liftShare: Double {
        guard let controlsTop else { return 0 }
        let height = UIScreen.main.bounds.height
        return height > 0 ? Double(1 - (controlsTop - Theme.px(8)) / height) : 0
    }
    @FocusState private var focus: PlayerFocus?
    /// A hold the press watcher reported, which only its letting go ends.
    @State private var pressHeld = false
    /// The last few left or right moves, which come quickly over and over while a direction is held.
    @State private var lastMove: (direction: Int, at: Date, count: Int)?
    @State private var moveHoldEnd: Task<Void, Never>?
    /// A swipe along the bar in progress, or just finished.
    @State private var swiping = false
    @State private var swipeSettled: Task<Void, Never>?

    private var canScrub: Bool {
        !model.isLive && panel == nil && model.failure == nil && (!shown || focus == .bar || focus == .surface)
    }

    /// A move left or right, which reads as a hold once it repeats quickly, for remotes and
    /// directions that repeat their move while held. Returns whether it went to a scrub.
    private func moved(_ direction: Int) -> Bool {
        if pressHeld || swiping { return true }
        let now = Date()
        var count = 1
        if let last = lastMove, last.direction == direction, now.timeIntervalSince(last.at) < 0.4 {
            count = last.count + 1
        }
        lastMove = (direction, now, count)
        guard model.scrubbing || count >= 3, canScrub else { return false }
        model.startScrub(direction)
        moveHoldEnd?.cancel()
        moveHoldEnd = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, !pressHeld else { return }
            model.endScrub()
            lastMove = nil
            wake()
        }
        return true
    }

    var body: some View {
        ZStack {
            VideoSurface(model: model).ignoresSafeArea()

            // Holding left or right scrubs, while the controls are hidden or the bar has focus.
            PressHold(
                begin: { direction in
                    guard canScrub else { return false }
                    pressHeld = true
                    moveHoldEnd?.cancel()
                    model.startScrub(direction)
                    reveal(.bar)
                    return true
                },
                end: {
                    pressHeld = false
                    model.endScrub()
                    wake()
                }
            )
            .frame(width: 0, height: 0)

            // Holding Select on the video plays faster (Held speed) until it's let go.
            PressHold(
                presses: [.select],
                begin: { _ in
                    guard !shown, panel == nil, !model.isLive, !model.paused, model.failure == nil else { return false }
                    heldSelect = true
                    model.hold(prefs.holdRate)
                    return true
                },
                end: { model.hold(nil) }
            )
            .frame(width: 0, height: 0)

            // Swiping across the remote while paused, with the bar focused, slides along it.
            SwipeScrub(
                begin: {
                    guard !model.isLive, model.paused, shown, focus == .bar, panel == nil, model.failure == nil,
                          !model.scrubbing else { return false }
                    swiping = true
                    swipeSettled?.cancel()
                    model.startSwipe()
                    return true
                },
                change: { model.swipe($0) },
                end: {
                    model.endSwipe()
                    // The focus engine's own moves from the swipe can trail it; those aren't skips.
                    swipeSettled = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        if !Task.isCancelled { swiping = false }
                    }
                    wake()
                }
            )
            .frame(width: 0, height: 0)

            // Takes the remote while the controls are hidden.
            Color.clear
                .contentShape(Rectangle())
                .focusable(!shown && panel == nil)
                .focused($focus, equals: .surface)
                .onMoveCommand { direction in
                    input()
                    switch direction {
                    // Live, there's nothing to skip through: a press only shows the controls.
                    case .left where model.isLive, .right where model.isLive: reveal(.play)
                    case .left: if !moved(-1) { model.skip(-step) }; if prefs.showOnPauseAndSkip { reveal(.bar) }
                    case .right: if !moved(1) { model.skip(step) }; if prefs.showOnPauseAndSkip { reveal(.bar) }
                    // On a channel, up and down change channel, as a TV's remote does.
                    case .up where model.request.item.isChannel: changeChannel(-1)
                    case .down where model.request.item.isChannel: changeChannel(1)
                    default: reveal(.play)
                    }
                }
                .onTapGesture {
                    if heldSelect { heldSelect = false; return }
                    input()
                    if model.isLive { model.togglePause() }
                    reveal(.play)
                }

            if let rate = model.heldRate {
                Label(L("%@×", rate.formatted(.number.precision(.fractionLength(0...1)).locale(AppLanguage.locale))),
                      systemImage: "forward.fill")
                    .font(Theme.font(Theme.lg, .semibold))
                    .padding(.horizontal, Theme.px(18))
                    .padding(.vertical, Theme.px(10))
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, Theme.px(48))
            }
            if model.party != nil { PartyToasts() }
            if stats {
                StatsOverlay(engine: model.engine)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(Theme.px(48))
                    .allowsHitTesting(false)
            }

            if model.waiting && model.failure == nil {
                ProgressView().progressViewStyle(.linear).frame(width: Theme.px(160))
            }
            if let failure = model.failure { failureCard(failure) }

            if shown {
                VStack(spacing: 0) {
                    Spacer()
                    controlsDock
                }
                .transition(.opacity)
            } else if model.paused && !model.isLive && model.failure == nil {
                pauseInfo
                    .padding(.horizontal, Theme.px(48))
                    .padding(.bottom, Theme.px(40))
                    .padding(.top, Theme.px(24))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.black.opacity(0.72), .clear],
                                               startPoint: .bottom, endPoint: .top))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
            }

            if prefs.showClock && (shown || model.paused) && panel == nil && model.failure == nil {
                playbackHeader
            }

            if panel == .episodes {
                Color.black.opacity(0.22).ignoresSafeArea().allowsHitTesting(false)
                EpisodesDrawer(item: model.request.item, close: closePanel) { episode in
                    closePanel()
                    input()
                    pickEpisode(episode)
                }
                .padding(.trailing, Theme.px(42))
                .padding(.bottom, Theme.px(108))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomTrailing)))
            }

            if panel == .versions {
                PlaybackVersionsPopup(item: model.request.item, activeID: model.request.source.ownId,
                                      close: closePanel) { source in
                    closePanel()
                    switchVersion(source)
                }
                .padding(.trailing, Theme.px(42))
                .padding(.bottom, Theme.px(108))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomTrailing)))
            }

            if panel == nil && model.failure == nil {
                VStack(alignment: .trailing, spacing: Theme.px(12)) {
                    if let notice {
                        Text(notice)
                            .font(Theme.font(Theme.sm, .medium))
                            .padding(.horizontal, Theme.px(14))
                            .padding(.vertical, Theme.px(8))
                            .background(Capsule().fill(.black.opacity(0.7)))
                            .transition(.opacity)
                    }
                    if askingStill {
                        stillWatchingCard
                    } else if upNextShown, let next = model.nextEpisode {
                        upNextCard(next)
                    } else if skipShown, let offer {
                        Button { skip(offer) } label: {
                            Label(skipLabel(offer.type), systemImage: "forward.end.fill")
                        }
                        .buttonStyle(SkipStyle())
                        .focused($focus, equals: .skip)
                        .transition(.opacity)
                    }
                }
                // Its own focus section, no bigger than what it shows.
                .focusSection()
                .padding(.trailing, Theme.px(40))
                .padding(.bottom, shown ? Theme.px(150) : Theme.px(48))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .font(Theme.font(Theme.base))
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.2), value: shown)
        .animation(.easeOut(duration: 0.2), value: panel)
        .onPlayPauseCommand { input(); model.togglePause(); wake() }
        .onExitCommand {
            if askingStill { close() }
            else if panel != nil { closePanel() }
            else if model.failure != nil && canChooseAnotherVersion { chooseAnotherVersion() }
            else if upNextShown && (focus == .next || !shown) {
                upNextDismissed = true
                focus = shown ? .play : .surface
            } else if skipShown && focus == .skip && !shown {
                offerFresh = false
                focus = .surface
            }
            else if shown && model.failure == nil { hide() }
            else { close() }
        }
        .onAppear { focus = .play; wake() }
        // Another device's remote: the player takes what plays here, the pages the rest.
        .onAppear { ServerEvents.shared.playerHandler = remote }
        .onDisappear { ServerEvents.shared.playerHandler = nil }
        .onChange(of: focus) { _, _ in if shown { wake() } }
        // The subtitles rise over the controls while they show, and settle back as they hide.
        .onChange(of: shown) { _, shown in model.liftSubtitles(shown ? liftShare : 0) }
        // At the end, the next episode plays on where Jellyfin's autoplay is on.
        .onChange(of: model.finished) { _, done in
            guard done else { return }
            // In a watch party, the group moves on to its next title, or stops.
            if let entry = model.request.partyEntry, model.party != nil {
                WatchParty.shared.request(["type": "NextItem", "playlistItemId": entry])
                return
            }
            if model.nextEpisode != nil && prefs.autoplayNext { playOn(auto: true) } else { close() }
        }
        .onChange(of: inside?.id) { _, _ in enter(inside) }
        .onChange(of: skipShown) { _, showing in
            if showing && !shown { focus = .skip }
            if !showing && focus == .skip { focus = shown ? .play : .surface }
        }
        .onChange(of: upNextShown) { _, showing in
            if showing && !shown { focus = .next }
            if !showing {
                countdownLeft = prefs.nextCountdown
                if focus == .next { focus = shown ? .play : .surface }
            }
        }
        .onChange(of: upNextDue) { _, due in if !due { upNextDismissed = false } }
        .onChange(of: askingStill) { _, asking in if asking { focus = .keepWatching } }
        .onAppear { countdownLeft = prefs.nextCountdown }
        // Counts down while the offer shows and the video plays, then plays on.
        .task(id: counting) {
            guard counting else { return }
            while countdownLeft > 0 {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
                countdownLeft = max(0, countdownLeft - 0.25)
            }
            playOn(auto: true)
        }
        .onChange(of: model.paused) { _, paused in
            if paused { if prefs.showOnPauseAndSkip || shown { reveal(nil) } } else { wake() }
        }
    }

    // MARK: Transport

    private var playbackHeader: some View {
        TimelineView(.everyMinute) { context in
            Text(prefs.time(context.date)).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(Theme.font(Theme.sm, .semibold))
        .padding(.horizontal, Theme.px(48))
        .padding(.top, Theme.px(30))
        .padding(.bottom, Theme.px(22))
        .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    private var liveTitle: some View {
        let item = model.request.item
        return Text(item.currentProgram?.name ?? item.name ?? "")
            .font(Theme.font(Theme.lg, .semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pauseInfo: some View {
        let item = model.request.item
        let metadata = [item.episodeCode, item.communityRating.map { "★ " + $0.formatted(.number.precision(.fractionLength(1))) },
                        item.genres?.first].compactMap { $0 }
        return VStack(alignment: .leading, spacing: Theme.px(6)) {
            if let url = session.client?.logo(item, width: 480) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                            .frame(maxWidth: Theme.px(265), maxHeight: Theme.px(68), alignment: .leading)
                    } else if item.isEpisode, let series = item.seriesName {
                        Text(series).font(Theme.font(Theme.lg, .semibold)).lineLimit(1)
                    }
                }
            } else if item.isEpisode, let series = item.seriesName {
                Text(series).font(Theme.font(Theme.lg, .semibold)).lineLimit(1)
            }
            Text(item.name ?? item.displayTitle).font(Theme.font(Theme.xl, .semibold)).lineLimit(1)
            if !metadata.isEmpty {
                Text(metadata.joined(separator: " · ")).font(Theme.font(Theme.sm, .medium))
            }
            if let overview = model.overview, !overview.isEmpty {
                Text(overview).font(Theme.font(Theme.sm)).lineLimit(3)
            }
            TimelineView(.everyMinute) { context in
                let remaining = model.duration - (model.scrubTarget ?? model.position)
                HStack(spacing: Theme.px(10)) {
                    Label(L("Paused"), systemImage: "pause.fill")
                    if remaining.isFinite && remaining > 0 {
                        Text(L("%@ left", clock(remaining)))
                        Text("·").accessibilityHidden(true)
                        Text(L("Ends %@", prefs.time(context.date.addingTimeInterval(remaining / max(0.01, model.speed)))))
                    }
                }
                .font(Theme.font(Theme.xs, .semibold))
                .monospacedDigit()
            }
        }
        .padding(.leading, Theme.px(12))
        .overlay(alignment: .leading) {
            Capsule().fill(.white.opacity(0.36)).frame(width: Theme.px(2))
        }
        .frame(maxWidth: Theme.px(600), alignment: .leading)
        .shadow(color: .black, radius: Theme.px(4))
    }

    private var controlsDock: some View {
        VStack(alignment: .leading, spacing: Theme.px(8)) {
            if let panel, panel != .chapters, panel != .episodes, panel != .versions {
                dockedPanel(panel)
            }
            if model.paused && !model.isLive && model.failure == nil && panel == nil {
                pauseInfo.padding(.bottom, Theme.px(4))
            }

            VStack(spacing: Theme.px(6)) {
                if model.isLive {
                    HStack(alignment: .bottom, spacing: Theme.px(16)) {
                        liveTitle
                        transportButtons.fixedSize(horizontal: true, vertical: false).focusSection()
                    }
                    Capsule().fill(.white.opacity(0.22)).frame(height: Theme.px(3))
                    if !recentLive.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.px(7)) {
                            Text(L("Recently watched")).font(Theme.font(Theme.sm, .semibold))
                            ScrollView(.horizontal) {
                                HStack(spacing: Theme.px(8)) {
                                    ForEach(recentLive) { channel in
                                        Button { tuneRecent(channel) } label: {
                                            VStack(alignment: .leading, spacing: Theme.px(5)) {
                                                ChannelLogo(channel: channel)
                                                    .frame(width: Theme.px(140), height: Theme.px(78))
                                                Text(channel.name ?? L("Channel"))
                                                    .font(Theme.font(Theme.xs, .medium)).lineLimit(1)
                                            }
                                            .frame(width: Theme.px(140), alignment: .leading)
                                        }
                                        .buttonStyle(CardStyle())
                                        .accessibilityAddTraits(channel.id == model.request.item.id ? .isSelected : [])
                                    }
                                }
                                .padding(.vertical, Theme.px(4))
                            }
                        }
                        .focusSection()
                    }
                } else {
                    transportButtons.focusSection()
                    timeline
                }
            }
            .disabled(panel != nil)

            if panel == .chapters {
                dockedPanel(.chapters)
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).minY
        } action: { top in
            controlsTop = top
            if shown { model.liftSubtitles(liftShare) }
        }
        .padding(.horizontal, Theme.px(48))
        .padding(.bottom, Theme.px(26))
        .background {
            LinearGradient(colors: [.black.opacity(0.92), .black.opacity(0.55), .clear],
                           startPoint: .bottom, endPoint: .top)
                .padding(.top, -Theme.px(46))
        }
    }

    private func dockedPanel(_ panel: PlayerPanel) -> some View {
        PlayerPanelView(model: model, panel: panel) { closePanel() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var timeline: some View {
        let position = model.scrubTarget ?? model.position
        return VStack(alignment: .leading, spacing: Theme.px(4)) {
            ProgressTrack(model: model, focused: focus == .bar)
                .focusable(shown && panel == nil)
                .focused($focus, equals: .bar)
                .accessibilityLabel(L("Playback position"))
                .onMoveCommand { direction in
                    input()
                    switch direction {
                    case .left: if !moved(-1) { model.skip(-step) }
                    case .right: if !moved(1) { model.skip(step) }
                    default: break
                    }
                    wake()
                }
                .onTapGesture { model.togglePause(); wake() }
                .overlay(alignment: .bottomLeading) { scrubPreview }
            HStack {
                Text(clock(position))
                Spacer()
                if model.paused && model.duration.isFinite && model.duration > 0 {
                    Text("−\(clock(max(0, model.duration - position)))")
                }
            }
            .font(Theme.font(Theme.xs, .medium))
            .monospacedDigit()
            .foregroundStyle(Theme.gray200)
        }
    }

    private var transportButtons: some View {
        HStack(spacing: Theme.px(8)) {
            Button { model.togglePause() } label: {
                Image(systemName: model.paused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(ControlIconStyle(flat: !model.isLive, primary: !model.isLive))
            .accessibilityLabel(model.paused ? L("Play") : L("Pause"))
            .focused($focus, equals: .play)
            if model.isLive {
                Text(L("LIVE"))
                    .font(Theme.font(Theme.sm, .bold))
                    .padding(.horizontal, Theme.px(10))
                    .padding(.vertical, Theme.px(4))
                    .background(Capsule().fill(Color.red.opacity(0.85)))
                    .padding(.leading, Theme.px(12))
            } else {
                Button { model.skip(-step) } label: { Image(systemName: "gobackward.\(prefs.seekStep)") }
                    .buttonStyle(ControlIconStyle(flat: !model.isLive))
                    .focused($focus, equals: .back)
                Button { model.skip(step) } label: { Image(systemName: "goforward.\(prefs.seekStep)") }
                    .buttonStyle(ControlIconStyle(flat: !model.isLive))
                    .focused($focus, equals: .forward)

            }
            if !model.isLive { Spacer(minLength: Theme.px(12)) }
            if model.nextEpisode != nil && model.party == nil {
                Button { playOn(auto: false) } label: { Image(systemName: "forward.end.fill") }
                    .buttonStyle(ControlIconStyle(flat: !model.isLive))
                    .accessibilityLabel(model.request.item.isEpisode ? L("Next episode") : L("Play next"))
                    .focused($focus, equals: .nextEpisode)
            }
            if model.request.item.isEpisode {
                Button { open(.episodes) } label: { Image(systemName: "list.and.film") }
                    .buttonStyle(ControlIconStyle(flat: !model.isLive))
                    .focused($focus, equals: .episodes)
            }
            // Audio and subtitles each have their own button, so a long subtitle list doesn't
            // bury the audio tracks.
            Button { open(.audio) } label: { Image(systemName: "speaker.wave.2") }
                .buttonStyle(ControlIconStyle(flat: !model.isLive))
                .accessibilityLabel(L("Audio"))
                .focused($focus, equals: .audio)
            Button { open(.tracks) } label: { Image(systemName: "captions.bubble") }
                .buttonStyle(ControlIconStyle(flat: !model.isLive))
                .accessibilityLabel(L("Subtitles"))
                .focused($focus, equals: .tracks)
            if !model.isLive && prefs.showSyncControls {
                Button { open(.sync) } label: { Image(systemName: "timer") }
                    .buttonStyle(ControlIconStyle(flat: !model.isLive))
                    .focused($focus, equals: .sync)
            }
            if prefs.chapterControl && !model.chapters.isEmpty {
                Button { open(.chapters) } label: { Image(systemName: "rectangle.split.3x1") }
                    .buttonStyle(ControlIconStyle(flat: !model.isLive))
                    .accessibilityLabel(L("Chapters"))
                    .focused($focus, equals: .chapters)
            }
            if !model.isLive && prefs.speedControl {
                Button { open(.speed) } label: { Image(systemName: "gauge.with.dots.needle.50percent") }
                    .buttonStyle(ControlIconStyle(flat: !model.isLive))
                    .focused($focus, equals: .speed)
            }
            if canChooseAnotherVersion && prefs.versionControl {
                Button { open(.versions) } label: { Image(systemName: "square.stack") }
                    .buttonStyle(ControlIconStyle(flat: true))
                    .accessibilityLabel(L("Versions"))
                    .focused($focus, equals: .versions)
            }
            if prefs.fitControl {
                Button {
                    let all = PlayerModel.Fit.allCases
                    model.setFit(all[(all.firstIndex(of: model.fit)! + 1) % all.count])
                } label: {
                    Image(systemName: model.fit == .fit ? "rectangle.arrowtriangle.2.outward" : model.fit == .crop ? "crop" : "arrow.left.and.right.square")
                }
                .buttonStyle(ControlIconStyle(flat: !model.isLive))
                .focused($focus, equals: .fit)
            }
            Button { stats.toggle() } label: { Image(systemName: stats ? "chart.bar.fill" : "chart.bar") }
                .buttonStyle(ControlIconStyle(flat: !model.isLive))
                .focused($focus, equals: .stats)
            if TVPictureInPicture.available(model.engine) {
                Button {
                    TVPictureInPicture.shared.start(model) { leave() }
                } label: { Image(systemName: "pip.enter") }
                    .buttonStyle(ControlIconStyle(flat: !model.isLive))
                    .focused($focus, equals: .pip)
            }
        }
    }

    private static let previewWidth = Theme.px(240)
    private static let previewHeight = Theme.px(210)

    /// While scrubbing: a frame from where it would land, its time, and the speed, over that point of
    /// the bar. The frame comes in as the engine makes it; until then the time and speed show alone.
    @ViewBuilder private var scrubPreview: some View {
        if let target = model.scrubTarget {
            GeometryReader { geometry in
                let width = geometry.size.width
                let at = model.duration > 0 ? CGFloat(min(max(target / model.duration, 0), 1)) * width : 0
                let x = min(max(at - Self.previewWidth / 2, 0), max(width - Self.previewWidth, 0))
                VStack(spacing: Theme.px(6)) {
                    if let image = model.preview {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: Self.previewWidth, height: Self.previewWidth * 9 / 16)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous)
                                .stroke(.white.opacity(0.6), lineWidth: Theme.px(1.5)))
                    }
                    HStack(spacing: Theme.px(8)) {
                        Text(clock(target)).monospacedDigit()
                        if model.scrubSpeed != 0 {
                            HStack(spacing: Theme.px(4)) {
                                Image(systemName: model.scrubSpeed > 0 ? "forward.fill" : "backward.fill")
                                Text(verbatim: "\(abs(model.scrubSpeed))×").monospacedDigit()
                            }
                            .foregroundStyle(Theme.gray200)
                        }
                    }
                    .font(Theme.font(Theme.base, .semibold))
                    .padding(.horizontal, Theme.px(12))
                    .padding(.vertical, Theme.px(5))
                    .background(Capsule().fill(.black.opacity(0.7)))
                }
                .frame(width: Self.previewWidth, height: Self.previewHeight, alignment: .bottom)
                .offset(x: x, y: -Self.previewHeight - Theme.px(8))
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private func failureCard(_ failure: String) -> some View {
        VStack(spacing: Theme.px(12)) {
            Text(L("This version didn't play")).font(Theme.font(Theme.xl, .semibold))
            Text(failure).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray300).multilineTextAlignment(.center)
            if canChooseAnotherVersion {
                Text(L("Press Back to pick another version.")).font(Theme.font(Theme.xs)).foregroundStyle(Theme.gray400)
            }
        }
        .padding(Theme.px(32))
        .frame(maxWidth: Theme.px(560))
        .background(RoundedRectangle(cornerRadius: Theme.px(16)).fill(Color(white: 17 / 255).opacity(0.95)))
    }

    /// The seek step the settings choose, in seconds.
    private var step: Double { Double(prefs.seekStep) }

    // MARK: Skipping and the next episode

    /// Someone's there: the run of episodes played on by themselves starts over.
    private func input() { UnattendedPlays.count = 0 }

    /// The segment playing now, short of its last second.
    private var inside: MediaSegment? {
        let at = model.position
        return model.segments.first { at >= $0.start && at < $0.end - 1 }
    }

    /// Credits that end the episode, which the next episode's offer takes over from.
    private func endsEpisode(_ segment: MediaSegment) -> Bool {
        let duration = model.duration
        return duration > 0 && segment.end >= duration * 0.9 && duration - segment.end <= 30
    }

    /// Where the next episode is offered: at the credits when they end the episode, else the
    /// chosen lead before the end. None for a short video, or with the offer off.
    private var promptAt: Double? {
        guard model.nextEpisode != nil, model.party == nil, model.duration >= 40, prefs.nextPrompt != "off" else { return nil }
        if prefs.nextPrompt == "credits",
           let credits = model.segments.first(where: { $0.type == "Outro" && endsEpisode($0) }) {
            return credits.start
        }
        return model.duration - prefs.nextLead
    }

    private var upNextDue: Bool { model.started && (promptAt.map { model.position >= $0 } ?? false) }
    private var upNextShown: Bool { upNextDue && !upNextDismissed && !askingStill && !playingOn && finding == nil }
    private var counting: Bool { upNextShown && prefs.autoplayNext && !model.paused }

    private var skipShown: Bool {
        guard let offer, inside?.id == offer.id else { return false }
        // The next episode's offer stands in for skipping the credits.
        if offer.type == "Outro" && endsEpisode(offer) && upNextDue && !upNextDismissed { return false }
        return shown || offerFresh
    }

    /// A segment starting: skipped where the settings say, else offered for a few seconds.
    private func enter(_ segment: MediaSegment?) {
        freshTask?.cancel()
        offerFresh = false
        offer = nil
        guard let segment, !model.scrubbing, model.scrubTarget == nil else { return }
        switch prefs.segmentAction(segment.type) {
        case "skip":
            // Credits before the next episode's offer are left to it.
            if segment.type == "Outro" && endsEpisode(segment) && promptAt != nil { return }
            model.seek(to: segment.end)
            show(skippedLabel(segment.type))
        case "ask":
            offer = segment
            offerFresh = true
            freshTask = Task {
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { offerFresh = false }
            }
        default:
            break
        }
    }

    private func skip(_ segment: MediaSegment) {
        input()
        offer = nil
        model.seek(to: segment.end)
        wake()
    }

    private func show(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { notice = nil }
        }
    }

    private func skipLabel(_ type: String) -> String {
        ["Intro": L("Skip intro"), "Recap": L("Skip recap"), "Outro": L("Skip credits"), "Preview": L("Skip preview"),
         "Commercial": L("Skip ad")][type] ?? L("Skip")
    }

    private func skippedLabel(_ type: String) -> String {
        ["Intro": L("Skipped intro"), "Recap": L("Skipped recap"), "Outro": L("Skipped credits"), "Preview": L("Skipped preview"),
         "Commercial": L("Skipped ad")][type] ?? L("Skipped")
    }

    /// What another device's remote sends while the player is up; a new title closes it for the
    /// pages to play.
    private func remote(_ command: RemoteCommand) -> Bool {
        switch command {
        case .key(let key):
            switch key {
            case .pause: if !model.paused { model.togglePause() }
            case .play: if model.paused { model.togglePause() }
            case .toggle: model.togglePause()
            case .stop: close(); return true
            case .next: if model.nextEpisode != nil { playOn(auto: false) }
            case .previous: model.seek(to: 0)
            case .seek(let ms): model.seek(to: ms / 1000)
            case .skip(let ms): model.skip(ms / 1000)
            }
            wake()
            return true
        case .track(let audio, let index):
            model.selectServerTrack(audio: audio, index: index)
            return true
        case .play:
            close()
            return false
        case .show:
            return false
        }
    }

    /// Moves on to the next episode; by itself, after a run of them, it asks first.
    private func playOn(auto: Bool) {
        guard !playingOn else { return }
        guard let next = model.nextEpisode else { return close() }
        if auto {
            let limit = prefs.stillWatching
            if limit > 0 && UnattendedPlays.count + 1 >= limit {
                askingStill = true
                if !model.paused && !model.finished { model.togglePause() }
                return
            }
            UnattendedPlays.count += 1
        } else {
            input()
        }
        playingOn = true
        playNext(next)
    }

    private func upNextCard(_ next: Item) -> some View {
        HStack(spacing: Theme.px(14)) {
            if let client = session.client {
                RemoteImage(url: client.still(next, height: 180))
                    .frame(width: Theme.px(144), height: Theme.px(81))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous))
            }
            VStack(alignment: .leading, spacing: Theme.px(6)) {
                Text(model.request.queue.isEmpty ? L("Next episode") : L("Up next")).font(Theme.font(Theme.xs, .medium)).foregroundStyle(Theme.gray400)
                Text(next.displayTitle).font(Theme.font(Theme.base, .semibold)).lineLimit(1)
                Button { playOn(auto: false) } label: {
                    Label(counting ? L("Playing in %@s", "\(max(1, Int(countdownLeft.rounded(.up))))") : L("Play next"),
                          systemImage: "play.fill")
                        .monospacedDigit()
                }
                .buttonStyle(SoftPillStyle(selected: true))
                .focused($focus, equals: .next)
            }
        }
        .padding(Theme.px(14))
        .frame(maxWidth: Theme.px(440), alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.px(14), style: .continuous).fill(Color(white: 17 / 255).opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: Theme.px(14), style: .continuous).stroke(.white.opacity(0.1), lineWidth: Theme.px(1)))
        .transition(.opacity)
    }

    private var stillWatchingCard: some View {
        VStack(alignment: .leading, spacing: Theme.px(12)) {
            Text(L("Are you still watching?")).font(Theme.font(Theme.lg, .semibold))
            HStack(spacing: Theme.px(8)) {
                Button(L("Keep watching")) {
                    askingStill = false
                    playOn(auto: false)
                }
                .buttonStyle(SoftPillStyle(selected: true))
                .focused($focus, equals: .keepWatching)
                Button(L("Stop")) { close() }
                    .buttonStyle(SoftPillStyle())
                    .focused($focus, equals: .stop)
            }
        }
        .padding(Theme.px(18))
        .background(RoundedRectangle(cornerRadius: Theme.px(14), style: .continuous).fill(Color(white: 17 / 255).opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: Theme.px(14), style: .continuous).stroke(.white.opacity(0.1), lineWidth: Theme.px(1)))
        .transition(.opacity)
    }

    // MARK: Showing and hiding

    /// Shows the controls, focusing `target` where given.
    private func reveal(_ target: PlayerFocus?) {
        shown = true
        if let target { focus = target }
        wake()
    }

    private func hide() {
        hideTask?.cancel()
        shown = false
        focus = .surface
    }

    /// Hides the controls a few seconds after the last press, while the video plays.
    private func wake() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, !model.paused, panel == nil, model.failure == nil, !DemoMode.holdsControls,
                  model.scrubTarget == nil else { return }
            hide()
        }
    }

    private func open(_ which: PlayerPanel) {
        hideTask?.cancel()
        panel = which
    }

    private func closePanel() {
        let from = panel
        panel = nil
        switch from {
        case .tracks: focus = .tracks
        case .audio: focus = .audio
        case .chapters: focus = .chapters
        case .speed: focus = .speed
        case .sync: focus = prefs.showSyncControls ? .sync : .play
        case .episodes: focus = .episodes
        case .versions: focus = .versions
        case nil: break
        }
        wake()
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds.isFinite ? max(seconds, 0) : 0)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The bar across the bottom: played in the accent, held ahead lighter, gaps at chapter starts.
private struct ProgressTrack: View {
    @ObservedObject var model: PlayerModel
    let focused: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let share = { (seconds: Double) -> CGFloat in
                model.duration > 0 ? CGFloat(min(max(seconds / model.duration, 0), 1)) * width : 0
            }
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(.white.opacity(0.35)).frame(width: share(model.buffered))
                Capsule().fill(.white).frame(width: share(model.scrubTarget ?? model.position))
                ForEach(model.chapters.dropFirst(), id: \.id) { chapter in
                    Rectangle()
                        .fill(Color.black)
                        .frame(width: Theme.px(3))
                        .offset(x: share(chapter.start) - Theme.px(1.5))
                }
                Circle()
                    .fill(.white)
                    .frame(width: Theme.px(focused ? 8 : 6), height: Theme.px(focused ? 8 : 6))
                    .offset(x: share(model.scrubTarget ?? model.position) - Theme.px(focused ? 4 : 3))
            }
            .frame(height: Theme.px(2))
            .frame(maxHeight: .infinity)
        }
        .frame(height: Theme.px(16))
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// The skip button over the video: white on dark, filling white with focus.
private struct SkipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Focused { focused in
            configuration.label
                .font(Theme.font(Theme.base, .semibold))
                .foregroundStyle(focused ? .black : .white)
                .padding(.horizontal, Theme.px(18))
                .frame(height: Theme.px(44))
                .background(Capsule().fill(focused ? Color.white : Color.black.opacity(0.65)))
                .overlay(Capsule().stroke(.white.opacity(focused ? 0 : 0.4), lineWidth: Theme.px(1)))
                .scaleEffect(focused ? 1.05 : 1)
                .animation(.easeOut(duration: 0.12), value: focused)
                .opacity(configuration.isPressed ? 0.85 : 1)
        }
    }
}

/// A compact transport control with a monochrome focus state.
private struct ControlIconStyle: ButtonStyle {
    var flat = false
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        Focused { focused in
            configuration.label
                .font(.system(size: Theme.px(17), weight: .semibold))
                .foregroundStyle(focused || primary ? Color.black : Color.white)
                .frame(width: Theme.px(38), height: Theme.px(38))
                .background(Circle().fill(focused || primary ? Color.white : flat ? Color.clear : Color.black.opacity(0.42)))
                .overlay(Circle().strokeBorder(.white.opacity(focused || primary || flat ? 0 : 0.13), lineWidth: Theme.px(1)))
                .brightness(focused && primary ? -0.15 : 0)
                .scaleEffect(focused ? 1.07 : 1)
                .opacity(configuration.isPressed ? 0.8 : 1)
        }
    }
}

/// A bounded menu or a chapter strip docked to the transport.
private struct PlayerPanelView: View {
    @EnvironmentObject private var session: Session
    @ObservedObject var model: PlayerModel
    let panel: PlayerPanel
    let done: () -> Void
    @Namespace private var menuFocus
    @EnvironmentObject private var prefs: Preferences
    /// Subtitles in other languages, which List only my languages keeps under More languages.
    @State private var allLanguages = false

    /// The subtitles listed: with List only my languages, those in the user's languages, without a
    /// language, and the one on; the rest wait under More languages.
    private var listedSubtitles: [TrackInfo] {
        guard prefs.listOnlyMyLanguages == true, !allLanguages else { return model.subtitleTracks }
        let mine = model.tracks.subtitleLanguages
        return model.subtitleTracks.filter { track in
            track.id == model.activeSubtitle || LanguageCodes.normal(track.language) == nil
                || mine.contains { LanguageCodes.same($0, track.language) }
        }
    }

    private static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    private var headerTitle: String {
        switch panel {
        case .tracks: return L("Subtitles")
        case .audio: return L("Audio")
        case .chapters: return L("Chapters")
        case .speed: return L("Speed")
        case .sync: return L("Sync")
        case .versions: return L("Versions")
        case .episodes: return model.request.item.parentIndexNumber.map { L("Season %@", "\($0)") } ?? L("Episodes")
        }
    }

    private var currentChapter: PlayerChapter? {
        model.chapters.last { $0.start <= model.position }
    }

    private var chapters: some View {
        ScrollViewReader { scroll in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Theme.px(15)) {
                    ForEach(model.chapters, id: \.id) { chapter in
                        let current = chapter.id == currentChapter?.id
                        ChapterTile(model: model, chapter: chapter, time: clock(chapter.start),
                                    current: current, namespace: menuFocus) {
                            model.seek(to: chapter.start)
                            done()
                        }
                        .id(chapter.id)
                    }
                }
                .padding(.horizontal, Theme.px(6))
                .padding(.vertical, Theme.px(7))
            }
            .frame(height: Theme.px(151))
            .task {
                if let chapter = currentChapter { scroll.scrollTo(chapter.id, anchor: .center) }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(10)) {
            HStack {
                Text(headerTitle).font(Theme.font(Theme.lg, .semibold))
                Spacer()
                Button(action: done) { Image(systemName: "xmark") }
                    .buttonStyle(ControlIconStyle())
                    .accessibilityLabel(L("Close"))
                    .prefersDefaultFocus(panel == .sync, in: menuFocus)
            }
            .padding(.leading, Theme.px(8))
            if panel == .chapters {
                chapters
            } else if panel == .sync {
                VStack(alignment: .leading, spacing: Theme.px(16)) {
                    group(L("Subtitles")) {
                        stepper(model.subtitleDelay, step: 0.1) { model.setSubtitleDelay($0) }
                    }
                    group(L("Audio")) {
                        stepper(model.audioDelay, step: 0.05) { model.setAudioDelay($0) }
                    }
                    Text(L("Later shows subtitles, or plays the sound, after the picture; earlier, before it. Kept for this title."))
                        .font(Theme.font(Theme.xs))
                        .foregroundStyle(Theme.gray400)
                        .padding(.horizontal, Theme.px(12))
                }
            } else {
                choices
            }
        }
        .padding(Theme.px(14))
        .frame(maxWidth: panel == .chapters ? .infinity : Theme.px(460))
        .background {
            RoundedRectangle(cornerRadius: Theme.px(22))
                .fill(.regularMaterial)
                .overlay { RoundedRectangle(cornerRadius: Theme.px(22)).fill(.black.opacity(0.38)) }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.px(22)).strokeBorder(.white.opacity(0.15), lineWidth: Theme.px(1)))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .focusScope(menuFocus)
        .focusSection()
        .onExitCommand(perform: done)
    }

    private var choices: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.px(20)) {
                switch panel {
                case .tracks:
                    group(nil) {
                        row(L("Off"), on: model.activeSubtitle == nil) { model.selectSubtitle(nil) }
                        ForEach(listedSubtitles) { track in
                            row(label(track), on: track.id == model.activeSubtitle) { model.selectSubtitle(track.id) }
                        }
                        if listedSubtitles.count < model.subtitleTracks.count {
                            row(L("More languages"), on: false) { allLanguages = true }
                        }
                    }
                case .audio:
                    group(nil) {
                        if model.audioTracks.isEmpty {
                            Text(L("This version has one audio track."))
                                .font(Theme.font(Theme.sm))
                                .foregroundStyle(Theme.gray400)
                                .padding(.horizontal, Theme.px(12))
                                .focusable()
                        }
                        ForEach(model.audioTracks) { track in
                            row(label(track), detail: audioDetail(track), on: track.id == model.activeAudio) {
                                model.selectAudio(track.id)
                            }
                        }
                    }
                case .chapters:
                    EmptyView()
                case .speed:
                    group(nil) {
                        ForEach(Self.speeds, id: \.self) { value in
                            row(value == 1 ? L("Normal") : String(format: "%g×", value), on: abs(model.speed - value) < 0.01) {
                                model.setSpeed(value)
                            }
                        }
                    }
                case .sync, .episodes, .versions:
                    EmptyView()
                }
            }
            .padding(Theme.px(4))
        }
        .frame(height: Theme.px(224))
    }

    /// Earlier, the value, later, and back to zero.
    private func stepper(_ value: Double, step: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: Theme.px(8)) {
            Button { set(value - step) } label: { Image(systemName: "minus") }
                .buttonStyle(ControlIconStyle())
            Text(value == 0 ? L("In sync") : String(format: "%+.2f s", value))
                .font(Theme.font(Theme.base, .semibold))
                .monospacedDigit()
                .frame(minWidth: Theme.px(110))
            Button { set(value + step) } label: { Image(systemName: "plus") }
                .buttonStyle(ControlIconStyle())
            Button(L("Reset")) { set(0) }
                .buttonStyle(SoftPillStyle())
                .disabled(value == 0)
        }
        .padding(.horizontal, Theme.px(8))
    }

    private func group<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.px(4)) {
            if let title {
                Text(title)
                    .font(Theme.font(Theme.sm, .semibold))
                    .foregroundStyle(Theme.gray400)
                    .padding(.horizontal, Theme.px(12))
                    .padding(.bottom, Theme.px(4))
            }
            content()
        }
    }

    private func row(_ text: String, detail: String? = nil, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.px(10)) {
                Text(text).font(Theme.font(15)).lineLimit(1)
                Spacer(minLength: Theme.px(8))
                if let detail {
                    Text(detail).font(Theme.font(Theme.xs)).opacity(0.72).monospacedDigit().lineLimit(1)
                }
                Image(systemName: "checkmark")
                    .font(.system(size: Theme.px(13), weight: .semibold))
                    .opacity(on ? 1 : 0)
            }
            .padding(.horizontal, Theme.px(12))
            .frame(height: Theme.px(40))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PanelRowStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
        .prefersDefaultFocus(on, in: menuFocus)
    }

    /// What tells audio tracks apart besides their language: the format, channels, Atmos or DTS:X,
    /// and commentary or audio description.
    private func audioDetail(_ track: TrackInfo) -> String? {
        let codecs = ["truehd": "TrueHD", "eac3": "DD+", "ac3": "DD", "dts": "DTS",
                      "aac": "AAC", "flac": "FLAC", "opus": "Opus", "mp3": "MP3", "pcm_s16le": "PCM", "pcm_s24le": "PCM"]
        var parts: [String] = []
        if let codec = codecs[track.codec.lowercased()] { parts.append(codec) }
        if track.isAtmos { parts.append("Atmos") } else if track.isDTSX { parts.append("DTS:X") }
        switch track.channels {
        case 1: parts.append(L("Mono"))
        case 2: parts.append(L("Stereo"))
        case 6: parts.append("5.1")
        case 8: parts.append("7.1")
        case let count where count > 2: parts.append(L("%@ ch", "\(count)"))
        default: break
        }
        if track.isCommentary { parts.append(L("Commentary")) }
        if track.isVisualImpaired { parts.append(L("Audio description")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func label(_ track: TrackInfo) -> String {
        var parts: [String] = []
        if !track.name.isEmpty { parts.append(track.name) }
        if let language = track.language, !language.isEmpty, !track.name.localizedCaseInsensitiveContains(language) {
            parts.append(AppLanguage.locale.localizedString(forLanguageCode: language) ?? language)
        }
        if track.isForced { parts.append(L("Forced")) }
        if track.isExternal { parts.append(L("Addon")) }
        return parts.isEmpty ? L("Track %@", "\(track.id)") : parts.joined(separator: " · ")
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct PanelRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Inner(label: configuration.label)
    }

    private struct Inner<Label: View>: View {
        @Environment(\.isFocused) private var focused
        let label: Label

        var body: some View {
            label
                .foregroundStyle(focused ? Color.black : Color.white)
                .background(
                    RoundedRectangle(cornerRadius: Theme.px(8), style: .continuous)
                        .fill(focused ? Color.white : Color.clear)
                )
        }
    }
}

/// A chapter with its picture: the server's, else a frame or trickplay thumbnail the model makes.
private struct ChapterTile: View {
    @ObservedObject var model: PlayerModel
    let chapter: PlayerChapter
    let time: String
    let current: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var picture: CGImage?

    private let width = Theme.px(184)

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.px(5)) {
                ZStack(alignment: .bottomTrailing) {
                    Color(white: 0.12)
                    if let url = chapter.image {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase { image.resizable().scaledToFill() }
                        }
                    } else if let picture {
                        Image(decorative: picture, scale: 1).resizable().scaledToFill()
                    }
                    Text(time).font(Theme.font(Theme.xs, .semibold)).monospacedDigit()
                        .padding(.horizontal, Theme.px(6))
                        .padding(.vertical, Theme.px(3))
                        .background(.black.opacity(0.74), in: Capsule())
                        .padding(Theme.px(6))
                }
                .frame(width: width, height: width * 9 / 16)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: Theme.px(10)))
                .overlay(RoundedRectangle(cornerRadius: Theme.px(10))
                    .strokeBorder(.white.opacity(current ? 0.8 : 0.18), lineWidth: Theme.px(1)))
                Text(chapter.name.isEmpty ? L("Chapter %@", "\(chapter.id + 1)") : chapter.name)
                    .font(Theme.font(Theme.sm, .medium))
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(ChapterTileStyle())
        .prefersDefaultFocus(current, in: namespace)
        .accessibilityAddTraits(current ? .isSelected : [])
        .task(id: chapter.id) {
            if chapter.image == nil { picture = await model.picture(at: chapter.start + 2) }
        }
    }
}

private struct ChapterTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Focused { focused in
            configuration.label
                .opacity(focused ? 1 : 0.82)
                .scaleEffect(focused ? 1.045 : 1)
                .opacity(configuration.isPressed ? 0.8 : 1)
        }
    }
}


/// Artwork covers the old frame while the chosen episode opens.
private struct EpisodeLoadingView: View {
    @EnvironmentObject private var session: Session
    let item: Item

    private var logoItem: Item {
        var copy = item
        copy.name = item.seriesName ?? item.name
        return copy
    }

    var body: some View {
        ZStack {
            Color.black
            RemoteImage(url: session.client?.backdrop(item, height: 1080)
                        ?? session.client?.still(item, height: 1080))
                .overlay(Color.black.opacity(0.64))
            VStack(spacing: Theme.px(20)) {
                TitleLogo(item: logoItem, maxHeight: Theme.px(130), maxWidth: Theme.px(430), titleSize: 44)
                Text(item.displayTitle).font(Theme.font(Theme.base, .medium))
                ProgressView().progressViewStyle(.linear).frame(width: Theme.px(140))
            }
            .foregroundStyle(.white)
            .padding(Theme.px(36))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}

private struct EpisodesDrawer: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @State private var seasons: [Item] = []
    @State private var selectedSeason: String?
    @State private var episodes: [Item]?
    @State private var failed = false
    @State private var pendingUnaired: Item?
    @State private var confirmsUnaired = false
    @FocusState private var focusedEpisode: String?
    let item: Item
    let close: () -> Void
    let play: (Item) -> Void

    private var seasonID: String? { selectedSeason ?? item.seasonId ?? seasons.first?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(12)) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Theme.px(4)) {
                    Text(L("Episodes").uppercased()).font(Theme.font(Theme.xs, .semibold)).foregroundStyle(Theme.gray300)
                    Text(item.seriesName ?? item.name ?? L("Episodes")).font(Theme.font(Theme.lg, .semibold)).lineLimit(2)
                }
                Spacer(minLength: Theme.px(8))
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(ControlIconStyle())
                    .accessibilityLabel(L("Close"))
            }
            .padding(.horizontal, Theme.px(16))
            if seasons.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: Theme.px(6)) {
                        ForEach(seasons) { season in
                            Button(season.name ?? L("Season")) { selectedSeason = season.id }
                                .buttonStyle(SoftPillStyle(selected: season.id == seasonID))
                                .accessibilityAddTraits(season.id == seasonID ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, Theme.px(16))
                    .padding(.vertical, Theme.px(4))
                }
                .focusSection()
            }
            Divider()
            episodeList
        }
        .padding(.vertical, Theme.px(23))
        .frame(width: Theme.px(410), height: Theme.px(412), alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.px(20)))
        .clipShape(RoundedRectangle(cornerRadius: Theme.px(20)))
        .focusSection()
        .task { await loadSeasons() }
        .task(id: seasonID) { await loadEpisodes(seasonID) }
        .alert(L("This episode hasn't aired yet."), isPresented: $confirmsUnaired, presenting: pendingUnaired) { episode in
            Button(L("Play anyway")) { play(episode) }
            Button(L("Cancel"), role: .cancel) {}
        }
    }

    private var episodeList: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: Theme.px(6)) {
                    if let episodes {
                        if episodes.isEmpty {
                            Text(L("No episodes found.")).foregroundStyle(Theme.gray300).padding()
                        }
                        ForEach(episodes) { episode in
                            let playing = item.id == episode.id
                            Button {
                                if playing { close() }
                                else if prefs.markUnaired, let date = parseDate(episode.premiereDate), date > Date() {
                                    pendingUnaired = episode
                                    confirmsUnaired = true
                                } else { play(episode) }
                            } label: {
                                episodeRow(episode, playing: playing)
                            }
                            .buttonStyle(EpisodeDrawerRowStyle(playing: playing))
                            .disabled(!playing && !episode.playable)
                            .focused($focusedEpisode, equals: episode.id)
                            .accessibilityAddTraits(playing ? .isSelected : [])
                            .id(episode.id)
                        }
                    } else if failed {
                        Text(L("Could not load the episodes.")).padding()
                    } else {
                        ProgressView().padding()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.px(10))
                .padding(.vertical, Theme.px(6))
            }
            .onChange(of: episodes?.map(\.id)) { previous, ids in
                if previous == nil, ids?.contains(item.id) == true {
                    reader.scrollTo(item.id, anchor: .center)
                    focusedEpisode = item.id
                }
            }
        }
        .focusSection()
    }

    private func episodeRow(_ episode: Item, playing: Bool) -> some View {
        let date = parseDate(episode.premiereDate)?.formatted(.dateTime.month(.abbreviated).day().year().locale(AppLanguage.locale))
        let duration = episode.timeLeft ?? episode.runtimeMinutes.map { L("%ldm", $0) }
        let title = episode.indexNumber.map { "\($0). \(episode.name ?? episode.displayTitle)" } ?? episode.displayTitle
        return HStack(alignment: .top, spacing: Theme.px(12)) {
            RemoteImage(url: session.client?.still(episode, height: 180))
                .frame(width: Theme.px(128), height: Theme.px(72))
                .overlay(alignment: .bottomLeading) {
                    if let percent = episode.userData?.playedPercentage, !playing, episode.userData?.played != true, percent > 0 {
                        Rectangle().fill(Theme.ring)
                            .frame(width: Theme.px(128) * CGFloat(min(percent, 100)) / 100, height: Theme.px(3))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.px(8)))
            VStack(alignment: .leading, spacing: Theme.px(4)) {
                Text(title).font(Theme.font(Theme.sm, .semibold)).lineLimit(2)
                Text(playing ? L("Playing") : [date, duration].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.font(Theme.xs)).opacity(playing ? 1 : 0.72)
                    .lineLimit(1)
            }
        }
        .padding(Theme.px(7))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadSeasons() async {
        guard let client = session.client, let userId = session.userId, let series = item.seriesId else { return }
        let result: ItemsResult? = try? await client.get("/Shows/\(series)/Seasons", ["userId": userId])
        if !Task.isCancelled { seasons = result?.items ?? [] }
    }

    private func loadEpisodes(_ season: String?) async {
        guard let client = session.client, let userId = session.userId, let series = item.seriesId else { return }
        episodes = nil
        failed = false
        let result: ItemsResult? = try? await client.get("/Shows/\(series)/Episodes", ["userId": userId, "SeasonId": season])
        guard !Task.isCancelled, season == seasonID else { return }
        if let result {
            episodes = result.items ?? []
        } else {
            failed = true
        }
    }
}

private struct EpisodeDrawerRowStyle: ButtonStyle {
    let playing: Bool

    func makeBody(configuration: Configuration) -> some View {
        Focused { focused in
            configuration.label
                .foregroundStyle(focused ? Color.black : Color.white)
                .background(Color.white.opacity(focused ? 0.94 : playing ? 0.15 : 0),
                            in: RoundedRectangle(cornerRadius: Theme.px(8)))
                .opacity(configuration.isPressed ? 0.8 : 1)
        }
    }
}
