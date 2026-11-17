import SwiftUI

struct OpenSourceNotices: View {
  struct Entry: Identifiable {
    let id: String, component: String, source: String
  }
  let entries = [
    Entry(
      id: "PiliPlus-GPL", component: "PiliPlus", source: "https://github.com/bggRGjQaUbCoE/PiliPlus"
    ),
    Entry(
      id: "FFmpeg-LGPL", component: "FFmpeg 9.0.2",
      source: "https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz"),
    Entry(id:"libass-ISC",component:"libass 0.17.5",source:"https://github.com/libass/libass/releases/tag/0.17.5"),
    Entry(id:"FriBidi-LGPL",component:"GNU FriBidi 1.0.18",source:"https://github.com/fribidi/fribidi/releases/tag/v1.0.18"),
    Entry(id:"FreeType-FTL",component:"FreeType 2.15.0",source:"https://freetype.org/"),
    Entry(id:"HarfBuzz-MIT",component:"HarfBuzz 15.1.0",source:"https://github.com/harfbuzz/harfbuzz/releases/tag/15.1.0"),
    Entry(id: "dav1d-BSD", component: "dav1d 1.5.4", source: "https://downloads.videolan.org/pub/videolan/dav1d/1.5.4/"),
    Entry(id: "MaterialColorUtilities", component: "Material Color Utilities", source: "https://github.com/material-foundation/material-color-utilities/tree/194144d75ed7d34f06264a625e086db81a7ab9aa/swift"),
    Entry(id: "FlexSeedScheme", component: "FlexSeedScheme 5.0.1", source: "https://pub.dev/packages/flex_seed_scheme/versions/5.0.1"),
    Entry(id: "Anime4K", component: "Anime4K", source: "https://github.com/bloc97/Anime4K"),
    Entry(
      id: "SwiftProtobuf-LICENSE", component: "Apple SwiftProtobuf",
      source: "https://github.com/apple/swift-protobuf/tree/1.32.0"),
    Entry(
      id: "ZIPFoundation-LICENSE", component: "ZIP Foundation",
      source: "https://github.com/weichsel/ZIPFoundation/tree/0.9.20"),
  ]
  var body: some View {
    List(entries) { entry in
      NavigationLink(entry.component) {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            if let u = URL(string: entry.source) { Link("项目主页", destination: u) }
            if let url = Bundle.module.url(
              forResource: entry.id, withExtension: "txt", subdirectory: "Notices"),
              let text = try? String(contentsOf: url, encoding: .utf8)
            {
              Text(verbatim: text).textSelection(.enabled).piliFont(.footnote)
            }
          }.padding()
        }.navigationTitle(entry.component)
      }
    }.navigationTitle("开源许可")
  }
}
