#!/usr/bin/env bash
# Exercise the lifecycle policies and LRC parser independent from OS audio notifications.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -f -- "$work/main.swift" "$work/tracks.swift" "$work/check"; rmdir -- "$work"' EXIT
# ListenMark below this declaration depends on the AV session track, not used by the gate.
sed '/^struct ListenMark/,$d' Sources/PiliNative/Audio/ListenResume.swift > "$work/tracks.swift"
cat > "$work/main.swift" <<'SWIFT'
import Foundation
var gate = ListenInterruptionGate()
gate.begin(active: true); gate.begin(active: false)
precondition(gate.interrupted && gate.finish(shouldResume: true))
precondition(!gate.finish(shouldResume: true))
gate.begin(active: true); gate.invalidate()
precondition(!gate.finish(shouldResume: true))
gate.begin(active: false)
precondition(!gate.finish(shouldResume: true))
gate.begin(active: true)
precondition(!gate.finish(shouldResume: false))
var movie = PlaybackInterruptionIntent<String>()
movie.play("A",rate:1.5); movie.interrupt("A"); movie.interrupt("A")
precondition(movie.finish("A",allowed:true)==1.5 && movie.finish("A",allowed:true)==nil)
movie.play("A",rate:1.5); movie.interrupt("A"); movie.cancel()
precondition(movie.finish("A",allowed:true)==nil)
movie.play("A",rate:1.5); movie.interrupt("A"); movie.play("B",rate:2)
precondition(movie.finish("B",allowed:true)==nil)
movie.play("A",rate:1.5); movie.interrupt("A")
precondition(movie.finish("B",allowed:true)==nil)
movie.play("A",rate:1.5); movie.interrupt("A")
precondition(movie.finish("A",allowed:false)==nil)
movie.play("A",rate:0); movie.interrupt("A")
precondition(movie.finish("A",allowed:true)==nil)
var profile = NetworkMediaRules()
profile.wifiVideo = 112; profile.cellVideo = 32
profile.wifiAudio = 30251; profile.cellAudio = 30216
precondition(OfflineQuality.video([16, 80, 112, 127], rules:profile) == 112)
precondition(OfflineQuality.audio([30216, 30280, 30251], rules:profile) == 30251)
precondition(OfflineQuality.audio([30216, 30280], rules:profile) == 30280)
precondition(OfflineQuality.video([], rules:profile) == nil)
let fence = SleepExitFence()
var quitCalls = 0
func simQuit(_ ticket: UUID) -> Bool { fence.finish(ticket, quiet: 0) { quitCalls += 1 } }
precondition(!simQuit(UUID()) && quitCalls == 0) // Never scheduled.
let cancelled = fence.arm(); fence.cancel(cancelled)
precondition(!simQuit(cancelled) && quitCalls == 0)
let scheduled = fence.arm()
let writing = try fence.enter()
precondition(!simQuit(scheduled) && quitCalls == 0) // Do not interrupt a commit.
writing()
let t = Date(timeIntervalSince1970: 1)
var finishBeforeExit = SleepDeadline.scheduled(t, afterItem: true)
precondition(!finishBeforeExit.expire(now:t.addingTimeInterval(-1), playing:true, live:false))
precondition(!finishBeforeExit.expire(now:t, playing:true, live:false) && quitCalls == 0)
if finishBeforeExit.finish() { precondition(simQuit(scheduled)) }
precondition(!finishBeforeExit.finish() && !simQuit(scheduled) && quitCalls == 1)
precondition((try? fence.enter()) == nil) // No new writes after commit.
fence.cancel(scheduled)
let afterReopen = try fence.enter(); afterReopen()

let marks = ["bv|genA|video": 17, "bv|genA|audio": 19]
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try JSONEncoder().encode(marks).write(to: directory, options: .atomic)
let restored = try JSONDecoder().decode([String:Int].self, from: Data(contentsOf: directory))
try FileManager.default.removeItem(at: directory)
func retry(_ key: String = "bv|genA|video", id: Int = 17, held: Bool = true, transferring: Bool = true, who: String? = "42") -> Bool {
  SleepTransferHold.mayResume(restored, key:key, task:id, suspended:held, transferring:transferring, downloadOwner:who, currentOwner:"42")
}
precondition(retry() && retry("bv|genA|audio",id:19))
precondition(!retry("bv|genB|video") && !retry(id:18) && !retry(held:false))
precondition(!retry(transferring:false) && !retry(who:"43") && !retry(who:nil))
var deadline = SleepDeadline.scheduled(t, afterItem: true)
precondition(deadline.expire(now:t,playing:false,live:false) && deadline == .off)
deadline = .scheduled(t, afterItem:true)
precondition(!deadline.expire(now:t,playing:true,live:false) && deadline == .finishingItem)
precondition(deadline.finish() && !deadline.finish())
let lyrics = LyricLines("[ar:作者]\n[00:02.00][00:08.05]重复\n[00:05]歌词\n[offset:200]\n")
precondition(lyrics.lines.map(\.text) == ["重复","歌词","重复"])
precondition(lyrics.active(at:1.79)==nil && lyrics.active(at:1.81)==0 && lyrics.active(at:4.81)==1 && lyrics.active(at:8)==2)
precondition(LyricLines("第一句\n第二句").lines.map(\.text)==["第一句","第二句"])
precondition(LyricLines("[99:94]无效").lines[0].seconds==nil)
print("PASS interruption intent, offline quality defaults, single/cancelled/deferred exit without terminating, deferred off, end-of-item once, repeat timestamps, offset and plain lyrics")
SWIFT
swiftc "$work/tracks.swift" Sources/PiliNative/Playback/SleepDeadline.swift Sources/PiliNative/Playback/SleepExitPermit.swift Sources/PiliNative/Playback/PlaybackInterruptionIntent.swift Sources/PiliNative/Playback/MediaPreferences.swift Sources/PiliNative/Network/ServiceError.swift Sources/PiliNative/Audio/LyricLines.swift "$work/main.swift" -o "$work/check"
"$work/check"
