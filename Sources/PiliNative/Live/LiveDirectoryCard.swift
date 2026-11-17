import SwiftUI

struct LiveDirectoryCard: View {
  let room: LiveRoom, firstFrame: Bool, mobile: Bool, feedback: () -> Void
  @State private var gallery = false
  private var cover: URL? {
    let urls =
      firstFrame
      ? [room.system_cover, room.cover, room.user_cover] : [room.cover, room.user_cover]
    return urls.compactMap { $0.flatMap(GalleryPicture.source) }.first
  }
  private var canGiveFeedback: Bool {
    mobile && room.feedback?.contains(where: { $0.reasons?.contains(where: \.usable) == true }) == true
  }
  var body: some View {
    NavigationLink {
      LivePlayer(id: room.id, title: room.title)
    } label: {
      VStack(alignment: .leading, spacing: 7) {
        Rectangle().fill(.quaternary).aspectRatio(16 / 9, contentMode: .fit)
          .overlay {
            SiteThumbnail(url: cover) {
              $0.resizable().scaledToFill()
            } placeholder: {
              Color.clear
            }
          }
          .overlay(alignment: .bottom) {
            HStack(spacing: 4) {
              Text(room.uname ?? "").lineLimit(1)
              Spacer(minLength: 4)
              if let v = room.viewer, !v.isEmpty {
                Image(systemName: "person.2.fill").font(.system(size: 9))
                Text(v).monospacedDigit().lineLimit(1)
              }
            }
            .font(.caption.weight(.medium)).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.top, 20).padding(.bottom, 6)
            .background(
              LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
          }
          .clipped()
          .clipShape(RoundedRectangle(cornerRadius: NativeGlass.cardRadius, style: .continuous))
        Text(room.title).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
          .foregroundStyle(.primary)
          .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
          .padding(.trailing, canGiveFeedback ? 26 : 0)
          .padding(.horizontal, 2)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .overlay(alignment: .bottomTrailing) {
      if canGiveFeedback {
        Button(action: feedback) {
          Image(systemName: "ellipsis").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            .frame(width: 30, height: 30).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("推荐反馈")
      }
    }
    .contextMenu {
      if cover != nil { Button(firstFrame ? "查看直播首帧" : "查看直播封面") { gallery = true } }
      if canGiveFeedback { Button("推荐反馈", action: feedback) }
    }
    .piliSheet(isPresented: $gallery) {
      if let cover {
        PiliNavigationStack {
          NativeGallery([GalleryPicture(cover)], index: 0).toolbar {
            Button("关闭") { gallery = false }
          }
        }
      }
    }
  }
}
struct LiveFeedbackSheet: View {
  let room: LiveRoom
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.dismiss) private var dismiss
  @State private var chosen: LiveFeedbackGroup.Reason?
  @State private var busy = false
  @State private var done = false
  @State private var note: String?
  private var owner: String? { accounts.state.owner(.role(.recommend)) }
  var body: some View {
    PiliNavigationStack {
      Form {
        Text(room.title)
        ForEach(Array((room.feedback ?? []).enumerated()), id: \.offset) { _, group in
          Section {
            ForEach((group.reasons ?? []).filter(\.usable), id: \.self) { r in
              Button {
                chosen = r
              } label: {
                HStack {
                  Text(r.name ?? "")
                  Spacer()
                  if chosen == r { Image(systemName: "checkmark") }
                }
              }
            }
          } header: {
            Text(group.title ?? "反馈原因")
          } footer: {
            Text(group.subtitle ?? "")
          }
        }
        if let owner, owner == room.viewer {
          Button("提交反馈") {
            guard !done, !busy, let chosen else { return }
            busy = true
            Task {
              defer { busy = false }
              do {
                try await BiliAPI.shared.liveFeedback(room, reason: chosen, owner: owner)
                done = true
                note = "反馈已提交"
              } catch { note = error.localizedDescription }
            }
          }.disabled(chosen == nil || done)
        } else if owner == nil {
          NavigationLink("登录后提交反馈") { QRLoginView() }
        }
        if let note { Text(note) }
      }.disabled(busy).navigationTitle("直播推荐反馈").toolbar { Button("关闭") { dismiss() } }
    }
  }
}
