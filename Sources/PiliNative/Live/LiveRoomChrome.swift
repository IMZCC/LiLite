import SwiftUI

// The live room's own look, after the original client and PiliPlus: a dark room over the stream's
// blurred cover, the anchor bar under the picture, chat as plain lines ("粉丝牌 名字：内容") on
// the dark background, and a rounded input bar at the bottom.

/// The room's backdrop: the cover, blurred and darkened; a dark gradient until it loads.
struct LiveRoomBackdrop: View {
  let url: URL?
  var body: some View {
    // The cover fills whatever space the page has without ever sizing it.
    LinearGradient(colors: [Color(white: 0.13), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
      .overlay {
        if let url {
          SiteThumbnail(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
            .blur(radius: 48, opaque: true)
            .overlay(Color.black.opacity(0.55))
            .transition(.opacity)
        }
      }
      .clipped()
      .ignoresSafeArea()
      .accessibilityHidden(true)
  }
}

/// Under the picture: the anchor (to their space), how many have watched and for how long it has
/// been live; follow, and the 高能观众 count that opens the ranking.
struct LiveAnchorBar: View {
  let room: LiveRoomIdentity
  let info: LiveRoomHeader?
  let watched: String?
  let online: Int64?
  let started: Int64?
  let ranks: () -> Void
  var body: some View {
    HStack(spacing: 10) {
      LazyLink {
        CreatorSpace(mid: room.uid, name: info?.anchor_info?.base_info?.uname ?? "主播")
      } label: {
        HStack(spacing: 9) {
          ProfileAvatar(url: info?.anchor_info?.base_info?.face.flatMap(httpsURL), size: 34)
          VStack(alignment: .leading, spacing: 2) {
            Text(info?.anchor_info?.base_info?.uname ?? "主播").font(.system(size: 14, weight: .medium))
              .foregroundStyle(.white).lineLimit(1)
            HStack(spacing: 8) {
              if let value = watched ?? info?.watched_show?.text_large, !value.isEmpty {
                Text(value).lineLimit(1)
              }
              LiveDurationText(timestamp: started)
            }
            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      Spacer(minLength: 6)
      CreatorQuickRelation(mid: room.uid).controlSize(.small)
      if let online, online > 0 {
        Button(action: ranks) {
          HStack(spacing: 3) {
            Text("高能 " + online.formatted(.number.notation(.compactName)))
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
          }
          .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
          .padding(.horizontal, 10).frame(height: 26)
          .background(.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("高能观众 \(online) 人，查看贡献榜")
      }
    }
    .padding(.horizontal, 14).padding(.vertical, 10)
  }
}

/// The room's tabs under the anchor, as the official room has them: 互动, and in a match room
/// 赛程 · 回放 · 选手评分. Words on the dark page; the current one white with the accent underline.
struct LiveRoomTabs: View {
  let titles: [String]
  @Binding var selected: Int
  @Namespace private var underline
  var body: some View {
    // One line each, scrolling sideways when the column is too narrow for all of them.
    ScrollView(.horizontal, showsIndicators: false) {
    HStack(spacing: 26) {
      ForEach(titles.indices, id: \.self) { i in
        let on = i == selected
        Button {
          guard !on else { return }
          TouchFeedback.light()
          selected = i
        } label: {
          Text(titles[i])
            .font(.system(size: 15, weight: on ? .semibold : .regular))
            .lineLimit(1).fixedSize()
            .foregroundStyle(on ? Color.white : Color.white.opacity(0.55))
            .frame(height: 40)
            .overlay(alignment: .bottom) {
              if on {
                Capsule().fill(Color.accentColor).frame(width: 18, height: 3)
                  .matchedGeometryEffect(id: "line", in: underline)
              }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
      }
    }
    .padding(.horizontal, 16)
    }
    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    .animation(.snappy(duration: 0.25), value: selected)
    .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5) }
  }
}

/// "已播 1:23" beside the watched count.
struct LiveDurationText: View {
  let timestamp: Int64?
  var body: some View {
    if let timestamp, timestamp > 0, Double(timestamp) <= Date().timeIntervalSince1970 {
      let start = Date(timeIntervalSince1970: Double(timestamp))
      TimelineView(.periodic(from: .now, by: 60)) { tick in
        let mins = max(0, Int(tick.date.timeIntervalSince(start) / 60))
        Text(mins < 1 ? "刚刚开播" : "已播 " + (mins < 60 ? "\(mins) 分钟" : String(format: "%d:%02d", mins / 60, mins % 60)))
          .lineLimit(1)
      }
    }
  }
}

/// The room's chat on the dark background. It keeps to the newest line until the reader scrolls
/// back; then a pill offers the new ones.
struct LiveChatFeed: View {
  let lines: [LiveLine]
  let anchor: Int64?
  /// Lines drawn on their own dark bubbles, for chat laid over the picture.
  var bubbles = false
  let select: (LiveLine) -> Void
  @State private var reading = false
  @State private var unseen = 0
  @State private var lastSeen: UUID?
  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: bubbles ? 6 : 8) {
          ForEach(lines) { line in
            Button { select(line) } label: {
              LiveChatLine(line: line, anchor: anchor, bubble: bubbles)
            }
            .buttonStyle(.plain)
            .id(line.id)
          }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
      }
      .scrollIndicators(.hidden)
      .defaultScrollAnchor(.bottom)
      .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { drag in
        if drag.translation.height > 12, !reading { reading = true; lastSeen = lines.last?.id }
      })
      .overlay(alignment: .bottomLeading) {
        if reading {
          Button {
            reading = false
            unseen = 0
            if let last = lines.last { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .bottom) } }
          } label: {
            Label(unseen > 0 ? "\(unseen) 条新消息" : "回到最新", systemImage: "arrow.down")
              .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
              .padding(.horizontal, 12).frame(height: 28)
              .background(Color.accentColor, in: Capsule())
          }
          .buttonStyle(.plain).padding(10)
          .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
      }
      .animation(.easeOut(duration: 0.18), value: reading)
      .onChange(of: lines.last?.id) { _, newest in
        guard let newest else { return }
        if reading {
          unseen = min(999, unseen + 1)
        } else {
          proxy.scrollTo(newest, anchor: .bottom)
        }
      }
    }
  }
}

/// One chat line: the fan medal, the name in a quiet colour, then the message.
struct LiveChatLine: View {
  let line: LiveLine
  var anchor: Int64? = nil
  var bubble = false
  @AppStorage("live.medal") private var showMedal = true
  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 5) {
      if let anchor, anchor == line.uid {
        LiveTag(text: "主播", color: Color(red: 1, green: 0.42, blue: 0.6))
      }
      if showMedal, let medal = line.medal {
        LiveMedal(text: medal)
      }
      message
    }
    .padding(.horizontal, bubble ? 9 : 0).padding(.vertical, bubble ? 5 : 0)
    .background {
      if bubble { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.32)) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
  @ViewBuilder private var message: some View {
    let name = line.name + (line.repliedName.map { " 回复 @" + $0 } ?? "") + "："
    if line.emote != nil || !line.inlineEmotes.isEmpty {
      HStack(alignment: .firstTextBaseline, spacing: 2) {
        Text(name).foregroundStyle(.white.opacity(0.55))
        ReplyRichText(nodes: LiveMessageRow(line: line).nodes, permitsPreview: false)
          .foregroundStyle(.white.opacity(0.93))
      }
      .font(.system(size: 14))
    } else {
      (Text(name).foregroundColor(.white.opacity(0.55))
        + Text(line.text).foregroundColor(line.highlight ? Color(red: 1, green: 0.78, blue: 0.35) : .white.opacity(0.93)))
        .font(.system(size: 14))
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// The fan medal "名字 21", coloured by its level band as the official badges are.
struct LiveMedal: View {
  let text: String
  private var level: Int { text.split(separator: " ").last.flatMap { Int($0) } ?? 0 }
  private var color: Color {
    switch level {
    case ..<5: Color(red: 0.36, green: 0.73, blue: 0.62)
    case 5..<9: Color(red: 0.36, green: 0.55, blue: 0.85)
    case 9..<13: Color(red: 0.55, green: 0.45, blue: 0.85)
    case 13..<17: Color(red: 0.86, green: 0.42, blue: 0.62)
    case 17..<21: Color(red: 0.93, green: 0.6, blue: 0.27)
    default: Color(red: 0.2, green: 0.36, blue: 0.75)
    }
  }
  var body: some View {
    let parts = text.split(separator: " ")
    HStack(spacing: 0) {
      Text(parts.dropLast().joined(separator: " ").isEmpty ? text : parts.dropLast().joined(separator: " "))
        .padding(.leading, 5).padding(.trailing, 3)
      if parts.count > 1, let last = parts.last {
        Text(last).foregroundStyle(color)
          .padding(.horizontal, 4)
          .background(.white, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
          .padding(1)
      }
    }
    .font(.system(size: 10, weight: .medium)).foregroundStyle(.white).lineLimit(1)
    .frame(height: 16)
    .background(color, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    .fixedSize()
  }
}

struct LiveTag: View {
  let text: String, color: Color
  var body: some View {
    Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
      .padding(.horizontal, 5).frame(height: 16)
      .background(color, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
      .fixedSize()
  }
}

/// The bottom bar: bullets on or off, "发个弹幕呗~" (opens the composer), like, emotes and 更多,
/// on a translucent panel with a rounded top as in PiliPlus.
struct LiveInputBar<Like: View, More: View>: View {
  @Binding var showBullets: Bool
  let compose: () -> Void
  let emotes: () -> Void
  @ViewBuilder let like: () -> Like
  @ViewBuilder let more: () -> More
  var body: some View {
    HStack(spacing: 6) {
      Button {
        TouchFeedback.light()
        showBullets.toggle()
      } label: {
        DanmakuSwitchGlyph(on: showBullets).environment(\.colorScheme, .dark)
          .frame(width: 36, height: 36).contentShape(Rectangle())
      }
      .accessibilityLabel(showBullets ? "关闭直播弹幕" : "开启直播弹幕")
      Button(action: compose) {
        Text("发个弹幕呗~").font(.system(size: 14)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14).frame(height: 36)
          .background(.white.opacity(0.1), in: Capsule())
          .contentShape(Capsule())
      }
      .accessibilityLabel("发送弹幕")
      Button(action: emotes) {
        Image(systemName: "face.smiling").font(.system(size: 21))
          .frame(width: 36, height: 36).contentShape(Rectangle())
      }
      .accessibilityLabel("表情")
      like()
        .font(.system(size: 20))
        .frame(width: 36, height: 36).contentShape(Rectangle())
      more()
        .font(.system(size: 20))
        .frame(width: 36, height: 36).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.white.opacity(0.9))
    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
    .background {
      UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20, style: .continuous)
        .fill(.white.opacity(0.08))
        .overlay(alignment: .top) {
          UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20, style: .continuous)
            .stroke(.white.opacity(0.1), lineWidth: 0.5)
        }
        .ignoresSafeArea(edges: .bottom)
    }
  }
}

// MARK: - Room panels

private struct RoomPanelCloseKey: EnvironmentKey {
  static let defaultValue: StableAction<Void>? = nil
}
extension EnvironmentValues {
  /// Closes the live room's panel. Views shown both as sheets and as the room's panels call it in
  /// place of `dismiss`, which inside a panel would leave the room itself.
  var roomPanelClose: StableAction<Void>? {
    get { self[RoomPanelCloseKey.self] }
    set { self[RoomPanelCloseKey.self] = newValue }
  }
}

/// A page of the room (高能榜, 醒目留言, 屏蔽, 播放信息…) opened in the room itself, as the official
/// room's half-screen panels are: under the picture in portrait, over the chat column beside it,
/// and as a drawer from the trailing edge in fullscreen — never a sheet laid over the stream.
struct LiveRoomPanelFrame<Content: View>: View {
  let title: String
  /// A drawer from the trailing edge rather than from the bottom.
  let side: Bool
  let close: () -> Void
  @ViewBuilder let content: () -> Content
  var body: some View {
    // The panel's own header: a stack nested in the room's is folded into the room's (hidden) bar.
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 8)
        Button(action: close) {
          Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
            .frame(width: 30, height: 30)
            .background(.white.opacity(0.1), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭")
      }
      .foregroundStyle(.white)
      .padding(.leading, 16).padding(.trailing, 12)
      .frame(height: 50)
      .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5) }
      content()
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color(white: 0.09))
    .clipShape(side
      ? UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, style: .continuous)
      : UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18, style: .continuous))
    .shadow(color: .black.opacity(0.35), radius: 12, x: side ? -2 : 0, y: side ? 0 : -2)
    .environment(\.colorScheme, .dark)
  }
}
