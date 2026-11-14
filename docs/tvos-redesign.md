# Apple TV navigation and collections

The sidebar defaults to Home, Live TV, My Library, Search and Settings. In **Settings →
Sidebar**, toggle Live TV, My Library, Search, Discover, Playlists, Calendar and Activity
individually. Home and Settings always stay available. Reset sidebar restores the default
five pages. Visibility is saved locally per server and signed-in user and survives relaunch;
these native settings do not change the web app's navigation. Enabled pages scroll when the
list exceeds the screen height. Hidden start pages fall back to Home. Playlists opens the
server's playlists and their on-demand video titles; it does not mix live channels into title grids.

Select the sidebar
control above Home to switch between labels and icons; the preference survives relaunch.
Swipe up/down through destinations, right into the current page, or left to collapse.
At a page root, Menu/Back focuses the sidebar, then collapses it if expanded. A further
Back returns to Home; on Home it yields to tvOS, respecting Prevent accidental exit.
Detail screens, sheets and playback retain their own Back handling first.

Watchlist and Favorites use the same Jellyfin `UserFavoriteItems` collection. Existing
favorites therefore appear without migration. Both context-menu add actions save the
same title; Remove from saved titles clears that state for both. Requests are serialized
per title, update the UI only after success, and surface failures. This is a tvOS UI
change; it does not add a second watchlist to the server or modify the iOS web bundle.

My Library places Saved titles before Recommended for you. Recommendations interleave
up to eight distinct saved/viewed seeds, normalize episodes to their show, and rank
similar movies and shows by how many seed results contain them. Both completed and
in-progress on-demand history contribute. Saved titles, watched titles/shows, channels,
and live programmes are excluded from the candidate list. Empty accounts get an
explanation instead of unrelated recommendations. Recommendation failures preserve the
saved section and offer a retry.

Media cards share a focus ring, lift, shadow, corner radius and spacing. Reduce Motion
disables card scaling and automatic hero rotation. Grids adapt to sidebar width. The
hero uses full-width cinematic artwork with directional gradients for legible text.

Recently Watched belongs exclusively to Live TV. One selection starts a channel directly.
Only a channel request that reaches playing with a ready first frame is recorded; loading,
failed starts, trailers and buffering alone do not count. The newest channel moves to the
front, duplicates are removed, and up to 30 IDs persist per server and user on this Apple TV.
The old unscoped `live.recent` key is intentionally not imported, since it cannot be safely
attributed to a server/user. Live history never supplies Home or Library rows or recommendation
seeds. Saved state syncs through the server; channel history stays local to this Apple TV.

## Validation on macOS

The Linux workspace can parse Swift syntax but cannot build SwiftUI/tvOS or run Xcode tests.
On a Mac with the README prerequisites installed:

```sh
scripts/build-web.sh
xcodegen generate
xcodebuild -showdestinations -project AIOStreams.xcodeproj -scheme AIOStreamsTV
xcodebuild test -project AIOStreams.xcodeproj -scheme AIOStreamsTV \
  -destination 'platform=tvOS Simulator,id=<available-simulator-UUID>' \
  CODE_SIGNING_ALLOWED=NO
```

`AIOStreamsTVTests` covers the five destinations, on-demand eligibility, recommendation
signals/exclusions/ranking, playback-success gating, recent-channel deduplication/limit,
and persisted history isolation. These tests still need execution on macOS.

On a paired Apple TV, also verify:

- Enable Activity and Playlists in Settings → Sidebar, disable them, and relaunch; verify
  visibility persists and Reset sidebar restores the five defaults. Check scrolling with
  all destinations enabled and that Home/Settings cannot be hidden.
- Expand/collapse, relaunch persistence, directional focus from every destination, and
  Back through details, player, sidebar, Home and system exit.
- Save via each context-menu label, then remove from My Library. Check the detail
  button, bookmark badge and both menu states, including after relaunch. Try a failed
  save with the server unavailable; the title must keep its previous state.
- Confirm saved titles appear above recommendations, including with an empty saved
  list but existing on-demand history. A failed recommendations request must preserve saves.
- Start two channels, revisit the first, and verify newest-first order after relaunch.
  Cancel or fail a third channel before playback; it must not enter Recently Watched.
- Confirm those channels never appear in Home, My Library or recommendations; switch
  server/user and verify that local channel history is isolated.
- Check focus rings and hero text at both sidebar widths, with Reduce Motion and VoiceOver.
