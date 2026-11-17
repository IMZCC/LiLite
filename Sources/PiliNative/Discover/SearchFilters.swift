import SwiftUI

struct SearchFilterForm: View {
  let domain: SearchDomain
  @Binding var videos: VideoSearchOptions
  @Binding var others: OtherSearchOptions
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    PiliNavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if domain == .video || domain == .mixed {
            group("排序") {
              FlowChoices(items: VideoSearchOptions.orders.map(\.0), selection: $videos.order) { key in
                VideoSearchOptions.orders.first { $0.0 == key }?.1 ?? key
              }
            }
            group("时长") {
              let titles = ["全部时长", "10 分钟内", "10–30 分钟", "30–60 分钟", "60 分钟以上"]
              FlowChoices(items: Array(titles.indices), selection: $videos.duration) { titles[$0] }
            }
            group("发布时间") {
              let dates = [(0, "不限"), (1, "最近一天"), (7, "最近一周"), (180, "最近半年"), (-1, "自定义")]
              FlowChoices(items: dates.map(\.0), selection: $videos.dates) { n in dates.first { $0.0 == n }?.1 ?? "" }
              if videos.dates == -1 {
                let first =
                  Calendar.current.date(from: .init(year: 2009, month: 6, day: 26)) ?? .distantPast
                HStack {
                  DatePicker(
                    "开始", selection: $videos.begin, in: first...min(videos.end, Date()),
                    displayedComponents: .date).labelsHidden()
                  Text("至").foregroundStyle(.secondary)
                  DatePicker(
                    "结束", selection: $videos.end, in: videos.begin...max(videos.begin, Date()),
                    displayedComponents: .date).labelsHidden()
                }
              }
            }
            group("内容分区") {
              FlowChoices(items: VideoSearchOptions.zones.map(\.0), selection: $videos.zone) { key in
                VideoSearchOptions.zones.first { $0.0 == key }?.1 ?? ""
              }
            }
          } else if domain == .creator {
            group("排列顺序") {
              FlowChoices(items: Array(OtherSearchOptions.users.indices), selection: $others.userOrder) {
                OtherSearchOptions.users[$0].1
              }
            }
            group("用户类型") {
              let titles = ["全部用户", "UP 主", "普通用户", "认证用户"]
              FlowChoices(items: Array(titles.indices), selection: $others.userType) { titles[$0] }
            }
          } else if domain == .article {
            group("排序") {
              FlowChoices(items: OtherSearchOptions.articles.map(\.0), selection: $others.articleOrder) { k in
                OtherSearchOptions.articles.first { $0.0 == k }?.1 ?? ""
              }
            }
            group("专栏分区") {
              FlowChoices(items: OtherSearchOptions.zones.map(\.0), selection: $others.articleZone) { k in
                OtherSearchOptions.zones.first { $0.0 == k }?.1 ?? ""
              }
            }
          }
        }
        .padding(16)
      }
      .navigationTitle("内容筛选").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if domain == .video || domain == .mixed {
          ToolbarItem(placement: .cancellationAction) { Button("重置") { videos = VideoSearchOptions() } }
        }
        ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
      }
    }
    .presentationDetents([.medium, .large])
  }
  private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.subheadline.weight(.semibold))
      content()
    }
  }
}

/// Wrapping single-choice chips (the original search panel's filter rows).
struct FlowChoices<Item: Hashable>: View {
  let items: [Item]
  @Binding var selection: Item
  let title: (Item) -> String
  var body: some View {
    WrappingActions(spacing: 8, rowSpacing: 8) {
      ForEach(items, id: \.self) { item in
        let on = item == selection
        Button {
          TouchFeedback.light()
          withAnimation(.snappy(duration: 0.2)) { selection = item }
        } label: {
          Text(title(item)).font(.footnote.weight(on ? .semibold : .regular))
            .foregroundStyle(on ? Color.accentColor : Color.primary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(on ? Color.accentColor.opacity(0.12) : Color(uiColor: .tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
      }
    }
  }
}
