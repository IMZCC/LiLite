# Runtime shell, lists, profile and shared artwork review

Review input: `native/ios` HEAD `2d16f01f5`, user feedback from an iPhone 15 Pro Max running iOS 27.3, and locally captured home/profile screenshots from the installed build. Personal screenshot contents are not copied into the repository.

## Confirmed paths and fixes

### Scroll progress invalidated the whole shell

`NavigationChrome.drag` wrote an `@Published fraction` on each pan update. `MainNavShell` owned that object through `@StateObject`, read the fraction itself, and injected its continuously changing value into the home page environment. This made default search-bar collapsing a dependency of the complete tab/page hierarchy.

`Settings/MainNavShell.swift` now uses Observation property tracking. Shell visibility and strip progress are separate dependencies; only `NavigationStrip` reads `fraction`. The home environment carries a stable `collapseHomeSearch` Boolean, consumed by `HomeSearchVisibility`. Native system-tab minimization continues to use UIKit; it does not also drive an unused custom bottom-bar fraction. Scroll-to-top, repeated-tab refresh, custom/floating/sidebar layouts, VoiceOver and Reduce Motion behavior remain connected to their original paths.

`Library/NativePullRefresh.swift` had the same broad observation shape for pull progress. Its state also uses Observation now, and only the small `PullIndicator` reads progress/working values. The content modifier retains the pan attachment, threshold setting, refresh action, cancellation, repeated-tab action and accessibility refresh command.

### Small images repeatedly decoded at 2048 pixels

Every `RemoteArtwork` thumbnail previously requested the same default 2048-pixel decode, including 28-point toolbar avatars and 64-point profile avatars. URLCache held encoded HTTP responses, but the store had no decoded-image reuse and no shared in-flight request ownership. Reappearing cells could repeat both request work and decoding.

`Library/RemoteArtwork.swift` now derives a stable pixel bucket from the image's laid-out bounds and display scale. `ArtworkCacheRules.pixels` uses 96/192/384/768/1536/2048-pixel buckets. At 3× scale a toolbar avatar requests 96 pixels, a 64-point profile avatar 192 pixels, and a normal cover around 768 pixels. A larger layout can request a larger bucket while the already loaded image remains visible. ImageIO decoding runs in a detached utility task, and still requests immediate downsampled decoding.

The production actor coalesces identical URL/size/byte-limit requests. Each visible consumer owns a waiter, so cancelling one cell does not cancel another cell's image. Cancelling the last waiter stops that work. Request IDs prevent old cancellation or late completion from damaging a replacement request. Clearing the cache fences pending public work and clears decoded entries too.

Decoded public CDN images use an NSCache with a 48 MiB maximum cost, further limited by the user's smaller cache limit, and a 192-entry count limit. Cache accounting includes the live decoded entries without keeping evicted entries alive. Signed URLs, other origins and responses with Set-Cookie/private/no-store are not added to decoded storage. A zero cache preference continues to disable caching. Existing proxy, TLS, redirect, no-account-cookie and response byte-limit policies remain in place. Full gallery rendering continues to use its separate gallery path.

### Offscreen channels affected the home navigation/layout

The old `RetainedDeck` implemented paging as a horizontal ScrollView and a regular HStack of retained page roots. Their navigation preferences shared the home navigation stack. The device screenshot showed the recommendation channel selected while a retained live page supplied the large “直播” title.

`Library/RetainedDeck.swift` now uses the native page-style TabView for swipeable decks, retaining the visited-page state and active-page environment. The fixed selection no longer competes with a horizontal scroll-position binding during initial layout. `Feed` passes a constant `embedded` flag to its live/ranking page roots. Those roots omit their standalone navigation-title modifier when embedded, leaving the home title with the owning home page. Standalone links and pushed category pages retain their own titles through the default `embedded == false` initializer. The non-swipe ranking deck keeps its state-retaining behavior.

`Feed` also explicitly constrains the archive-card label to the available width with leading alignment, keeping long featured titles inside the content margins. The shared CatalogGrid was checked: its geometry observation emits only an integer column count, its flexible columns accept the available width, and large accessibility text keeps one column. There is no continuously changing pixel measurement written back into that grid.

### Profile disclosure arrows and repeated row loads

The profile screenshot showed a disclosure arrow beside each item in a composite statistics/shortcut row. Those were real NavigationLink list accessories; plain button styling did not remove them. `ProfileView` now registers the same destinations once outside the lazy List and uses native Buttons for the avatar, statistics and four shortcuts. One explicit arrow remains in the profile header; the statistics and shortcut columns have no accidental list accessory. History still follows its role owner, a logged-in guest-history choice opens account-use settings, unauthenticated cloud shortcuts open login, and offline remains directly accessible.

Profile section spacing, header spacing and shortcut height are tightened. The four shortcuts remain a four-column row, switching to two columns for accessibility text. Balance/experience text uses a horizontal fit with a vertical fallback. Other library, social, subscriptions, account, privacy and settings links remain in their original groups.

`ProfileOverview` and `ProfileShelf` now remember their successfully loaded UID/revision keys. A virtualized List row reappearing does not clear and request the same successful data again. Pull refresh and explicit shelf refresh still change/reset the key; an incomplete or failed request remains retryable. Their existing cancellation and generation guards remain.

### Font/theme/root checks

Custom font-family resolution in `Typography` previously repeated UIFont name/family lookup whenever text was recomputed. A bounded cache now stores only successfully resolved names, so importing a previously unavailable font is still discoverable. Font choice, weight, relative text styles, Dynamic Type and the stored scale remain available.

The app root, `NativeInterfaceScale`, `NativeGlass`, `NativeTheme`, `NightCanvas`, navigation motion and profile/settings containers were read through. The sleep timer publishes scheduling/finish state rather than ticking the whole app every frame; the metric subscriber is already idempotent; palette generation is already keyed to a changed selection. `NativeInterfaceScale` preserves the unscaled physical display scale for separate modal roots, and its settings range remains unchanged. These paths were not replaced with speculative global style or feature changes.

The root agent separately found that the installed executable advertised SDK 17 in its Mach-O build command despite compiling against iOS 27.1. That delivery defect accounts for the system compatibility appearance and is being corrected in the build/link/IPA inspection workflow, outside this source ownership.

## Executed validation

`python3 Checks/runtime_shell.py` executes the production ArtworkStore actor with synthetic platform/transport/decode leaves. It checks shared decode identity, decoded reuse and usage accounting, size and byte-limit separation, one-versus-all waiter cancellation, noncooperative late completion, replacement request ownership, clear fencing, signed/private/no-store/zero-cache isolation and normal avatar/cover pixel budgets. The decoder leaf asserts it is not running on the main thread.

The same entry executes the production Observation-based NavigationChrome and PullState with synthetic UIKit leaves. Across 120 alternating scroll updates the strip dependency receives 120 changes while the shell's visibility dependency receives none. Pull progress is separate from refresh working state, and duplicate refresh/cancellation behavior remains exercised.

Result: PASS, `dist/runtime-shell-check.log`

The arm64 iPhone SDK typecheck includes the 20 audited root/shell/scale/theme/list/artwork/profile/settings and narrow live/ranking primary files against the iOS 27.1 SDK. Result: PASS, `dist/runtime-shell-sdk.log`

Existing `Checks/media_system.sh` passes its artwork privacy/rendition and media contracts. Existing `Checks/setting_search.sh` passes 317 real control anchors and the 145 synonym/value rows. The scoped whitespace check passes. The root agent maintains the interface consumer witness rename from `homeSearchFraction` to the real stable environment/strip consumers; no fake compatibility marker is added to production code.

## Ownership and device follow-up

Changed source files: `Settings/MainNavShell.swift`, `Settings/Typography.swift`; `Library/ArtworkCacheRules.swift`, `RemoteArtwork.swift`, `NativePullRefresh.swift`, `RetainedDeck.swift`, `Feed.swift`; `Account/ProfileView.swift`, `ProfileOverview.swift`, `ProfileComponents.swift`, `ProfileShelf.swift`; and the narrow embedded-root title parameters in `Discover/Rankings.swift` and `Live/LiveViews.swift`.

New regression entry: `Checks/runtime_shell.py`. It uses temporary files only. Playback rendering/decoder/danmaku/subtitles, other detail layouts, release gates, signing and installation are owned by the other assigned agents/root workflow.

The next device pass should compare home title and page transitions, long featured text, profile statistic/shortcut taps and chevrons, repeated fast scroll through image cells, pull refresh and tab reselect, then custom font/scale, sidebar/floating bar and accessibility layouts. These source fixes and synthetic counts are ready for that release build; final frame-time measurements and updated screenshots belong to the device capture.
