import SwiftUI

// Live TV reminders, as the web app has them (features/live-tv/live-reminders.tsx): a programme
// still to come is marked in the guide, and as it starts, while the app is open, the app asks
// whether to watch it. Kept on this Apple TV, for each user.

struct Reminder: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var start: Date
    var channelId: String
    var channelName: String
}

@MainActor
final class LiveReminders: ObservableObject {
    static let shared = LiveReminders()

    /// A reminder shows a minute before its programme, and is dropped ten minutes after its start.
    static let early: TimeInterval = 60
    static let late: TimeInterval = 600

    @Published private(set) var list: [Reminder] = []
    private var userId: String?

    private var key: String? { userId.map { "live.reminders.\($0)" } }

    func load(userId: String) {
        guard self.userId != userId else { return }
        self.userId = userId
        list = key.flatMap { UserDefaults.standard.data(forKey: $0) }
            .flatMap { try? JSONDecoder().decode([Reminder].self, from: $0) } ?? []
    }

    func isSet(_ programmeId: String) -> Bool { list.contains { $0.id == programmeId } }

    func toggle(_ programme: Item, on channel: Item) {
        if isSet(programme.id) {
            list.removeAll { $0.id == programme.id }
        } else if let start = programme.starts {
            list.append(Reminder(id: programme.id, title: programme.name ?? "", start: start,
                                 channelId: channel.id, channelName: channel.name ?? ""))
        }
        save()
    }

    /// The reminder due now, if any, which is taken off the list; past ones are dropped.
    func takeDue(now: Date = Date()) -> Reminder? {
        let due = list.first { $0.start.addingTimeInterval(-Self.early) <= now }
        list.removeAll { $0 == due || $0.start.addingTimeInterval(Self.late) < now }
        save()
        return due
    }

    private func save() {
        guard let key, let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// Asks whether to watch a programme as it starts, over whatever page is open.
struct ReminderHost: View {
    @EnvironmentObject private var prefs: Preferences
    @ObservedObject private var reminders = LiveReminders.shared
    let watch: (Item) -> Void
    @State private var due: Reminder?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            if let due {
                Color.black.opacity(0.6).ignoresSafeArea()
                VStack(alignment: .leading, spacing: Theme.px(14)) {
                    Text(due.title).font(Theme.font(Theme.xl, .semibold))
                    Text(L("%@ on %@", prefs.time(due.start), due.channelName))
                        .font(Theme.font(Theme.base))
                        .foregroundStyle(Theme.gray400)
                    HStack(spacing: Theme.px(8)) {
                        Button {
                            self.due = nil
                            watch(Item(id: due.channelId, name: due.channelName, type: "TvChannel"))
                        } label: {
                            Label(L("Watch"), systemImage: "play.fill")
                        }
                        .buttonStyle(SoftPillStyle(selected: true))
                        .focused($focused)
                        Button(L("Dismiss")) { self.due = nil }.buttonStyle(SoftPillStyle())
                    }
                    .padding(.top, Theme.px(6))
                }
                .padding(Theme.px(24))
                .frame(width: Theme.px(520), alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.px(16), style: .continuous).fill(Color(white: 17 / 255)))
                .overlay(RoundedRectangle(cornerRadius: Theme.px(16), style: .continuous).stroke(.white.opacity(0.1), lineWidth: Theme.px(1)))
                .focusSection()
                .onAppear { focused = true }
                .onExitCommand { self.due = nil }
            }
        }
        .task {
            while !Task.isCancelled {
                if due == nil, let next = reminders.takeDue() { due = next }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
}
