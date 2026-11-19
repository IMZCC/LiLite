import SwiftUI

struct HistoryCourseLink: View {
  @EnvironmentObject private var accounts: AccountContext
  private var owner: String { accounts.state.owner(.role(.video)) ?? "" }
  let id: Int64, byEpisode: Bool, aid: Int64?, seconds: Double?
  private var reader: String { accounts.state.owner(.role(.heartbeat)) ?? "" }
  @State private var observedEpisode: Int64?
  @State private var observedSeconds: Double?
  @State private var course: CourseDetail.Course?
  @State private var issue: String?
  @State private var refresh = 0
  var body: some View {
    Group {
      if let course {
        if let item = course.preferred(
          episode: byEpisode ? id : observedEpisode, aid: aid, useSaved: false)?.playItem
        {
          EpisodePlayer(
            episode: item, course: true,
            initialSeconds: seconds ?? observedSeconds,
            sequence: course.groups.first { $0.episodes.contains(where: { $0.id == item.id }) }?
              .episodes ?? course.lessons, seasonTitle: course.title,
            seasonID: course.season_id)
        } else {
          ContentUnavailableView("此课时暂不可播放", systemImage: "lock")
        }
      } else if let issue {
        ContentUnavailableView {
          Label("课程未能载入", systemImage: "book.closed")
        } description: { Text(issue) } actions: { Button("重试") { refresh += 1 } }
      } else {
        ProgressView()
      }
    }.task(id: "\(id):\(owner):\(reader):\(refresh)") {
      course = nil
      observedEpisode = nil
      observedSeconds = nil
      issue = nil
      do {
        let value = try await BiliAPI.shared.courseCatalog(
          id, byEpisode: byEpisode, videoOwner: owner)
        try Task.checkCancellation()
        let history: CourseCatalog?
        if reader == owner {
          history = value
        } else {
          history = try? await BiliAPI.shared.read(
            "/pugv/view/web/season", ["season_id": String(value.season_id)],
            expectedAccount: reader, as: CourseCatalog.self)
          try Task.checkCancellation()
        }
        let chosen = byEpisode ? id : history?.user_status?.progress?.last_ep_id
        observedEpisode = chosen
        if let entry = value.preferred(episode: chosen, aid: aid, useSaved: false),
          let hist = history?.lessons.first(where: { $0.id == entry.id })
        {
          observedSeconds = history?.continueSeconds(for: hist)
        }
        course = value
        issue = nil
      } catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
  }
}
