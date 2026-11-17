"""Actual legacy FLV remux, ordered multipart HLS, cross-part seeks and cancellation.
The host ffmpeg only generates and independently decodes synthetic fixtures.
"""
import os, re, shutil, subprocess, tempfile
from pathlib import Path
from urllib.parse import unquote, urlparse

native = Path(__file__).resolve().parents[1]
kit = native / "MediaKit"
source = kit / "Sources/CLiveRemux"
swift = native / "Sources/PiliNative"
ff = os.environ.get("PILI_QA_FFMPEG") or shutil.which("ffmpeg") or str(Path.home() / ".cache/piliplus-native/tools/live-qa/ffmpeg")
prefix = Path(subprocess.check_output(["bash", str(kit / "build-ffmpeg.sh"), "host"], text=True).strip())

def run(args, **kw):
    result = subprocess.run(list(map(str, args)), stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kw)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace")[-4000:])
    return result.stdout

def frames(path, lane="v", seek=None, duration=None):
    args = [ff, "-v", "error", "-protocol_whitelist", "file,crypto,data"]
    if str(path).endswith(".m3u8"):
        args += ["-allowed_extensions", "ALL"]
    if seek is not None:
        args += ["-ss", str(seek)]
    args += ["-i", path, "-map", f"0:{lane}:0"]
    if duration is not None:
        args += ["-t", str(duration)]
    text = run(args + (["-fps_mode", "passthrough"] if lane == "v" else []) + ["-f", "framemd5", "-"]).decode()
    return [line.rsplit(",", 1)[-1].strip() for line in text.splitlines() if line and not line.startswith("#")]

def periods(playlist):
    # HLS discontinuity changes the initialization/decoder context. FFmpeg's HLS demuxer ignores
    # that tag and skips a subsequent moov; independently reset at the declared period boundaries.
    text = playlist.read_text()
    groups = text.split("#EXT-X-DISCONTINUITY\n")
    result = []
    for i, group in enumerate(groups):
        group = group.replace("#EXT-X-ENDLIST", "")
        if i:
            group = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-TARGETDURATION:90\n" + group
        path = playlist.with_name(playlist.stem + f"-period-{i}.m3u8")
        path.write_text(group + "\n#EXT-X-ENDLIST\n")
        seconds = sum(float(x) for x in re.findall(r"#EXTINF:([0-9.eE+-]+)", group))
        result.append((path, seconds))
    return result

def seek_period(periods, seconds):
    for path, duration in periods:
        if seconds < duration:
            return path, seconds
        seconds -= duration
    raise AssertionError("seek exceeds timeline")

def seek_segment(playlist, seconds):
    initialization, duration, start = None, None, 0.0
    for line in playlist.read_text().splitlines():
        if line.startswith('#EXT-X-MAP:URI="'):
            initialization = Path(unquote(urlparse(line[16:-1]).path))
        elif line.startswith("#EXTINF:"):
            duration = float(line[8:].split(",")[0])
        elif line and not line.startswith("#"):
            if seconds < start + duration:
                target = playlist.with_suffix(".seek.mp4")
                target.write_bytes(initialization.read_bytes() + Path(unquote(urlparse(line).path)).read_bytes())
                return target, seconds - start
            start += duration
    raise AssertionError("seek segment missing")

with tempfile.TemporaryDirectory(prefix="pili-legacy-durl-") as tmp:
    root = Path(tmp)
    exe, check = root / "remux", root / "index"
    run(["cc", "-std=c11", "-Werror=implicit-function-declaration", "-O2", "-I" + str(prefix / "include"),
         "-I" + str(source / "include"), source / "LegacyVOD.c", kit / "Checks/legacy_vod_file.c",
         "-L" + str(prefix / "lib"), "-lavformat", "-lavcodec", "-lswresample", "-lavutil", "-ldav1d", "-lm", "-lpthread", "-o", exe])
    first, old, converted = root / "one.mp4", root / "two.flv", root / "two.mp4"
    for file, seconds, hue in [(first, 4, 0), (old, 6, 90)]:
        run([ff, "-v", "error", "-f", "lavfi", "-i", "testsrc2=s=128x72:r=12", "-f", "lavfi", "-i",
             "sine=frequency=701:sample_rate=48000", "-t", str(seconds), "-vf", f"hue=h={hue}", "-c:v", "libx264",
             "-preset", "ultrafast", "-g", "12", "-bf", "2", "-sc_threshold", "0", "-c:a", "aac",
             *(["-movflags", "+faststart"] if file == first else ["-flvflags", "add_keyframe_index", "-f", "flv"]), file])
    run([exe, old, converted])
    original, remuxed = frames(old), frames(converted)
    assert len(original) == 72 and remuxed == original, (len(original), len(remuxed))
    assert frames(old, "a") == frames(converted, "a"), "FLV remux changed decoded PCM"
    enhanced = []
    for name, encoder, options in [
        ("hevc", "libx265", ["-preset", "ultrafast", "-x265-params", "log-level=error:pools=1:frame-threads=1"]),
        ("av1", "libaom-av1", ["-cpu-used", "8", "-threads", "2"]),
    ]:
        source_file, movie = root / (name + ".flv"), root / (name + ".mp4")
        run([ff, "-v", "error", "-f", "lavfi", "-i", "testsrc2=s=128x72:r=10", "-f", "lavfi", "-i",
             "sine=frequency=401:sample_rate=48000", "-t", "3", "-c:v", encoder, *options, "-g", "10", "-c:a", "aac", "-flvflags", "add_keyframe_index", "-f", "flv", source_file])
        run([exe, source_file, movie])
        assert frames(movie) == frames(source_file) and frames(movie, "a") == frames(source_file, "a"), name
        enhanced.append(source_file)
    module = root / "module.modulemap"
    module.write_text(f'module CLiveRemux {{ umbrella header "{source / "include/CLiveRemux.h"}" export * }}')
    obj = root / "remux.o"
    run(["cc", "-c", "-O2", "-I" + str(prefix / "include"), "-I" + str(source / "include"), source / "LegacyVOD.c", "-o", obj])
    run(["swiftc", "-Xcc", "-fmodule-map-file=" + str(module), swift / "Playback/LegacyDURLPlaylist.swift", swift / "Playback/SegmentIndex.swift",
         swift / "Decoder/LocalFragmentIndex.swift", swift / "Decoder/LocalMovieTable.swift", swift / "Decoder/LocalMovieFragments.swift",
         swift / "Decoder/LegacyMovieRemux.swift", swift / "Offline/LegacyOfflineMedia.swift", swift / "Offline/LegacyMediaComponents.swift",
         swift / "Offline/OfflinePieces.swift", swift / "Playback/RelayRange.swift", swift / "Playback/MediaRange.swift", swift / "Network/ServiceError.swift",
         native / "Checks/LegacyDURLCheck.swift", obj, "-L" + str(prefix / "lib"), "-lavformat", "-lavcodec", "-lswresample", "-lavutil", "-ldav1d", "-lm", "-lpthread", "-o", check])
    out = root / "vod"
    print(run([check, out, first, old, *enhanced]).decode().strip())
    index_obj = root / "index.o"
    run(["cc", "-c", "-O2", "-I" + str(prefix / "include"), "-I" + str(source / "include"), source / "LegacyFLVIndex.c", "-o", index_obj])
    window = root / "window"
    pool_check = root / "pool"
    run(["swiftc", "-D", "PILI_SLICE_QA", swift / "Playback/LegacySlicePool.swift", native / "Checks/LegacySlicePoolCheck.swift", "-o", pool_check])
    print(run([pool_check]).decode().strip())
    run(["swiftc", "-Xcc", "-fmodule-map-file=" + str(module),
         *[swift / (file + ".swift") for file in ["Playback/LegacyFLVIndex", "Playback/LegacyDURLPlaylist", "Playback/LegacyFragmentTime", "Playback/SegmentIndex",
           "Decoder/LegacyMovieRemux", "Decoder/LocalFragmentIndex", "Decoder/LocalMovieTable", "Decoder/LocalMovieFragments", "Network/ServiceError"]],
         native / "Checks/LegacyFLVWindowCheck.swift", obj, index_obj, "-L" + str(prefix / "lib"), "-lavformat", "-lavcodec", "-lswresample", "-lavutil", "-ldav1d", "-lm", "-lpthread", "-o", window])
    for file in [old, *enhanced]:
        target = root / (file.stem + "-windows")
        print(run([window, file, target]).decode().strip())
        actual = frames(target / "v/index.m3u8")
        assert actual == frames(file), (file.stem, len(actual), len(frames(file)))
        actual_audio = frames(target / "a/index.m3u8", "a")
        assert actual_audio == frames(file, "a"), (file.stem, "window PCM changed", len(actual_audio), len(frames(file, "a")))
    long = root / "long-indexed.flv"
    run([ff, "-v", "error", "-f", "lavfi", "-i", "testsrc2=s=512x288:r=24", "-f", "lavfi", "-i", "sine=sample_rate=48000", "-t", "90",
         "-c:v", "libx264", "-preset", "ultrafast", "-b:v", "2M", "-g", "24", "-bf", "2", "-sc_threshold", "0", "-c:a", "aac", "-flvflags", "add_keyframe_index", "-f", "flv", long])
    print(run([window, long, root / "sparse", "sparse"]).decode().strip())
    video_periods = periods(out / "video.m3u8")
    combined = [frame for path, _ in video_periods for frame in frames(path)]
    expected = frames(first) + remuxed + [frame for file in enhanced for frame in frames(file)]
    assert combined == expected, (len(combined), len(expected))
    manifest = (out / "video.m3u8").read_text()
    total = sum(float(n) for n in re.findall(r"#EXTINF:([0-9.eE+-]+)", manifest))
    assert abs(total - 16) < 0.001, total
    # A seek straight into part 2 must resolve its own initialization and keyframe preroll.
    path, time = seek_period(video_periods, 6)
    path, time = seek_segment(path, time)
    seek = frames(path, seek=time, duration=1)
    # The synthetic FLV uses millisecond time stamps, so compare the selected source's own seek.
    assert len(seek) == 12 and seek == frames(converted, seek=2, duration=1)
    # Seek back across the discontinuity to an earlier part after an independently indexed read.
    path, time = seek_period(video_periods, 1)
    path, time = seek_segment(path, time)
    assert frames(path, seek=time, duration=1) == frames(first, seek=1, duration=1)
    audio = [frame for path, _ in periods(out / "audio.m3u8") for frame in frames(path, "a")]
    assert len(audio) >= 740, len(audio)
    cancelled = root / "cancel.mp4"
    assert subprocess.run([str(exe), str(old), str(cancelled), "3"], capture_output=True).returncode != 0
    assert not cancelled.exists(), "cancelled partial movie retained"
    invalid = root / "invalid.flv"
    invalid.write_bytes(b"not a media container" * 50)
    assert subprocess.run([str(exe), str(invalid), str(cancelled)], capture_output=True).returncode != 0
    assert not cancelled.exists()
    print(f"Legacy DURL: {len(combined)} exact decoded video frames, {len(audio)} audio frames, {total:g}s VOD, forward/backward cross-part seek, lossless FLV/MP4, cancellation and malformed input passed")
