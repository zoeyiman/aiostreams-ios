import SwiftUI

@MainActor
final class LivePreview: ObservableObject {
    @Published private(set) var model: PlayerModel?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var surfaceID = UUID()
    private var generation = UUID()

    func play(_ channel: Item, session: Session, prefs: Preferences, force: Bool = false) async {
        if !force, model?.request.item.id == channel.id { return }
        stop()
        guard let client = session.client, let userId = session.userId else { return }
        let current = generation
        loading = true
        error = nil
        defer { if current == generation { loading = false } }
        do {
            let info = try await client.playbackInfo(userId: userId, itemId: channel.id)
            try Task.checkCancellation()
            guard let source = info.mediaSources?.first(where: { $0.aiostreams?.ytId == nil }) else {
                throw JellyfinError(status: 0, message: "This channel has no playable stream.")
            }
            let named = try await client.playbackInfo(userId: userId, itemId: channel.id, sourceId: source.ownId)
            try Task.checkCancellation()
            guard current == generation else { return }
            let selected = named.mediaSources?.first(where: { $0.ownId == source.ownId }) ?? named.mediaSources?.first ?? source
            let request = PlayRequest(item: channel, source: selected,
                                      playSessionId: named.playSessionId ?? info.playSessionId, startMs: nil)
            let player = PlayerModel(request: request, client: client,
                                     audioLanguages: prefs.audioLanguages, subtitleLanguages: prefs.subtitleLanguages,
                                     look: prefs.subtitleLook, speakers: prefs.speakers, userId: userId)
            model = player
            player.start()
        } catch is CancellationError {
        } catch { if current == generation { self.error = error.localizedDescription } }
    }

    func stop() {
        generation = UUID()
        loading = false
        model?.stop()
        model = nil
    }
}

/// The preview and full-screen player share one PlayerModel; expanding never starts a second stream.
struct LivePreviewSurface: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        ZStack {
            VideoSurface(model: model)
            if model.waiting && model.failure == nil { ProgressView() }
            if let failure = model.failure {
                Text(failure).font(Theme.font(Theme.base)).multilineTextAlignment(.center)
                    .padding(Theme.px(24)).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.8))
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.px(16)))
    }
}

struct LivePreviewActions: View {
    @ObservedObject var model: PlayerModel
    let expand: () -> Void
    let retry: () -> Void

    var body: some View {
        if model.failure == nil {
            Button(action: expand) {
                Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(PrimaryPillStyle())
        } else {
            Button("Retry channel", action: retry).buttonStyle(PrimaryPillStyle())
        }
    }
}

struct LiveChannelTile: View {
    @EnvironmentObject private var prefs: Preferences
    let channel: Item
    let slots: (now: Slot?, next: Slot?)
    let now: Date
    let selected: Bool
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: Theme.px(12)) {
                if let number = channel.channelNumber {
                    Text(number).font(Theme.font(Theme.xs)).monospacedDigit()
                        .foregroundStyle(Theme.gray400).frame(width: Theme.px(42))
                }
                ChannelLogo(channel: channel).frame(width: Theme.px(64), height: Theme.px(44))
                VStack(alignment: .leading, spacing: Theme.px(4)) {
                    HStack {
                        Text(channel.name ?? "Channel").font(Theme.font(Theme.base, .semibold)).lineLimit(1)
                        if selected { Image(systemName: "speaker.wave.2.fill").font(.system(size: Theme.px(12))) }
                    }
                    if let current = slots.now {
                        Text(current.name).font(Theme.font(Theme.sm)).foregroundStyle(Theme.gray200).lineLimit(1)
                        ProgressView(value: airedShare(from: current.start, to: current.end, now: now))
                            .tint(.white)
                    }
                    if let next = slots.next {
                        Text((next.start.map { prefs.time($0) + "  " } ?? "") + next.name)
                            .font(Theme.font(Theme.xs)).foregroundStyle(Theme.gray400).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Theme.px(12))
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(.white.opacity(selected ? 0.12 : 0.02)))
        }
        .buttonStyle(RowStyle())
        .accessibilityLabel([channel.channelNumber, channel.name, slots.now?.name].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(selected ? "Open full screen" : "Play in preview")
    }
}
