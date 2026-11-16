import SwiftUI

// The web app's item menu (components/item-menu.tsx), which a TV opens by holding select
// on a card: play, go to the show or open the title, watched, watched up to here, remove
// from Continue watching, and favourite.

extension Notification.Name {
    /// Watched or favourite state changed, so pages showing it load again.
    static let watchStateChanged = Notification.Name("aiostreams.watchStateChanged")
}

private struct PlayItemKey: EnvironmentKey {
    static let defaultValue: (Item, PlayMode) -> Void = { _, _ in }
}

private struct OpenRouteKey: EnvironmentKey {
    static let defaultValue: (Route) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Plays a title from anywhere: its versions, or one straight away, then the player.
    var playItem: (Item, PlayMode) -> Void {
        get { self[PlayItemKey.self] }
        set { self[PlayItemKey.self] = newValue }
    }

    /// Opens a page on the current place's stack.
    var openRoute: (Route) -> Void {
        get { self[OpenRouteKey.self] }
        set { self[OpenRouteKey.self] = newValue }
    }
}

struct ItemMenu: ViewModifier {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @Environment(\.playItem) private var play
    @Environment(\.openRoute) private var openRoute
    @Environment(\.removeFromPlaylist) private var removeFromPlaylist
    let item: Item
    @State private var adding = false
    @State private var choosingDevice = false
    @State private var choosingEpisode = false
    @State private var randomEpisode: Item?
    var continueWatching = false
    /// On the title's own page, where Open would lead nowhere.
    var onPage = false

    private var played: Bool { item.userData?.played == true }

    /// Whether Play would start a version without listing them.
    private var playsStraight: Bool {
        if continueWatching && item.isEpisode { return false }
        return prefs.autoPlayFirst || (item.resumeMs != nil && LastVersions.get(item.id) != nil)
    }
    private var favourite: Bool { item.userData?.isFavorite == true }

    func body(content: Content) -> some View {
        content.contextMenu {
            Section {
                if item.playable {
                    Button { play(item, continueWatching && item.isEpisode ? .list : .usual) } label: {
                        Label(item.resumeMs != nil ? L("Resume") : L("Play"), systemImage: "play.fill")
                    }
                    // The other way to start, as holding Play does in the web app.
                    if playsStraight {
                        Button { play(item, .list) } label: {
                            Label(L("Choose a version"), systemImage: "list.bullet")
                        }
                    } else {
                        Button { play(item, .straight) } label: {
                            Label(L("Play straight away"), systemImage: "forward.end")
                        }
                    }
                }
                if continueWatching && item.playable {
                    Button { choosingDevice = true } label: {
                        Label(L("Play on another device"), systemImage: "airplay.video")
                    }
                }
                if item.playable || item.isSeries {
                    Button { adding = true } label: { Label(L("Add to playlist"), systemImage: "text.badge.plus") }
                }
                if item.isSeries {
                    Button { choosingEpisode = true } label: {
                        Label(L("Random episode"), systemImage: "shuffle")
                    }
                }
                if item.isEpisode, let seriesId = item.seriesId {
                    Button {
                        openRoute(.item(Item(id: seriesId, name: item.seriesName, type: "Series")))
                    } label: {
                        Label(L("Go to show"), systemImage: "tv")
                    }
                } else if !onPage {
                    Button {
                        openRoute(item.isFolder ? .library(item) : .item(item))
                    } label: {
                        Label(L("Open"), systemImage: "info.circle")
                    }
                }
            } header: {
                Text(item.seriesName ?? item.name ?? item.displayTitle)
            }
            if item.type != "BoxSet" {
                // Watched before but started again: marking it watched finishes this time through.
                if !played || (!continueWatching && item.resumeMs != nil) {
                    Button {
                        act { client, userId in
                            try await client.call("POST", "/UserPlayedItems/\(item.id)", ["userId": userId])
                        }
                    } label: {
                        Label(L("Mark watched"), systemImage: "checkmark")
                    }
                }
                if played {
                    Button {
                        act { client, userId in
                            try await client.call("DELETE", "/UserPlayedItems/\(item.id)", ["userId": userId])
                        }
                    } label: {
                        Label(L("Mark unwatched"), systemImage: "arrow.uturn.backward")
                    }
                }
                if item.isEpisode, item.seriesId != nil {
                    Button {
                        act { client, userId in try await markUpTo(client: client, userId: userId) }
                    } label: {
                        Label(L("Mark watched up to here"), systemImage: "checkmark.circle")
                    }
                }
                if item.resumeMs != nil {
                    Button {
                        act { client, userId in
                            let _: UserData? = try await client.post(
                                "/UserItems/\(item.id)/UserData",
                                ["userId": userId],
                                body: ["PlaybackPositionTicks": 0]
                            )
                        }
                    } label: {
                        Label(L("Remove from continue watching"), systemImage: "arrow.counterclockwise")
                    }
                }
            }
            if favourite || item.type == "Movie" || item.isSeries {
                Button {
                    act { client, userId in
                        try await client.call(favourite ? "DELETE" : "POST", "/UserFavoriteItems/\(item.id)", ["userId": userId])
                    }
                } label: {
                    Label(favourite ? L("Remove favourite") : L("Add favourite"), systemImage: favourite ? "heart.slash" : "heart")
                }
            }
            if let removeFromPlaylist {
                Button(role: .destructive) { removeFromPlaylist(item) } label: {
                    Label(L("Remove from playlist"), systemImage: "minus.circle")
                }
            }
        }
        .fullScreenCover(isPresented: $choosingEpisode, onDismiss: {
            guard let episode = randomEpisode else { return }
            randomEpisode = nil
            play(episode, .list)
        }) {
            RandomEpisodePicker(series: item) { episode in
                randomEpisode = episode
                choosingEpisode = false
            }
            .environmentObject(session)
            .environmentObject(prefs)
        }
        .fullScreenCover(isPresented: $choosingDevice) {
            ItemRemotePicker(item: item) { choosingDevice = false }
                .environmentObject(session)
        }
        .fullScreenCover(isPresented: $adding) {
            AddToPlaylist(item: item) { adding = false }
                .environmentObject(session)
                .presentationBackground(.clear)
        }
    }

    private func act(_ change: @escaping (JellyfinClient, String) async throws -> Void) {
        guard let client = session.client, let userId = session.userId else { return }
        Task {
            do {
                try await change(client, userId)
            } catch {
                AppLog.warn("menu", "\(error.localizedDescription)")
            }
            NotificationCenter.default.post(name: .watchStateChanged, object: nil)
        }
    }

    /// The server's own endpoint where it has one; otherwise each aired episode up to this one.
    private func markUpTo(client: JellyfinClient, userId: String) async throws {
        do {
            try await client.call("POST", "/AIOStreams/PlayedUpTo/\(item.id)")
            return
        } catch let failure as JellyfinError where failure.status == 404 || failure.status == 405 {
            // An older server: mark them one by one.
        }
        guard let seriesId = item.seriesId else { return }
        let all: ItemsResult = try await client.get("/Shows/\(seriesId)/Episodes", ["userId": userId])
        let season = item.parentIndexNumber ?? 0
        let episode = item.indexNumber ?? 0
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wanted = (all.items ?? []).filter { candidate in
            guard candidate.userData?.played != true,
                  let s = candidate.parentIndexNumber, let e = candidate.indexNumber else { return false }
            let upTo = s == season ? e <= episode : (season > 0 && s > 0 && s < season)
            let aired = candidate.premiereDate.flatMap { iso.date(from: $0) }.map { $0 <= now } ?? true
            return upTo && aired
        }
        for candidate in wanted {
            try await client.call("POST", "/UserPlayedItems/\(candidate.id)", ["userId": userId])
        }
    }
}

extension View {
    func itemMenu(_ item: Item, onPage: Bool = false, continueWatching: Bool = false) -> some View {
        modifier(ItemMenu(item: item, continueWatching: continueWatching, onPage: onPage))
    }

    /// Loads again when a menu changes what's watched or favourite.
    func reloadOnWatchChange(_ action: @escaping () async -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: .watchStateChanged)) { _ in
            Task { await action() }
        }
    }
}


/// Lists other Jellyfin sessions that can accept the web app's PlayNow command.
private struct ItemRemotePicker: View {
    private struct Device: Decodable, Identifiable {
        let id: String
        let deviceId: String?
        let deviceName: String?
        let client: String?
        let supportsRemoteControl: Bool?
        let playableMediaTypes: [String]?
    }

    @EnvironmentObject private var session: Session
    @State private var devices: [Device]?
    @State private var error: String?
    @State private var sending = false
    let item: Item
    let close: () -> Void

    var body: some View {
        VStack(spacing: Theme.px(18)) {
            Text(L("Play on another device")).font(Theme.font(Theme.xl, .semibold))
            if let devices {
                if devices.isEmpty {
                    Text(L("No devices available"))
                } else {
                    ScrollView {
                        VStack(spacing: Theme.px(8)) {
                            ForEach(devices) { device in
                                Button(device.deviceName ?? device.client ?? L("Device")) {
                                    Task { await play(on: device) }
                                }
                                .buttonStyle(SoftPillStyle())
                                .disabled(sending)
                            }
                        }
                    }
                }
            } else if error == nil {
                ProgressView()
            }
            if let error { Text(error).foregroundStyle(Theme.gray300) }
            Button(L("Back"), action: close).buttonStyle(SoftPillStyle())
        }
        .frame(maxWidth: Theme.px(480), maxHeight: Theme.px(360))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand(perform: close)
        .task {
            guard let client = session.client, let userId = session.userId else { return }
            do {
                let found: [Device] = try await client.get("/Sessions", ["ControllableByUserId": userId])
                devices = found.filter {
                    $0.supportsRemoteControl == true && $0.playableMediaTypes?.contains("Video") == true
                        && $0.deviceId?.lowercased() != client.deviceId.lowercased()
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func play(on device: Device) async {
        guard !sending, let client = session.client else { return }
        sending = true
        error = nil
        defer { sending = false }
        do {
            try await client.call("POST", "/Sessions/\(device.id)/Playing", [
                "playCommand": "PlayNow", "itemIds": item.id,
                "startPositionTicks": String(max(0, item.userData?.playbackPositionTicks ?? 0)),
            ])
            close()
        } catch { self.error = error.localizedDescription }
    }
}
