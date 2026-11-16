import SwiftUI

/// How Play picks a version: as the settings say, by listing them, or by starting the first.
enum PlayMode {
    case usual, list, straight
}

/// Something to play: an item, from where it would start. A show plays its next episode.
struct VersionChoice: Identifiable {
    let id = UUID()
    let item: Item
    let startMs: Double?
    var mode: PlayMode = .usual
    /// What plays on after it, from a playlist, in place of a show's next episode.
    var queue: [Item] = []
}

/// The version each title last played in, kept on this device, which resuming goes back to.
enum LastVersions {
    private static let key = "playback.lastVersions"
    private static let releasesKey = "playback.lastReleases"
    private static let limit = 500

    static func get(_ itemId: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[itemId]
    }

    static func set(_ itemId: String, _ source: MediaSource) {
        store(key, itemId, source.ownId)
        if let release = source.aiostreams?.release { store(releasesKey, itemId, release) }
    }

    /// The version last played: by its id, else (as the web app does since server v2.38) the one
    /// with its release, which keeps when the version's id doesn't.
    static func find(_ itemId: String, in sources: [MediaSource]) -> MediaSource? {
        if let id = get(itemId), let same = sources.first(where: { $0.ownId == id }) { return same }
        guard let release = (UserDefaults.standard.dictionary(forKey: releasesKey) as? [String: String])?[itemId] else { return nil }
        return sources.first { $0.aiostreams?.release == release }
    }

    private static func store(_ name: String, _ itemId: String, _ value: String) {
        var all = (UserDefaults.standard.dictionary(forKey: name) as? [String: String]) ?? [:]
        all[itemId] = value
        if all.count > limit { all.removeValue(forKey: all.keys.first { $0 != itemId }!) }
        UserDefaults.standard.set(all, forKey: name)
    }
}

/// Lists a choice's versions, or starts one straight away, then plays it over whatever screen asked.
/// As the web app's picker does: Play starts the first version when "Auto-play the first version" is on,
/// and resuming goes back to the version that was playing; otherwise Play lists them.
struct PlayFlow: ViewModifier {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var wash: ArtWash
    @Binding var choice: VersionChoice?
    var finished: () -> Void = {}
    /// The one flow, the app's own, that opens the player again from Picture in Picture.
    var restoresPictureInPicture = false
    var playerVisibility: (Bool) -> Void = { _ in }

    @State private var playing: PlayRequest?
    /// The model Picture in Picture hands back, for the player opened again on it.
    @State private var restored: PlayerModel?
    @ObservedObject private var pictureInPicture = TVPictureInPicture.shared
    @ObservedObject private var follow = PartyFollow.shared
    /// The party's next title, opened once the player before it has closed.
    @State private var partyNext: PlayRequest?
    /// Waits for the version sheet to close, as one screen can't open over another closing.
    @State private var pendingPlay: PlayRequest?
    /// The title a version is being found for, without the list.
    @State private var finding: Item?
    /// An episode the player played on to, whose versions are listed once the player has closed.
    @State private var listAfterPlayer: VersionChoice?

    private func straight(_ choice: VersionChoice) -> Bool {
        switch choice.mode {
        case .list: return false
        case .straight: return true
        case .usual:
            return prefs.autoPlayFirst || ((choice.startMs ?? 0) > 0 && LastVersions.get(choice.item.id) != nil)
        }
    }

    /// The list, for a choice that isn't played straight away.
    private var listed: Binding<VersionChoice?> {
        Binding(
            get: { choice.flatMap { straight($0) ? nil : $0 } },
            set: { choice = $0 }
        )
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let finding {
                    HStack(spacing: Theme.px(12)) {
                        ProgressView()
                        Text(L("Finding a version of %@…", finding.isEpisode ? finding.displayTitle : finding.name ?? L("this")))
                            .font(Theme.font(Theme.base, .medium))
                    }
                    .padding(.horizontal, Theme.px(20))
                    .padding(.vertical, Theme.px(12))
                    .background(Capsule().fill(Color(white: 17 / 255).opacity(0.95)))
                    .padding(.bottom, Theme.px(40))
                    .transition(.opacity)
                }
            }
            .onChange(of: pictureInPicture.restoring?.request.id) { _, _ in
                guard restoresPictureInPicture, let model = pictureInPicture.restoring, playing == nil else { return }
                restored = model
                playing = model.request
            }
            // A watch party's title, which the party opens on this Apple TV.
            .onChange(of: follow.open?.id) { _, _ in
                guard restoresPictureInPicture, let request = follow.open else { return }
                follow.open = nil
                if playing == nil { playing = request } else { partyNext = request }
            }
            .onChange(of: choice?.id) { _, _ in
                guard let choice, straight(choice) else { return }
                self.choice = nil
                Task { await playStraight(choice) }
            }
            .fullScreenCover(item: listed, onDismiss: {
                if let request = pendingPlay {
                    pendingPlay = nil
                    present(request)
                }
            }) { choice in
                VersionsView(choice: choice) { request in
                    LastVersions.set(request.item.id, request.source)
                    pendingPlay = request
                    self.choice = nil
                }
                .environmentObject(session)
                .environmentObject(prefs)
                .environmentObject(wash)
                // The page stays in sight, dimmed, behind the panel.
                .presentationBackground(.clear)
            }
            .onChange(of: playing != nil) { _, visible in playerVisibility(visible) }
            .fullScreenCover(item: $playing, onDismiss: {
                restored = nil
                if let next = partyNext {
                    partyNext = nil
                    playing = next
                    return
                }
                if let next = listAfterPlayer {
                    listAfterPlayer = nil
                    choice = next
                }
            }) { request in
                PlayerScreen(request: request, existing: restored?.request.id == request.id ? restored : nil, close: {
                    playing = nil
                    finished()
                }, listVersions: { item in
                    listAfterPlayer = VersionChoice(item: item, startMs: item.userData?.played == true ? nil : item.resumeMs, mode: .list)
                })
                .environmentObject(session)
                .environmentObject(prefs)
            }
    }

    /// The player for a title; in a watch party, the title starts for everyone instead, and the party
    /// opens it here as it does for the others.
    private func present(_ request: PlayRequest) {
        if WatchParty.shared.live, !request.isTrailer, !request.item.isChannel, request.partyEntry == nil {
            PartyFollow.shared.playForParty(request)
        } else {
            playing = request
        }
    }

    /// The version that was playing, else the first; the list where there's none to play.
    private func playStraight(_ choice: VersionChoice) async {
        guard let client = session.client, let userId = session.userId else { return }
        finding = choice.item
        defer { finding = nil }
        let info = try? await client.playbackInfo(userId: userId, itemId: choice.item.id)
        let sources = (info?.mediaSources ?? []).filter { $0.aiostreams?.ytId == nil }
        let last = (choice.startMs ?? 0) > 0 ? LastVersions.find(choice.item.id, in: sources) : nil
        guard let source = last ?? sources.first else {
            self.choice = VersionChoice(item: choice.item, startMs: choice.startMs, mode: .list)
            return
        }
        // Named again, the version brings its subtitles from the configuration's subtitle addons.
        var chosen = source
        var playSession = info?.playSessionId
        if let named = try? await client.playbackInfo(userId: userId, itemId: choice.item.id, sourceId: source.ownId),
           let match = named.mediaSources?.first(where: { $0.ownId == source.ownId }) ?? named.mediaSources?.first {
            chosen = match
            playSession = named.playSessionId ?? playSession
        }
        LastVersions.set(choice.item.id, chosen)
        present(PlayRequest(item: choice.item, source: chosen, playSessionId: playSession, startMs: choice.startMs, queue: choice.queue))
    }

}

extension View {
    func playFlow(_ choice: Binding<VersionChoice?>, restoresPictureInPicture: Bool = false,
                  playerVisibility: @escaping (Bool) -> Void = { _ in },
                  finished: @escaping () -> Void = {}) -> some View {
        modifier(PlayFlow(choice: choice, finished: finished, restoresPictureInPicture: restoresPictureInPicture,
                          playerVisibility: playerVisibility))
    }
}

/// What playing a title means: a show's next episode, else the title from where it stopped.
@MainActor
func playChoice(for item: Item, session: Session, mode: PlayMode = .usual) async -> VersionChoice? {
    guard item.isSeries else { return VersionChoice(item: item, startMs: item.resumeMs, mode: mode) }
    guard let client = session.client, let userId = session.userId else { return nil }
    let next: ItemsResult? = try? await client.get("/Shows/NextUp", ["userId": userId, "SeriesId": item.id, "Limit": "1"])
    if let episode = next?.items?.first { return VersionChoice(item: episode, startMs: episode.resumeMs, mode: mode) }
    let first: ItemsResult? = try? await client.get("/Shows/\(item.id)/Episodes", ["userId": userId, "Limit": "1"])
    return first?.items?.first.map { VersionChoice(item: $0, startMs: nil, mode: mode) }
}

/// Lets a page switch the rail's place.
private struct OpenPlaceKey: EnvironmentKey {
    static let defaultValue: (Place) -> Void = { _ in }
}

extension EnvironmentValues {
    var openPlace: (Place) -> Void {
        get { self[OpenPlaceKey.self] }
        set { self[OpenPlaceKey.self] = newValue }
    }
}

/// What the player is asked to play: an item, from a position, in a chosen version.
struct PlayRequest: Identifiable {
    let id = UUID()
    let item: Item
    let source: MediaSource
    let playSessionId: String?
    let startMs: Double?
    /// A title's trailer: played without telling the server, so the title's own progress is left alone.
    var isTrailer = false
    /// What plays on after it, from a playlist, in place of a show's next episode.
    var queue: [Item] = []
    /// Audio languages in place of the account's, as a trailer's own language stands in for Original.
    var audioLanguages: [String]?
    /// The watch party's title it plays, which the party's commands drive.
    var partyEntry: String?
}
