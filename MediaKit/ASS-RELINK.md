# ASS rendering: source, licenses and relinking

The four unmodified libraries below are built into the local iOS executable. The build needs their source release archives, not prebuilt slices. [build-subtitles.py](build-subtitles.py) contains the HTTPS URLs, SHA-256 checksums, complete Meson settings and iPhone arm64 target. Downloads and output are outside the repository. The frontend uses the app's own [C adapter](Sources/CLiveRemux/PiliASS.c) and Swift view; it does not invoke a subtitle player or ship a Flutter runtime

| Component | License selected here | Fixed source |
|---|---|---|
| libass 0.17.5 | ISC | [upstream archive](https://github.com/libass/libass/releases/download/0.17.5/libass-0.17.5.tar.xz) |
| GNU FriBidi 1.0.18 | LGPL-2.1-or-later | [upstream archive](https://github.com/fribidi/fribidi/releases/download/v1.0.18/fribidi-1.0.18.tar.xz) |
| HarfBuzz 15.1.0 | Old MIT and the included module/data notices | [upstream archive](https://github.com/harfbuzz/harfbuzz/releases/download/15.1.0/harfbuzz-15.1.0.tar.xz) |
| FreeType 2.15.0 | FreeType Project License (FTL) and included module notices | [upstream archive](https://download-mirror.savannah.gnu.org/releases/freetype/freetype-2.15.0.tar.xz) |

Portions of this software are copyright © 1996–2026 The FreeType Project (https://freetype.org/). All rights reserved. Full license texts and acknowledgments for the shipped renderer are in [Notices](../Sources/PiliNative/Notices), bundled with the app and readable from Settings → About → Open source licenses. The host comparison uses an installed system font. No Apple SDK, Apple glyphs or test fonts are redistributed

To reproduce the shipped static build, from `Native` run `python3 MediaKit/build-subtitles.py ios` (or `host` for the host), followed by `bash build.sh --release` for the unsigned iOS app. Meson/Ninja/clang, the established WSL Apple SDK, and on iOS CoreText and the platform C/C++ runtime are required. The MediaKit build already bootstraps Meson and Ninja on this WSL environment. Static-library and final-link options are in this checkout's `MediaKit/Package.swift`, `Package.swift` and `build.sh`. The versioned callback interface, all app sources and build scripts in this same checkout are sufficient to relink; no private app object file is required

To relink against a modified compatible FriBidi, copy the printed prefix to a separate local directory. Rebuild your modified FriBidi source using the same Meson configure command and generated iOS cross file as the pinned build (see the build cache's `fribidi/meson-logs/meson-log.txt`). Install the changed library and headers into that copy. Set `PILI_SUBTITLE_RELINK_PREFIX=/absolute/path/to/your/prefix` when invoking the Native app build. The alternate prefix is explicit, skips the pinned-sources builder and leaves the original archive, receipt and cache intact. The same mechanism works for all four libraries. The resulting unsigned executable can be run with the device owner's normal signing process

For a binary distribution, supply the corresponding application and library source (including the four archives for this version), these build scripts and relinking instructions with the executable or through an appropriate corresponding-source delivery route. The local source archive cache can be used to prepare that separate source bundle; `build-subtitles.py` verifies each archive before unpacking
