import SwiftUI

// Full-screen source selection keeps the episode summary alongside the stream list.

struct VersionsView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    let choice: VersionChoice
    let play: (PlayRequest) -> Void

    @State private var info: PlaybackInfo?
    @State private var episodeDetail: Item?
    @State private var series: Item?
    @State private var error: String?
    @State private var opening: String?
    @State private var fromStart = false
    @FocusState private var focusedVersion: String?

    private var item: Item { choice.item }
    private var resumeMs: Double? { (choice.startMs ?? 0) > 0 ? choice.startMs : nil }
    private var sources: [MediaSource] { info?.mediaSources ?? [] }

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: Theme.px(36)) {
                VStack(spacing: Theme.px(12)) {
                    header
                    list
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: sources.isEmpty ? .center : .top)
                }
                .frame(maxWidth: .infinity)

                summary
                    .frame(width: geometry.size.width * 0.32)
                    .padding(.top, Theme.px(22))
            }
            .padding(.horizontal, Theme.px(56))
            .padding(.vertical, Theme.px(44))
        }
        .background {
            ZStack {
                RemoteImage(url: session.client?.backdrop(item, height: 720))
                    .blur(radius: Theme.px(36))
                LinearGradient(colors: [Color(red: 0.12, green: 0.13, blue: 0.17).opacity(0.9),
                                        Color(red: 0.18, green: 0.19, blue: 0.24).opacity(0.95)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .ignoresSafeArea()
        }
        .foregroundStyle(.white)
        .task { await load(refresh: false) }
        .task(id: item.id) { await loadSummary() }
        .onExitCommand { dismiss() }
    }

    private var header: some View {
        VStack(spacing: Theme.px(12)) {
            ZStack {
                Text(L("Select Source"))
                    .font(Theme.font(Theme.xl, .semibold))
                HStack(spacing: Theme.px(10)) {
                    Button { dismiss() } label: {
                        Label(L("Back"), systemImage: "chevron.left")
                    }
                    .buttonStyle(SoftPillStyle())
                    Spacer()
                    Text(info == nil ? L("Finding versions") : L("%ld streams", sources.count))
                        .font(Theme.font(Theme.sm))
                        .foregroundStyle(Theme.gray200)
                    Button {
                        Task { await load(refresh: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(CircleIconStyle())
                    .accessibilityLabel(L("Refresh sources"))
                    .disabled(info == nil && error == nil)
                }
            }
            if let resumeMs {
                HStack(spacing: Theme.px(4)) {
                    Button(L("Resume from %@", clock(resumeMs))) { fromStart = false }
                        .buttonStyle(SegmentStyle(selected: !fromStart))
                    Button(L("From the start")) { fromStart = true }
                        .buttonStyle(SegmentStyle(selected: fromStart))
                }
                .padding(Theme.px(4))
                .background(Capsule().fill(.black.opacity(0.35)))
            }
        }
        .padding(.horizontal, Theme.px(10))
        .focusSection()
    }

    private var summary: some View {
        let detail = episodeDetail ?? item
        let minutes = detail.runtimeMinutes.map { L("%ldm", $0) }
        let rating = (detail.communityRating ?? series?.communityRating)
            .map { "★ " + $0.formatted(.number.precision(.fractionLength(1))) }
        let metadata = [minutes, rating, detail.genres?.first ?? series?.genres?.first].compactMap { $0 }
        return VStack(spacing: Theme.px(8)) {
            RemoteImage(url: summaryPoster)
                .frame(width: Theme.px(210), height: Theme.px(315))
                .clipShape(RoundedRectangle(cornerRadius: Theme.px(12)))
            Text(detail.seriesName ?? series?.name ?? detail.name ?? "")
                .font(Theme.font(Theme.xl, .bold))
                .lineLimit(2)
            if detail.isEpisode {
                Text(detail.displayTitle).font(Theme.font(Theme.base, .semibold)).lineLimit(2)
            }
            if !metadata.isEmpty {
                Text(metadata.joined(separator: " · "))
                    .font(Theme.font(Theme.sm, .medium))
                    .foregroundStyle(Theme.gray200)
            }
            if let overview = detail.overview ?? item.overview, !overview.isEmpty {
                Text(overview)
                    .font(Theme.font(Theme.sm))
                    .foregroundStyle(Theme.gray200)
                    .lineLimit(4)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var summaryPoster: URL? {
        guard let client = session.client else { return nil }
        if let series { return client.poster(series, height: 560) }
        if let id = item.seriesId {
            return client.image(id, .primary, tag: item.seriesPrimaryImageTag, height: 560)
        }
        return client.poster(item, height: 560)
    }

    private func loadSummary() async {
        guard let client = session.client, let userId = session.userId else { return }
        let ids = [item.id, item.seriesId].compactMap { $0 }.joined(separator: ",")
        let result: ItemsResult? = try? await client.get("/Items", [
            "userId": userId, "Ids": ids, "Fields": "Overview,Genres",
        ])
        guard !Task.isCancelled else { return }
        episodeDetail = result?.items?.first { $0.id == item.id }
        series = result?.items?.first { $0.id == item.seriesId }
    }

    @ViewBuilder private var list: some View {
        if !sources.isEmpty {
            ScrollView {
                LazyVStack(spacing: Theme.px(8)) {
                    ForEach(sources, id: \.ownId) { source in
                        Button {
                            Task { await open(source) }
                        } label: {
                            VersionCard(source: source, opening: opening == source.ownId)
                        }
                        .buttonStyle(VersionCardStyle())
                        .disabled(opening != nil)
                        .focused($focusedVersion, equals: source.ownId)
                    }
                }
                .padding(Theme.px(10))
            }
            .focusSection()
            .onAppear { focusedVersion = sources.first?.ownId }
        } else if let error {
            VStack(spacing: Theme.px(16)) {
                ErrorText(text: error)
                Button(L("Try again")) { Task { await load(refresh: true) } }.buttonStyle(SoftPillStyle())
            }
            .padding(Theme.px(40))
        } else if info != nil {
            VStack(spacing: Theme.px(16)) {
                Text(L("No playable versions found. Only streams with a link play: use debrid or Usenet."))
                    .font(Theme.font(Theme.base))
                    .foregroundStyle(Theme.gray400)
                    .multilineTextAlignment(.center)
                Button(L("Search again")) { Task { await load(refresh: true) } }.buttonStyle(SoftPillStyle())
            }
            .padding(Theme.px(40))
        } else {
            VStack(spacing: Theme.px(12)) {
                ProgressView().progressViewStyle(.linear).frame(width: Theme.px(200))
                Text(L("Searching your addons…")).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray400)
            }
            .padding(Theme.px(48))
        }
    }

    private func load(refresh: Bool) async {
        guard let client = session.client, let userId = session.userId else { return }
        error = nil
        if refresh { info = nil }
        do {
            var result: PlaybackInfo
            if !refresh, let started = VersionSearches.take(item.id), let found = try? await started.value {
                result = found
            } else {
                result = try await client.playbackInfo(userId: userId, itemId: item.id, refresh: refresh)
            }
            // Versions only the app's own player could open from YouTube aren't offered here.
            result.mediaSources = result.mediaSources?.filter { $0.aiostreams?.ytId == nil }
            info = result
            // A title's only version plays without being listed, as the web app does, unless the
            // list was asked for (Choose a version) or reloaded.
            if !refresh, choice.mode != .list, let only = sources.first, sources.count == 1 {
                await open(only)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Naming the version again gets its subtitles from the configuration's subtitle addons.
    private func open(_ source: MediaSource) async {
        guard let client = session.client, let userId = session.userId else { return }
        opening = source.ownId
        defer { opening = nil }
        var chosen = source
        var playSession = info?.playSessionId
        if let named = try? await client.playbackInfo(userId: userId, itemId: item.id, sourceId: source.ownId),
           let match = named.mediaSources?.first(where: { $0.ownId == source.ownId }) ?? named.mediaSources?.first {
            chosen = match
            playSession = named.playSessionId ?? playSession
        }
        play(PlayRequest(item: item, source: chosen, playSessionId: playSession, startMs: fromStart ? 0 : choice.startMs,
                         queue: choice.queue))
    }

    private func clock(_ ms: Double) -> String {
        let seconds = Int(ms / 1000)
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// A source's server-formatted description and a short row of technical details.
private struct VersionCard: View {
    let source: MediaSource
    let opening: Bool

    private var badges: [String] {
        let video = source.mediaStreams?.first { $0.type == "Video" }?.codec?.uppercased()
        let audio = source.mediaStreams?.first { $0.type == "Audio" }?.codec?.uppercased()
        return [source.aiostreams?.resolution, video, audio].compactMap { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(5)) {
            HStack(alignment: .top) {
                Text(source.label)
                    .font(Theme.font(Theme.base, .semibold))
                    .multilineTextAlignment(.leading)
                Spacer()
                if opening {
                    ProgressView().scaleEffect(0.65)
                } else if let size = source.aiostreams?.size ?? source.size, size > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(Theme.font(Theme.sm, .semibold))
                        .monospacedDigit()
                }
            }
            if let description = source.aiostreams?.description, !description.isEmpty {
                Text(description)
                    .font(Theme.font(Theme.sm))
                    .foregroundStyle(Theme.gray200)
                    .multilineTextAlignment(.leading)
            }
            if !badges.isEmpty {
                HStack(spacing: Theme.px(5)) {
                    ForEach(Array(badges.enumerated()), id: \.offset) { index, badge in
                        Text(badge)
                            .font(Theme.font(Theme.xs, .bold))
                            .padding(.horizontal, Theme.px(6))
                            .padding(.vertical, Theme.px(2))
                            .background((index == 0 && source.aiostreams?.resolution != nil ? Color.green : Color.white)
                                .opacity(0.25), in: RoundedRectangle(cornerRadius: Theme.px(4)))
                    }
                }
            }
        }
        .padding(Theme.px(14))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct VersionCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Card(label: configuration.label, pressed: configuration.isPressed)
    }

    private struct Card<Label: View>: View {
        @Environment(\.isFocused) private var focused
        let label: Label
        let pressed: Bool

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.px(12), style: .continuous)
            label
                .background(shape.fill(Color.white.opacity(focused ? 0.29 : 0.12)))
                .overlay(shape.stroke(Color.white.opacity(focused ? 0.8 : 0.04), lineWidth: Theme.px(1)))
                .opacity(pressed ? 0.85 : 1)
        }
    }
}

/// A half of the Resume / From the start toggle: white when chosen.
private struct SegmentStyle: ButtonStyle {
    var selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Segment(label: configuration.label, selected: selected)
    }

    private struct Segment<Label: View>: View {
        @Environment(\.isFocused) private var focused
        let label: Label
        let selected: Bool

        var body: some View {
            label
                .font(Theme.font(Theme.sm, .medium))
                .foregroundStyle(selected ? Color.black : Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.px(32))
                .background(Capsule().fill(selected ? Color.white : (focused ? Color.white.opacity(0.12) : Color.clear)))
                .focusRing(focused)
        }
    }
}

/// Version searches started before Play (Find versions when a title opens), which the version list
/// takes up rather than searching again; a search older than a few minutes is left to go stale.
@MainActor
enum VersionSearches {
    private static var started: [String: (at: Date, search: Task<PlaybackInfo, Error>)] = [:]
    private static let fresh: TimeInterval = 180

    static func start(_ itemId: String, client: JellyfinClient, userId: String) {
        if let existing = started[itemId], Date().timeIntervalSince(existing.at) < fresh { return }
        started = started.filter { Date().timeIntervalSince($0.value.at) < fresh }
        started[itemId] = (Date(), Task { try await client.playbackInfo(userId: userId, itemId: itemId) })
    }

    static func take(_ itemId: String) -> Task<PlaybackInfo, Error>? {
        guard let entry = started.removeValue(forKey: itemId), Date().timeIntervalSince(entry.at) < fresh else { return nil }
        return entry.search
    }
}

struct PlaybackVersionsPopup: View {
    @EnvironmentObject private var session: Session
    @FocusState private var focusedVersion: String?
    @State private var sources: [MediaSource]?
    @State private var failed = false
    let item: Item
    let activeID: String
    let close: () -> Void
    let choose: (MediaSource) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.px(10)) {
            HStack {
                Text(L("Versions")).font(Theme.font(Theme.lg, .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(CircleIconStyle())
                    .accessibilityLabel(L("Close"))
            }
            if let sources, !sources.isEmpty {
                ScrollView {
                    LazyVStack(spacing: Theme.px(6)) {
                        ForEach(sources, id: \.ownId) { source in
                            Button {
                                if source.ownId == activeID { close() } else { choose(source) }
                            } label: {
                                HStack(alignment: .top, spacing: 0) {
                                    VersionCard(source: source, opening: false)
                                    if source.ownId == activeID {
                                        Image(systemName: "checkmark").padding(Theme.px(14))
                                    }
                                }
                            }
                            .buttonStyle(VersionCardStyle())
                            .focused($focusedVersion, equals: source.ownId)
                            .accessibilityAddTraits(source.ownId == activeID ? .isSelected : [])
                        }
                    }
                }
                .frame(height: Theme.px(310))
            } else if failed || sources != nil {
                Text(failed ? L("Could not load versions.") : L("No versions available."))
                    .padding(.vertical, Theme.px(12))
            } else {
                ProgressView().progressViewStyle(.linear).padding(.vertical, Theme.px(12))
                    .accessibilityLabel(L("Finding versions"))
            }
        }
        .padding(Theme.px(16))
        .frame(width: Theme.px(435))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.px(18)))
        .focusSection()
        .task(id: item.id) {
            guard let client = session.client, let userId = session.userId else { failed = true; return }
            do {
                let info = try await client.playbackInfo(userId: userId, itemId: item.id)
                guard !Task.isCancelled else { return }
                sources = (info.mediaSources ?? []).filter { $0.aiostreams?.ytId == nil }
                // Use a visible row for initial focus even when the current stream is far down the list.
                focusedVersion = sources?.first?.ownId
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}
