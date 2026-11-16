import AVFoundation
import Combine
import SwiftUI

// Focus previews follow AIOStreams' card-preview.tsx: widen the card in the row, show its
// artwork, then bring in the trailer and let the title details fade.
enum CardPreviewTiming {
    static let rest: Duration = .milliseconds(1200)
    static let trailer: Duration = .milliseconds(1500)
    static let details: Duration = .seconds(3)
}

enum CardPreviewLayout {
    /// scrollTo aligns the same fraction of the card and viewport. Leave space for the focus ring.
    static func revealAnchor(cardWidth: CGFloat, viewportWidth: CGFloat, margin: CGFloat) -> CGFloat? {
        let spare = viewportWidth - cardWidth
        guard cardWidth > 0, spare > 0, spare >= 2 * margin else { return nil }
        return 1 - margin / spare
    }
}

struct CardPreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var prefs: Preferences
    let item: Item
    let size: CGSize

    @State private var player: AVPlayer?
    @State private var frameReady = false
    @State private var hideDetails = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: session.client?.backdrop(item, height: Int(size.height * 2))
                        ?? session.client?.still(item, height: Int(size.height * 2)))
            if let player {
                TrailerLayer(player: player, ready: $frameReady)
                    .id(ObjectIdentifier(player))
                    .opacity(frameReady ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: frameReady)
                    .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification,
                                                                    object: player.currentItem)) { _ in
                        stopTrailer()
                    }
            }
            LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .bottom, endPoint: .center)
                .opacity(hideDetails ? 0 : 1)
            VStack(alignment: .leading, spacing: Theme.px(4)) {
                TitleLogo(item: item, maxHeight: Theme.px(44), maxWidth: size.width * 0.6, titleSize: 22)
                HeroMeta(item: item)
                    .font(Theme.font(Theme.xs))
            }
            .padding(Theme.px(12))
            .opacity(hideDetails ? 0 : 1)
        }
        .frame(width: size.width, height: size.height)
        .task(id: prefs.cardTrailers) {
            if prefs.cardTrailers {
                await startTrailer()
            } else {
                stopTrailer()
            }
        }
        .task(id: frameReady) {
            guard frameReady else { hideDetails = false; return }
            try? await Task.sleep(for: CardPreviewTiming.details)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { hideDetails = true }
        }
        .onChange(of: prefs.trailerSound) { _, sound in player?.isMuted = !sound }
        .onDisappear { stopTrailer() }
    }

    private func startTrailer() async {
        // Request the trailers while the expanded card is showing its artwork.
        async let trailers = loadTrailers()
        try? await Task.sleep(for: CardPreviewTiming.trailer)
        for trailer in await trailers {
            guard !Task.isCancelled else { return }
            guard let url = await trailerURL(trailer), !Task.isCancelled else { continue }
            let candidate = AVPlayer(url: url)
            candidate.isMuted = !prefs.trailerSound
            frameReady = false
            player = candidate
            candidate.play()

            // Reveal only after the video layer has a frame. Try another trailer if one fails.
            for _ in 0..<80 {
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { candidate.pause(); return }
                if player !== candidate || frameReady { return }
                if candidate.currentItem?.status == .failed { break }
            }
            stopTrailer()
        }
    }

    private func loadTrailers() async -> [RemoteTrailer] {
        if let known = item.remoteTrailers, !known.isEmpty { return known }
        guard let client = session.client, let userId = session.userId else { return [] }
        for id in [item.id, item.seriesId].compactMap({ $0 }) {
            guard !Task.isCancelled else { return [] }
            let found: ItemsResult? = try? await client.get("/Items", ["userId": userId, "Ids": id, "Fields": "RemoteTrailers"])
            if let trailers = found?.items?.first?.remoteTrailers, !trailers.isEmpty { return trailers }
        }
        return []
    }

    private func stopTrailer() {
        player?.pause()
        player = nil
        frameReady = false
        hideDetails = false
    }

    private func trailerURL(_ trailer: RemoteTrailer) async -> URL? {
        if let id = trailer.youTubeId {
            let stream: YouTube.Stream? = await withCheckedContinuation { done in
                YouTube.resolve(id) { done.resume(returning: $0) }
            }
            return stream.flatMap { URL(string: $0.url) }
        }
        guard let text = trailer.url, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }
}

/// A video layer that reports when its first picture can replace the backdrop.
private struct TrailerLayer: UIViewRepresentable {
    let player: AVPlayer
    @Binding var ready: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        let coordinator = context.coordinator
        let ready = $ready
        view.clipsToBounds = true
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        coordinator.observation = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { _, change in
            guard change.newValue == true else { return }
            DispatchQueue.main.async { [weak coordinator] in
                if coordinator?.observation != nil { ready.wrappedValue = true }
            }
        }
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {}

    static func dismantleUIView(_ view: LayerView, coordinator: Coordinator) {
        coordinator.observation = nil
        view.playerLayer.player = nil
    }

    final class Coordinator {
        var observation: NSKeyValueObservation?
    }

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
