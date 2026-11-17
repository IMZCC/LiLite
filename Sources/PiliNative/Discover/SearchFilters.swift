import SwiftUI

struct SearchFilterForm: View {
  let domain: SearchDomain
  @Binding var videos: VideoSearchOptions
  @Binding var others: OtherSearchOptions
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    PiliNavigationStack {
      Form {
        if domain == .video || domain == .mixed {
          Picker("排序", selection: $videos.order) {
            ForEach(VideoSearchOptions.orders, id: \.0) { key, title in Text(title).tag(key) }
          }
          Picker("视频时长", selection: $videos.duration) {
            ForEach(
              Array(["全部时长", "10 分钟内", "10–30 分钟", "30–60 分钟", "60 分钟以上"].enumerated()),
              id: \.offset
            ) { i, title in Text(title).tag(i) }
          }
          Picker("视频分区", selection: $videos.zone) {
            ForEach(VideoSearchOptions.zones, id: \.0) { key, title in Text(title).tag(key) }
          }
          Picker("发布时间", selection: $videos.dates) {
            ForEach([(0, "不限"), (1, "最近一天"), (7, "最近一周"), (180, "最近半年"), (-1, "自定义")], id: \.0) {
              n, title in Text(title).tag(n)
            }
          }
          if videos.dates == -1 {
            let first =
              Calendar.current.date(from: .init(year: 2009, month: 6, day: 26)) ?? .distantPast
            DatePicker(
              "开始", selection: $videos.begin, in: first...min(videos.end, Date()),
              displayedComponents: .date)
            DatePicker(
              "结束", selection: $videos.end, in: videos.begin...max(videos.begin, Date()),
              displayedComponents: .date)
          }
          Button("重置视频筛选") { videos = VideoSearchOptions() }
        } else if domain == .creator {
          Picker("排列顺序", selection: $others.userOrder) {
            ForEach(OtherSearchOptions.users.indices, id: \.self) { n in
              Text(OtherSearchOptions.users[n].1).tag(n)
            }
          }
          Picker("用户类型", selection: $others.userType) {
            ForEach(Array(["全部用户", "UP 主", "普通用户", "认证用户"].enumerated()), id: \.offset) {
              i, title in Text(title).tag(i)
            }
          }
        } else if domain == .article {
          Picker("排序", selection: $others.articleOrder) {
            ForEach(OtherSearchOptions.articles, id: \.0) { k, n in Text(n).tag(k) }
          }
          Picker("专栏分区", selection: $others.articleZone) {
            ForEach(OtherSearchOptions.zones, id: \.0) { k, n in Text(n).tag(k) }
          }
        }
      }.navigationTitle("搜索筛选").toolbar { Button("完成") { dismiss() } }
    }
  }
}
