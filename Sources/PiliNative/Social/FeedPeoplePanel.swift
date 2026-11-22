import SwiftUI

enum FeedPanelDestination: Hashable {
  case creator(Int64, String)
  case room(Int64, String)
  case followedLive
}

struct FeedPeoplePanel: View {
  let uid: String, position: FeedPanelPosition, selected: Int64?
  @ObservedObject var model: FeedDirectoryState
  @Binding var expandedLive: Bool
  let select: (DynamicPortal.Person?) -> Void, open: (FeedPanelDestination) -> Void
  @AppStorage("social.allFollowed") private var all = false
  private var me: AccountProfile? { model.me }
  private var horizontal: Bool { position == .top }
  var body: some View {
    ScrollView(horizontal ? .horizontal : .vertical) {
      if horizontal {
        // The official client's strip: round avatars with one line of name under each.
        LazyHStack(alignment: .top, spacing: 6) { entries }.padding(.horizontal, 12).padding(.vertical, 8)
      } else {
        LazyVStack(alignment: position.drawer ? .leading : .center, spacing: 4) { entries }
          .padding(.horizontal, 4).padding(.vertical, 6)
      }
    }
    .scrollIndicators(.hidden)

  }
  @ViewBuilder private var entries: some View {
    Button {
      expandedLive.toggle()
    } label: {
      tile(
        "直播 \(model.liveCount)",
        symbol: expandedLive ? "chevron.up.circle" : "dot.radiowaves.left.and.right")
    }
    .contextMenu { Button("关注的直播") { open(.followedLive) } }
    .accessibilityHint("展开或收起直播列表")
    if expandedLive {
      ForEach(model.rooms) { room in
        Button {
          if let id = room.room_id { TouchFeedback.light(); open(.room(id, room.title ?? "直播间")) }
        } label: {
          tile(
            room.uname ?? "直播间", face: room.face, symbol: "antenna.radiowaves.left.and.right",
            live: true)
        }
        .contextMenu {
          if let mid = room.mid, mid > 0 {
            Button("打开空间") { open(.creator(mid, room.uname ?? "UP 主")) }
          }
          Button("关注的直播") { open(.followedLive) }
        }
      }
      if !model.rooms.isEmpty || model.liveCount > 0 {
        Button {
          open(.followedLive)
        } label: {
          tile("全部直播", symbol: "tv")
        }
      }
    }
    Button {
      TouchFeedback.light(); select(nil)
    } label: {
      tile("全部动态", symbol: "square.grid.2x2", active: selected == nil)
    }
    if let mid = Int64(uid), mid > 0 {
      Button {
        TouchFeedback.light(); select(.init(mid: mid, uname: me?.uname ?? "我", face: me?.face))
      } label: {
        tile("我", face: me?.face, symbol: "person.crop.circle", active: selected == mid)
      }.contextMenu { Button("我的空间") { open(.creator(mid, me?.uname ?? "我的空间")) } }
    }
    ForEach(model.people.filter { String($0.mid) != uid }) { person in
      Button {
        TouchFeedback.light(); model.read(person.mid)
        select(person)
      } label: {
        tile(
          person.uname ?? String(person.mid), face: person.face, symbol: "person.crop.circle",
          active: selected == person.mid, updated: person.has_update == true)
      }.contextMenu { Button("打开空间") { open(.creator(person.mid, person.uname ?? "UP 主")) } }
    }
    if model.busy {
      ProgressView().frame(minWidth: 40, minHeight: 42).accessibilityLabel("正在加载 UP 主")
    } else if let issue = model.issue {
      Button {
        Task {
          if model.more { await model.loadMore() } else { await model.refresh(uid, all: all) }
        }
      } label: {
        tile("重试", symbol: "arrow.clockwise")
      }
      .accessibilityHint(issue)
      if position.drawer { Text(issue).font(.caption2).foregroundStyle(.secondary) }
    } else if model.more {
      Button {
        Task { await model.loadMore() }
      } label: {
        tile("更多", symbol: "ellipsis.circle")
      }
      .onAppear { Task { await model.loadMore() } }
    }
  }
  private func tile(
    _ name: String, face: String? = nil, symbol: String, active: Bool = false,
    updated: Bool = false, live: Bool = false
  ) -> some View {
    let layout =
      position.drawer
      ? AnyLayout(HStackLayout(alignment: .center, spacing: 9))
      : AnyLayout(VStackLayout(spacing: 3))
    return layout {
      ZStack(alignment: .topTrailing) {
        Group {
          if let face, let url = httpsURL(face) {
            SiteThumbnail(url: url) {
              $0.resizable().scaledToFill()
            } placeholder: {
              Image(systemName: symbol)
            }
          } else {
            Image(systemName: symbol).font(.title3)
          }
        }
        .frame(width: horizontal ? 42 : 31, height: horizontal ? 42 : 31).background(.quaternary).clipShape(Circle())
        .overlay {
          if active || live {
            Circle().stroke(active ? Color.accentColor : Color.pink, lineWidth: 2)
          }
        }
        if updated {
          Circle().fill(Color.accentColor).frame(width: 8, height: 8)
            .accessibilityLabel("有更新")
        }
      }
      Text(name).font(.caption).fontWeight(active ? .semibold : .regular)
        .foregroundStyle(active ? Color.accentColor : Color.primary)
        .lineLimit(position.drawer || horizontal ? 1 : 2).multilineTextAlignment(
          position.drawer ? .leading : .center)
    }.frame(
      minWidth: 48, maxWidth: position.drawer ? .infinity : horizontal ? 62 : 68,
      minHeight: position.drawer ? 42 : 58, alignment: position.drawer ? .leading : .center
    )
    .padding(.horizontal, position.drawer ? 6 : 1)
    .background(
      active ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine).accessibilityAddTraits(active ? .isSelected : [])
  }
}

struct FeedPanelHost<Panel: View, Content: View>: View {
  @AppStorage(InterfaceInteraction.horizontal) private var threshold = 24.0
  let position: FeedPanelPosition
  @Binding var shown: Bool
  @ViewBuilder let panel: () -> Panel
  @ViewBuilder let content: () -> Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ScaledMetric(relativeTo: .caption) private var topRailHeight: CGFloat = 88
  @ScaledMetric(relativeTo: .caption) private var sideRailWidth: CGFloat = 68
  var body: some View {
    GeometryReader { geometry in
      if position == .top {
        VStack(spacing: 0) {
          panel().frame(height: topRailHeight)
          Divider()
          content()
        }
      } else if position.drawer {
        ZStack(alignment: position.leading ? .leading : .trailing) {
          content().accessibilityHidden(shown).allowsHitTesting(!shown)
          if shown {
            Button {
              close()
            } label: {
              Color.black.opacity(0.3).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("关闭 UP 主面板")
              .transition(.opacity)
            panel()
              .frame(width: min(286, geometry.size.width * 0.78))
              .frame(maxHeight: .infinity).background(.regularMaterial)
              .accessibilityAddTraits(.isModal)
              .transition(.move(edge: position.leading ? .leading : .trailing))
          }
        }.contentShape(Rectangle())
          .simultaneousGesture(
            DragGesture(minimumDistance: max(1,min(24,threshold))).onEnded { value in
              let dx = value.translation.width * (position.leading ? 1 : -1)
              let near =
                position.leading
                ? value.startLocation.x < 28 : value.startLocation.x > geometry.size.width - 28
              guard InterfaceInteraction.horizontalDrag(x: dx, y: value.translation.height, threshold: threshold) else { return }
              if !shown, near, dx > 48 { setShown(true) } else if shown, dx < -48 { close() }
            }
          )
      } else {
        HStack(spacing: 0) {
          if position.leading {
            panel().frame(width: sideRailWidth)
            Divider()
          }
          content()
          if !position.leading {
            Divider()
            panel().frame(width: sideRailWidth)
          }
        }
      }
    }.animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: shown)
  }
  private func close() { setShown(false) }
  private func setShown(_ value: Bool) { shown = value }
}
