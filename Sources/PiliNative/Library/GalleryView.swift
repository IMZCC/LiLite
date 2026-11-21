import AVKit
import SwiftUI

private struct GalleryShare: Identifiable { let id = UUID(), file: URL }
private struct GalleryActivity: UIViewControllerRepresentable {
  let file: URL
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: [file], applicationActivities: nil)
  }
  func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
@MainActor private final class GalleryOwner: ObservableObject {
  lazy var assets = GalleryAssets()
  @Published var busy = false
  @Published var downloading = false
  @Published var issue: String?
  @Published var needsPhotoAccess = false
  @Published var share: GalleryShare?
  func run(saving: Bool, _ work: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    needsPhotoAccess = false
    downloading = saving
    busy = true
    Task {
      defer { busy = false }
      do { try await work() }
      catch is CancellationError {}
      catch {
        needsPhotoAccess = error is GalleryPhotoPermission
        issue = error.localizedDescription
      }
    }
  }
}
private struct GalleryActions: View {
  let photos: [GalleryPicture], index: Int
  @ObservedObject var owner: GalleryOwner
  @AppStorage("images.live") private var allowMotion = true
  @ViewBuilder var body: some View {
    if photos.indices.contains(index) {
      let photo = photos[index]
      Button("分享原图") {
        owner.run(saving: false) { owner.share = GalleryShare(file: try await owner.assets.local(photo.url)) }
      }
      Button("保存原图") {
        owner.run(saving: true) {
          _ = try await owner.assets.savePictures([photo])
          owner.issue = "已保存原图"
        }
      }
      if photos.count > 1 {
        Button("保存全部原图") {
          owner.run(saving: true) {
            let n = try await owner.assets.savePictures(photos)
            owner.issue = "已保存 \(n) 张图片"
          }
        }
      }
      if allowMotion, photo.motion != nil {
        Button("保存实况照片") {
          owner.run(saving: true) {
            try await owner.assets.saveLive(photo)
            owner.issue = "实况照片已保存"
          }
        }
      }
    }
  }
}
private struct GalleryFeedback: ViewModifier {
  @ObservedObject var owner: GalleryOwner
  @AppStorage("images.silentSave") private var silent = false
  @Environment(\.openURL) private var openURL
  func body(content: Content) -> some View {
    content.overlay {
      if owner.busy && (!owner.downloading || !silent) {
        ProgressView().padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      }
    }
    .sheet(item: $owner.share) { GalleryActivity(file: $0.file) }
    .alert("图片", isPresented: Binding(get: { owner.issue != nil }, set: { if !$0 { owner.issue = nil } })) {
      if owner.needsPhotoAccess, let settings = URL(string: UIApplication.openSettingsURLString) {
        Button("打开系统设置") { openURL(settings) }
      }
      Button("好", role: .cancel) {}
    } message: { Text(owner.issue ?? "") }
  }
}
struct GalleryLink<Label: View>: View {
  let photos: [GalleryPicture], index: Int, label: Label
  @Environment(\.presentGalleryRail) private var rail
  @AppStorage("images.sidePreview") private var side = false
  @AppStorage("images.longMenu") private var menu = false
  @StateObject private var owner = GalleryOwner()
  @State private var sheet = false
  @State private var viewer = false
  @Namespace private var zoom
  init(_ photos: [GalleryPicture], index: Int, @ViewBuilder label: () -> Label) {
    self.photos = photos
    self.index = index
    self.label = label()
  }
  @ViewBuilder var body: some View {
    let content = Group {
      if side, let rail {
        Button {
          rail(.init(photos: photos, index: index))
        } label: {
          label
        }
      } else {
        Button {
          TouchFeedback.light()
          viewer = true
        } label: {
          label.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .galleryZoomSource(index, in: zoom)
        .fullScreenCover(isPresented: $viewer) {
          GalleryViewer(photos, index: index) { viewer = false }
            .galleryZoomTransition(index, in: zoom)
        }
      }
    }
    Group {
      if menu && photos.indices.contains(index) {
        content.contextMenu {
          Button("查看图片") {
            if side, let rail { rail(.init(photos: photos, index: index)) } else { sheet = true }
          }
          Button("复制图片地址") { UIPasteboard.general.url = photos[index].url }
          GalleryActions(photos: photos, index: index, owner: owner).disabled(owner.busy)
        }.modifier(GalleryFeedback(owner: owner))
      } else {
        content
      }
    }.piliSheet(isPresented: $sheet) {
      PiliNavigationStack {
        NativeGallery(photos, index: index).toolbar { Button("关闭") { sheet = false } }
      }.presentationDetents([.medium, .large])
    }
  }
}
struct GalleryThumb: View {
  let photo: GalleryPicture
  /// Fill (and crop) the proposed frame instead of letterboxing, for grid cells.
  var fill = false
  @AppStorage("images.quality") private var q = 10
  @AppStorage("images.live") private var live = true
  var body: some View {
    RemoteArtwork(url: photo.display(quality: q)) { img in
      if fill { img.resizable().scaledToFill() } else { img.resizable().scaledToFit() }
    } placeholder: {
      if fill { Color.clear } else { ProgressView() }
    }
    .overlay(alignment: .bottomLeading) {
      if live && photo.motion != nil {
        Label("实况", systemImage: "livephoto").font(.caption2.bold()).padding(4).foregroundStyle(
          .white
        ).background(.black.opacity(0.65), in: Capsule()).padding(4)
      }
    }
  }
}
/// The official client's picture viewer: black, full screen, opened by zooming out of the tapped
/// thumbnail (iOS 18+) and closed by a tap or a pull down that shrinks it back; "2/5" at the top,
/// save and more at the bottom.
struct GalleryViewer: View {
  let photos: [GalleryPicture]
  let close: () -> Void
  @State private var page: Int
  @State private var chrome = true
  /// How far a swipe to the right has carried the first picture: past the threshold it closes
  /// the viewer (and only the viewer: the page under it stays as it was).
  @State private var swipe: CGFloat = 0
  @State private var swiping: Bool?
  @StateObject private var owner = GalleryOwner()
  @StateObject private var edges = GalleryPagingEdges()
  init(_ photos: [GalleryPicture], index: Int, close: @escaping () -> Void) {
    self.photos = photos
    self.close = close
    _page = State(initialValue: min(max(0, index), max(0, photos.count - 1)))
  }
  private var swipeClose: some Gesture {
    DragGesture(minimumDistance: 12)
      .onChanged { v in
        let x = v.translation.width, y = v.translation.height
        if swiping == nil {
          // The first picture, at rest at its leading edge: nothing to page or pan back to.
          swiping = x > 0 && x > abs(y) * 1.2 && page == 0 && edges.allows(x)
        }
        if swiping == true { swipe = max(0, x) }
      }
      .onEnded { v in
        defer { swiping = nil }
        guard swiping == true else { return }
        if v.translation.width > 90 || v.predictedEndTranslation.width > 240 {
          close()
        } else {
          withAnimation(.snappy(duration: 0.25)) { swipe = 0 }
        }
      }
  }
  var body: some View {
    ZStack {
      Color.black.opacity(1 - min(0.6, swipe / 600)).ignoresSafeArea()
      if !photos.isEmpty {
        ThresholdPager(count: photos.count, page: $page, allows: edges.allows) { i in
          GalleryPage(photo: photos[i], assets: owner.assets, active: i == page, edges: edges, tapped: close)
        }
        .ignoresSafeArea()
        .offset(x: swipe)
        .scaleEffect(1 - min(0.12, swipe / 2400))
      }
    }
    .simultaneousGesture(swipeClose)
    .overlay(alignment: .top) {
      HStack {
        Button(action: close) {
          Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
            .frame(width: 40, height: 40).contentShape(Circle())
            .piliGlass(in: Circle(), interactive: true)
        }.accessibilityLabel("关闭")
        Spacer()
        if photos.count > 1 {
          Text("\(page + 1)/\(photos.count)").font(.system(size: 15, weight: .medium)).monospacedDigit()
            .contentTransition(.numericText()).animation(.snappy(duration: 0.2), value: page)
        }
        Spacer()
        Color.clear.frame(width: 40, height: 40)
      }
      .padding(.horizontal, 16).padding(.top, 6)
    }
    .overlay(alignment: .bottomTrailing) {
      if photos.indices.contains(page) {
        let p = photos[page]
        HStack(spacing: 12) {
          Menu {
            GalleryActions(photos: photos, index: page, owner: owner)
            Button("复制原图地址") { UIPasteboard.general.url = p.url }
            Link("在浏览器打开", destination: p.url)
          } label: {
            Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold))
              .frame(width: 44, height: 44).contentShape(Circle())
              .piliGlass(in: Circle(), interactive: true)
          }.accessibilityLabel("图片操作").disabled(owner.busy)
        }
        .padding(.trailing, 16).padding(.bottom, 12)
      }
    }
    .foregroundStyle(.white)
    .environment(\.colorScheme, .dark)
    .statusBarHidden()
    .modifier(GalleryFeedback(owner: owner))
  }
}

extension View {
  /// The thumbnail a viewer zooms out of and back into (iOS 18+).
  @ViewBuilder func galleryZoomSource(_ id: Int, in space: Namespace.ID) -> some View {
    if #available(iOS 18, *) { matchedTransitionSource(id: id, in: space) } else { self }
  }
  /// The viewer side of that zoom; before iOS 18 the cover slides up as usual.
  @ViewBuilder func galleryZoomTransition(_ id: Int, in space: Namespace.ID) -> some View {
    if #available(iOS 18, *) { navigationTransition(.zoom(sourceID: id, in: space)) } else { self }
  }
}

struct NativeGallery: View {
  let photos: [GalleryPicture]
  @State private var page: Int
  @StateObject private var owner = GalleryOwner()
  @StateObject private var edges = GalleryPagingEdges()
  init(_ photos: [GalleryPicture], index: Int = 0) {
    self.photos = photos
    _page = State(initialValue: min(max(0, index), max(0, photos.count - 1)))
  }
  var body: some View {
    Group {
      if !photos.isEmpty {
        ThresholdPager(count: photos.count, page: $page, allows: edges.allows) { i in
          GalleryPage(photo: photos[i], assets: owner.assets, active: i == page, edges: edges)
        }

      } else {
        ContentUnavailableView("没有图片", systemImage: "photo")
      }
    }.navigationTitle(photos.count > 1 ? "\(page+1) / \(photos.count)" : "图片")
      .navigationBarTitleDisplayMode(.inline).toolbar {
        if photos.indices.contains(page) {
          let p = photos[page]
          Menu {
            GalleryActions(photos: photos, index: page, owner: owner)
            Button("复制原图地址") { UIPasteboard.general.url = p.url }
            Link("在浏览器打开", destination: p.url)
          } label: {
            Image(systemName: "ellipsis.circle").accessibilityLabel("图片操作")
          }.disabled(owner.busy)
        }
      }.modifier(GalleryFeedback(owner: owner))
  }
}
private struct GalleryPage: View {
  let photo: GalleryPicture, assets: GalleryAssets, active: Bool
  let edges: GalleryPagingEdges
  var tapped: (() -> Void)? = nil
  @AppStorage("images.live") private var live = true
  @AppStorage("images.previewQuality") private var quality = 100
  @AppStorage("images.quality") private var minimum = 10
  @State private var file: URL?
  @State private var movie: AVQueuePlayer?
  @State private var loop: AVPlayerLooper?
  @State private var still = false
  @State private var issue: String?
  @State private var retry = 0
  private struct Key: Hashable {
    let photo: GalleryPicture, active: Bool, live: Bool, still: Bool, quality: Int, minimum: Int,
      retry: Int
  }
  /// The largest copy of the list's thumbnail already in memory.
  private func thumbnail() -> UIImage? {
    let url = photo.display(quality: minimum)
    for pixels in [2048, 1536, 768, 384, 192, 96] {
      if let image = ArtworkStore.cachedImage(url, pixels: pixels) { return image }
    }
    return nil
  }
  var body: some View {
    ZStack(alignment: .topLeading) {
      Group {
        if let movie, active {
          VideoPlayer(player: movie)
        } else if let file {
          GalleryZoom(file: file, paging: edges, active: active, tapped: tapped)
        } else if issue == nil && active {
          // The picture as the list already shows it, while the full one loads (as the original
          // does), rather than a blank page.
          ZStack {
            if let thumb = thumbnail() { Image(uiImage: thumb).resizable().scaledToFit() }
            ProgressView().tint(tapped == nil ? nil : .white)
          }
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
      if live && photo.motion != nil {
        Button {
          still.toggle()
          issue = nil
        } label: {
          Label(still ? "播放实况" : "查看封面", systemImage: "livephoto").font(.caption.bold()).padding(6)
            .piliGlass(in: Capsule(), interactive: true)
        }.padding()
      }
      if let issue, active {
        VStack {
          Text(issue)
          Button("重试") { retry += 1 }
        }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous)).frame(
          maxWidth: .infinity, maxHeight: .infinity)
      }
    }.task(
      id: Key(
        photo: photo, active: active, live: live, still: still, quality: quality, minimum: minimum,
        retry: retry)
    ) {
      stop()
      file = nil
      issue = nil
      do {
        let preview = photo.display(quality: quality, minimum: minimum)
        let image: URL
        do { image = try await assets.local(preview) } catch {
          guard preview != photo.url else { throw error }
          image = try await assets.local(photo.url)
        }
        try Task.checkCancellation()
        file = image
        if active && live && !still, let raw = photo.motion {
          let url = try await assets.local(raw, movie: true)
          try Task.checkCancellation()
          let p = AVQueuePlayer()
          p.isMuted = true
          let l = AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: url))
          loop = l
          movie = p
          p.play()
        }
      } catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }.onDisappear { stop() }
  }
  private func stop() {
    movie?.pause()
    loop?.disableLooping()
    movie?.removeAllItems()
    loop = nil
    movie = nil
  }
}
struct GallerySettings: View {
  @AppStorage("images.live") private var live = true
  @AppStorage("images.previewQuality") private var preview = 100
  @AppStorage("images.quality") private var quality = 10
  @AppStorage("images.sidePreview") private var side = false
  @AppStorage("images.silentSave") private var silent = false
  @AppStorage("images.longMenu") private var menu = false
  var body: some View {
    Form {
      Toggle("预览实况照片", isOn: $live).settingAnchor("GallerySettings/预览实况照片")
      Toggle("横屏时在面板中查看", isOn: $side).settingAnchor("GallerySettings/横屏时在面板中查看")
      Toggle("长按缩略图显示菜单", isOn: $menu).settingAnchor("GallerySettings/长按缩略图显示菜单")
      SettingStepper(title: "缩略图质量", value: $quality.asDouble, range: 1...100) { "\(Int($0))%" }.settingAnchor("GallerySettings/缩略图质量")
      SettingStepper(title: "大图质量", value: $preview.asDouble, range: 1...100) { "\(Int($0))%" }.settingAnchor("GallerySettings/大图质量")
      Toggle("保存时隐藏进度提示", isOn: $silent).settingAnchor("GallerySettings/保存时隐藏进度提示")
      NavigationLink("图片保存位置") { DeferredPage { PictureLocationSettings() } }.settingAnchor("GallerySettings/图片保存位置")
    }.navigationTitle("图片与实况照片")
  }
}
