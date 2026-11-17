# C audio continuity and starvation check — 2026-11-13

Scope: read-only review of `AudioSegment.c`, `AudioTap.c`, `AudioGain.c`, `TimingRing.c` and `TimingStretch.h`, followed by temporary, real AAC/ALAC/PCM execution. C sources were not changed. The samples below are generated stereo tones, not account media or private device logs.

## Commands and independent oracle

Run from `Native` under WSL, with `vendor` set to the existing `dist/audio-libs-host.path` value. The probes compiled the shipping functions into temporary shared libraries:

```sh
cc -std=c11 -O2 -shared -fPIC -Wl,-Bsymbolic -I"$vendor/include" -IMediaKit/Sources/CLiveRemux/include MediaKit/Sources/CLiveRemux/AudioSegment.c -L"$vendor/lib" -lavformat -lavfilter -lavcodec -lswresample -lswscale -lavutil -ldav1d -lpthread -lm -o /tmp/audio-probe.so
cc -std=c11 -O2 -shared -fPIC -IMediaKit/Sources/CLiveRemux/include MediaKit/Sources/CLiveRemux/TimingRing.c -lm -o /tmp/ring-probe.so
ffmpeg -v error -f lavfi -i 'aevalsrc=0.31*sin(2*PI*719*t)|0.17*sin(2*PI*431*t):s=44100' -t 17.317 -c:a aac -b:a 160k -movflags empty_moov+default_base_moof+dash+skip_trailer -frag_duration 1990000 /tmp/input-44100.m4a
```

The second input uses `s=48000`. A temporary Python/ctypes harness invokes production `pl_audio_pcm` for every fragment, supplying one preceding/following fragment and `volume=volume=1`. Its independent Python MP4 parser reads the original `tfdt` plus `tfhd`/`trun` sample durations directly. Every returned `first_sample` and `frames` must equal those original container fields, and adjacent sample intervals must touch exactly. For first/middle/last fragments it also calls `pl_audio_segment`, decodes the resulting ALAC with FFmpeg, and verifies decoded PTS/frame counts using `-copyts -f framehash`. FFmpeg CLI was 7.0.2; the production C library uses the repository's locked FFmpeg vendor build.

## Actual boundary results

| Stereo AAC rate | Fragments | Source `trun` end / returned PCM frames | Adjacent PTS gaps | Inserted/lost source frames | ALAC decoded first/middle/last |
| --- | ---: | ---: | ---: | ---: | --- |
| 44,100 Hz | 9 | 764,704 / 764,704 | 0 | 0 | Exact PTS and frame count: 0, 4, 8 |
| 48,000 Hz | 9 | 832,240 / 832,240 | 0 | 0 | Exact PTS and frame count: 0, 4, 8 |

The last source AAC sample duration is 800/752 frames, rather than 1024. Untrimmed CLI PCM contains 224/272 additional padding frames; direct container parsing confirms that the production crop is correct. CLI PCM waveform comparison has worst per-segment error RMS of −83.03/−120.17 dBFS respectively. It does not contain the periodic zero-filled intervals being investigated. The ALAC muxer prints a nonzero-DTS/empty-moov warning for later fragments; actual output `tfdt` and decoded clocks are correct after the production `set_time` operation.

`bounds`, `receive_pcm`, `drain_fifo` and `process` enforce the selected interval and flush both filter and codec output. The processed rendition uses ALAC, without AAC re-encoding/encoder priming. With no selected sound effects the AVPlayer rendition preserves compressed AAC, but the default independent presentation clock separately decodes AAC to PCM. Therefore the existence of a direct AAC rendition does not imply that native AVPlayer audio is the active sound path.

## Real render-ring supply boundary

The production `pl_clock_ring` was configured at 48 kHz, mono, capacity 144,000 frames, first sample 0. Input was a 719 Hz tone at amplitude 0.3; each hardware-like call requested 512 frames with the default ratio/tempo 1.

- Continuous supply: prefill 96,000 frames; before each callback, append 48,000 whenever buffered frames fall below 48,000. All 1,000 render calls returned 512 frames; underflows were **0**.
- Deliberate producer stall: prefill 96,000 frames, then call render 375 times without another write. It rendered the two supplied seconds and filled **96,000 missing frames** with exact zeros. The first short callback was index **187**; **187 callbacks** were wholly silent.
- After an empty callback, `pl_clock_time(ring, 4, 1, 0)` returned **NAN**. This follows `pl_clock_render`'s `memset` of unfilled output and `pl_clock_time`'s zero-rendered-frame guard. The logical source cursor does not advance through the inserted silence.

This is a concrete route from late producer replenishment to interrupted sound and an unavailable presentation clock. It does not require a malformed AAC boundary. At accelerated playback the source-frame watermarks also represent less wall-clock reserve; the WSOLA branch additionally needs its bounded future window. The Swift playback owner is addressing producer scheduling, startup watermarks, replenishment and fallback lifecycle, and owns the corresponding regression integration. No C algorithm change is justified by these sample results. Device audio/video continuity still needs to be checked with the rebuilt application.
