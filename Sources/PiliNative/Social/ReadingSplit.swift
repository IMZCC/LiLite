import SwiftUI

/// Geometry belongs to the current window, including iPad multitasking.
struct ReadingSplit<Story: View, Panel: View>: View {
  let hasPanel: Bool
  @ViewBuilder var story: () -> Story
  @ViewBuilder var panel: (AnyView?) -> Panel
  @AppStorage("reading.bodyPercent") private var percent = 60.0
  @State private var adjust = false
  @State private var gallery: GalleryRailRequest?
  @AppStorage("images.sidePreview") private var galleryEnabled = false
  var body: some View {
    GeometryReader { g in
      let wide = g.size.width > g.size.height && g.size.width >= 540
      Group {
      if wide && hasPanel {
        HStack(spacing: 0) {
          ScrollView {
            story().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
          }
          .frame(width: max(0, g.size.width - 1) * min(90, max(10, percent)) / 100)
          .clipped()
          Divider()
          panel(nil).frame(maxWidth: .infinity)
            .overlay {
              if galleryEnabled, let gallery { GalleryRailPanel(request: gallery) { self.gallery = nil } }
            }
        }.toolbar {
          Button {
            adjust = true
          } label: {
            Label("调整分栏比例", systemImage: "rectangle.split.2x1")
          }.popover(isPresented: $adjust) {
            VStack(alignment: .leading) {
              Text("正文宽度 \(Int(percent.rounded()))%")
              Slider(value: $percent, in: 10...90).accessibilityLabel("正文宽度")
              Button("恢复 60:40") { percent = 60 }
            }.frame(width: 220).padding().presentationCompactAdaptation(.popover)
          }
        }
      } else if hasPanel {
        panel(
          AnyView(
            story().frame(maxWidth: .infinity, alignment: .leading)
              .buttonStyle(.borderless)))
      } else {
        ScrollView { story().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal) }
          .overlay(alignment: .trailing) {
            if wide && galleryEnabled, let gallery {
              GalleryRailPanel(request: gallery) { self.gallery = nil }
                .frame(width: min(500, g.size.width * 0.5))
            }
          }
      }
      }.environment(\.presentGalleryRail, wide && galleryEnabled ? { gallery = $0 } : nil)
       .onChange(of: wide && galleryEnabled) { _, show in if !show { gallery = nil } }
    }
  }
}
