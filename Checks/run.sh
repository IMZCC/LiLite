#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -f -- "$work/sidx" "$work/content" "$work/behavior" "$work/article" "$work/backup" "$work/livechat" "$work/creator-sections" "$work/feed-columns" "$work/nav-shell" "$work/media-buffer" "$work/login-grant" "$work/liveinteraction" "$work/post-draft" "$work/interaction" "$work/phone-layout"; rmdir -- "$work"' EXIT
src=Sources/PiliNative
swiftc "$src/Library/FeedHeaderInsets.swift" "$src/Library/PlayerPageLayout.swift" Checks/PhoneLayoutCheck.swift -o "$work/phone-layout"
"$work/phone-layout"
swiftc "$src/Playback/SegmentIndex.swift" Checks/SegmentIndexCheck.swift -o "$work/sidx"
"$work/sidx"
swiftc "$src/Network/ServiceError.swift" "$src/Danmaku/Danmaku.swift" "$src/Danmaku/DanmakuStyle.swift" "$src/Danmaku/CloudBulletRule.swift" "$src/Danmaku/BulletTrackFrame.swift" "$src/Danmaku/BulletLayoutPlan.swift" "$src/Danmaku/DMProto.swift" "$src/Danmaku/SpecialBullet.swift" "$src/Discover/SharedLink.swift" "$src/Playback/RelayRange.swift" Checks/ContentContractCheck.swift -o "$work/content"
"$work/content"
swiftc "$src/Account/SpacePrivacyValues.swift" "$src/Playback/PictureFit.swift" "$src/Playback/ArchiveStreamGrant.swift" "$src/Network/ServiceError.swift" "$src/Settings/DecodedSettingCache.swift" "$src/Library/RecommendationFilter.swift" "$src/Library/MediaPageWindow.swift" "$src/Library/LaterMedia.swift" "$src/Social/DynamicModules.swift" "$src/Social/IMHistoryPolicy.swift" "$src/Live/LiveModels.swift" "$src/Live/LiveVariants.swift" "$src/Live/LiveLocalAsset.swift" "$src/Live/LiveCDNOrigin.swift" "$src/Social/ChatWindow.swift" "$src/Social/IMCardBody.swift" "$src/Social/RichNodes.swift" "$src/Library/GalleryPicture.swift" "$src/Social/IMShareCard.swift" "$src/Social/UnreadTotals.swift" "$src/Discover/SharedLink.swift" "$src/Social/ReplyFiltering.swift" "$src/Social/ReplyDraft.swift" "$src/Social/DynamicRevision.swift" "$src/Account/AccountRole.swift" "$src/Account/AccountServices.swift" "$src/Library/Video.swift" "$src/Playback/DashModels.swift" "$src/Playback/VODLine.swift" "$src/Network/APIProxy.swift" "$src/Network/ArchiveNumber.swift" "$src/Decoder/AudioFilterChoice.swift" "$src/Offline/OfflineVideo.swift" "$src/Offline/LegacyMediaComponents.swift" "$src/Offline/EpisodeCachePolicy.swift" "$src/Playback/VideoRepeat.swift" "$src/Playback/SubtitlePreference.swift" "$src/Network/ConnectionRetry.swift" "$src/Library/ArtworkCacheRules.swift" "$src/Discover/SeasonSchedule.swift" "$src/Audio/AudioSequence.swift" "$src/Playback/ArchiveResume.swift" "$src/Playback/PlaybackMemory.swift" "$src/Playback/FullscreenPolicy.swift" "$src/Playback/VideoEngagement.swift" "$src/Playback/CaptureTiming.swift" "$src/Playback/TimelineData.swift" "$src/Playback/SponsorRules.swift" "$src/Playback/SponsorDraft.swift" "$src/Playback/MediaPreferences.swift" "$src/Playback/SleepDeadline.swift" "$src/Playback/EpisodeClips.swift" "$src/Playback/RelayRange.swift" "$src/Playback/MediaRange.swift" "$src/Playback/SponsorSource.swift" Checks/PortBehaviorCheck.swift -o "$work/behavior"
"$work/behavior" "$@"
swiftc "$src/Decoder/AudioFilterChoice.swift" -I Checks/Support/XML -Xcc -I/usr/include/libxml2 "$src/Network/ServiceError.swift" "$src/Settings/DecodedSettingCache.swift" "$src/Library/RecommendationFilter.swift" "$src/Library/Video.swift" "$src/Library/GalleryPicture.swift" "$src/Discover/SharedLink.swift" "$src/Social/RichNodes.swift" "$src/Social/InlineDocument.swift" "$src/Discover/ArticleBody.swift" "$src/Discover/ArticleHTML.swift" Checks/ArticleBodyCheck.swift -o "$work/article"
"$work/article"
swiftc "$src/Network/ServiceError.swift" "$src/Network/SelfHostedServiceURL.swift" "$src/Playback/SponsorAPIRequest.swift" "$src/Settings/BackupFormat.swift" "$src/Settings/WebDAVStore.swift" Checks/BackupCheck.swift -o "$work/backup"
"$work/backup"
swiftc "$src/Network/ServiceError.swift" "$src/Network/ServiceID.swift" "$src/Live/SuperChatData.swift" Checks/LiveChatCheck.swift -o "$work/livechat"
"$work/livechat"
swiftc "$src/Network/ServiceError.swift" "$src/Network/ServiceID.swift" "$src/Live/LiveModels.swift" "$src/Live/SuperChatData.swift" "$src/Live/LiveEmoteChoices.swift" Checks/LiveInteractionCheck.swift -o "$work/liveinteraction"
"$work/liveinteraction"
swift test --package-path ArchiveKit --scratch-path "$HOME/.cache/piliplus-native/archive-tests"
swift test --package-path Wire --scratch-path "$HOME/.cache/piliplus-native/wire-tests"
swiftc "$src/Discover/SharedLink.swift" "$src/Social/CreatorSections.swift" Checks/CreatorSectionsCheck.swift -o "$work/creator-sections"
"$work/creator-sections"
swiftc "$src/Social/FeedColumnPlan.swift" "$src/Library/FeedScrollPaging.swift" Checks/FeedColumnCheck.swift -o "$work/feed-columns"
"$work/feed-columns"
swiftc "$src/Decoder/AudioFilterChoice.swift" "$src/Network/ServiceError.swift" "$src/Discover/SharedLink.swift" "$src/Settings/DecodedSettingCache.swift" "$src/Library/RecommendationFilter.swift" "$src/Library/Video.swift" "$src/Settings/NavigationRules.swift" "$src/Account/ProfileShelfModels.swift" Checks/NavigationShellCheck.swift -o "$work/nav-shell"
"$work/nav-shell"
swiftc "$src/Playback/MediaBufferPolicy.swift" "$src/Playback/MediaBufferWindow.swift" "$src/Playback/MediaBufferFIFO.swift" Checks/MediaBufferCheck.swift -o "$work/media-buffer"
"$work/media-buffer"
swiftc "$src/Account/WebAccountCookies.swift" Checks/WebAccountCookiesCheck.swift -o "$work/login-grant"
"$work/login-grant"
python3 Checks/vod_probe.py
python3 Checks/cast_receiver.py
bash Checks/reply_domain.sh
bash Checks/music_content.sh
bash Checks/interface_acceptance.sh
python3 Checks/runtime_shell.py
bash Checks/caption_domain.sh
python3 Checks/caption_manifest.py
python3 Checks/social_signoff.py
python3 Checks/service_protocols.py
python3 Checks/common_pages.py
bash Checks/personal_library.sh
python3 Checks/account_routes.py
swiftc "$src/Network/ServiceError.swift" "$src/Social/ReplyDraft.swift" "$src/Social/DynamicRevision.swift" "$src/Social/DynamicDraftFile.swift" Checks/DynamicDraftCheck.swift -o "$work/post-draft"
"$work/post-draft"
swiftc "$src/Settings/InteractionPolicy.swift" Checks/InteractionPolicyCheck.swift -o "$work/interaction"
"$work/interaction"
python3 Checks/secure_network_loopback.py
python3 Checks/discovery_readback.py
python3 Checks/audio_gain.py
bash Checks/imported_credentials.sh
python3 Checks/mobile_passport.py
python3 Checks/mobile_rest.py
python3 Checks/web_cookies.py
python3 Checks/device_activation.py
bash Checks/creator_playlist.sh
bash Checks/interactive_story.sh
bash Checks/setting_search.sh
bash Checks/im_notice_actions.sh
bash Checks/moment_domain.sh
bash Checks/notebook_domain.sh
python3 Checks/offline_resume.py
bash Checks/listen_interruption.sh
bash Checks/season_detail.sh
bash Checks/media_system.sh
bash Checks/player_keys.sh
bash Checks/archive_detail.sh
bash Checks/theme_colors.sh
python3 Checks/ReviewEvidenceCheck.py
python3 Checks/parity.py
